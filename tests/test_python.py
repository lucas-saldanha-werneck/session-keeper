#!/usr/bin/env python3
"""Tests for the Python commands, against a simulated system.

Nothing here talks to a real iTerm, tmux, launchd or Claude: every subprocess call goes through a fake
(`FakeSystem.run`) that keeps a process table, tmux sessions and iTerm windows in memory, and all state
lives in a temporary folder. Runs on macOS, Linux and Windows. Run: python3 tests/test_python.py -v
"""
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TMP = tempfile.mkdtemp(prefix="sk-test-")
os.environ.update(
    SESSION_KEEPER_STATE_DIR=os.path.join(TMP, "state"),
    SESSION_KEEPER_LOG_DIR=os.path.join(TMP, "logs"),
    SESSION_KEEPER_CONFIG=os.path.join(TMP, "config"),
    CLAUDE_CONFIG_DIR=os.path.join(TMP, "claude"),
    SESSION_KEEPER_ITERM_APP=os.path.join(TMP, "iTerm.app"),
    SESSION_KEEPER_ASSUME_MACOS="1",
    SESSION_KEEPER_TMUX="tmux",
    SESSION_KEEPER_SHELL="/bin/zsh",
    CLAUDE_SAVE_WAIT="1",
    CLAUDE_SAVE_TYPE_DELAY="0",
)
for k in ("SESSION_KEEPER_NOTIFY", "SESSION_KEEPER_CLAUDE_ARGS", "SESSION_KEEPER_KEEP_ENV",
          "SESSION_KEEPER_IGNORE_SESSIONS", "SESSION_KEEPER_FOLDER_TITLE", "SESSION_KEEPER_TITLE_ROOTS",
          "SESSION_KEEPER_GC_PREFIX", "CLAUDE_PLUGIN_OPTION_FOLDER_TITLE"):
    os.environ.pop(k, None)
os.makedirs(os.environ["SESSION_KEEPER_ITERM_APP"])
sys.path.insert(0, os.path.join(ROOT, "lib"))


def load(name):
    ld = SourceFileLoader(name.replace("-", "_"), os.path.join(ROOT, "bin", name))
    spec = importlib.util.spec_from_loader(ld.name, ld)
    mod = importlib.util.module_from_spec(spec)
    ld.exec_module(mod)
    return mod


save_mod = load("claude-save")
cir = save_mod.cir
gc_mod = load("claude-tmux-gc")
app_mod = load("claude-restart-app")
title_mod = load("claude-folder-title")
import sk_common  # noqa: E402

SID_A = "aaaaaaaa-0000-4000-8000-00000000000a"
SID_B = "bbbbbbbb-0000-4000-8000-00000000000b"
SID_C = "cccccccc-0000-4000-8000-00000000000c"
HOME = os.path.expanduser("~")


def cp(args, rc=0, out="", err=""):
    return subprocess.CompletedProcess(args, rc, out, err)


class FakeSystem:
    """In-memory processes, tmux and iTerm. run() answers the commands the tools use."""

    def __init__(self):
        self.procs = {}         # pid -> [ppid, tty, args, env-string]
        self.sessions = {}      # tmux name -> {"panes": [(pid, path, pane_id)], "attached": "0", "created": t}
        self.clients = {}       # tty -> tmux session
        self.windows = []       # (window id, [l, t, r, b], tab, tty)
        self.iterm_running = True
        self.tmux_start = int(time.time()) - 3600
        self.calls = []
        self.created = []       # osascript create window / tab commands
        self.next_pid = 5000
        self.next_win = 900
        self.screens = {}       # pane id -> text
        self.start_on_write = True
        self.never_start = set()

    # helpers to build the world
    def proc(self, pid, ppid, args, tty="??", env=""):
        self.procs[pid] = [ppid, tty, args, env]

    def claude(self, pid, ppid, sid, cwd, tty="??", args=None, env="", status="idle", name=None, tmux=None):
        self.proc(pid, ppid, args or "claude", tty, env)
        d = {"pid": pid, "sessionId": sid, "cwd": cwd, "kind": "interactive", "status": status, "name": name}
        if tmux:
            d["tmux"] = tmux
        os.makedirs(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "sessions"), exist_ok=True)
        with open(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "sessions", f"{pid}.json"), "w") as f:
            json.dump(d, f)

    def _resume_started(self, text):
        import re
        m = re.search(r"--resume ([0-9a-f-]{36})", text)
        if m and self.start_on_write and m.group(1) not in self.never_start:
            self.next_pid += 1
            self.claude(self.next_pid, 1, m.group(1), HOME)

    def run(self, cmd, **kw):
        self.calls.append(list(cmd))
        prog = os.path.basename(cmd[0])
        a = cmd[1:]
        if prog == "ps":
            return self._ps(a)
        if prog == "pgrep":
            if "iTerm2" in a:
                return cp(cmd, 0 if self.iterm_running else 1)
            return cp(cmd, 0, "\n".join(str(p) for p, v in self.procs.items() if a[-1] in v[2]))
        if prog == "lsof":
            return cp(cmd, 0, f"p{a[2]}\nfcwd\nn{HOME}/work\n")
        if prog == "tmux":
            return self._tmux(a)
        if prog == "osascript":
            return self._osa(a[1])
        if prog == "notifier":
            return cp(cmd, 0, "sent")
        return cp(cmd, 127, "", f"{prog}: not faked")

    def _ps(self, a):
        if a[:2] == ["-axo", "pid=,ppid=,tty=,args="]:
            return cp(a, 0, "\n".join(f"{p} {v[0]} {v[1]} {v[2]}" for p, v in self.procs.items()))
        if a[:2] == ["-axo", "pid=,ppid=,args="]:
            return cp(a, 0, "\n".join(f"{p} {v[0]} {v[2]}" for p, v in self.procs.items()))
        if "-p" in a:
            pid = int(a[a.index("-p") + 1])
            if pid not in self.procs:
                return cp(a, 1)
            v = self.procs[pid]
            return cp(a, 0, (v[2] + " " + v[3]).strip() if "-E" in a else v[2])
        if "-t" in a:
            tty = a[a.index("-t") + 1]
            return cp(a, 0, "\n".join(v[2] for v in self.procs.values() if v[1] == tty))
        return cp(a, 1)

    def _tmux(self, a):
        c = a[0]
        if c == "display-message":
            return cp(a, 0, f"{self.tmux_start}\n")
        if c == "list-clients":
            return cp(a, 0, "\n".join(f"{t}|{s}" for t, s in self.clients.items()))
        if c == "list-sessions":
            if "#{session_attached}" in a[-1]:
                return cp(a, 0, "\n".join(f"{n}|{s['attached']}" for n, s in self.sessions.items()))
            return cp(a, 0, "\n".join(self.sessions))
        if c == "list-panes":
            fmt = a[-1]
            rows = []
            items = self.sessions.items()
            if "-t" in a:
                t = a[a.index("-t") + 1]
                items = [(t, self.sessions[t])] if t in self.sessions else []
            for n, s in items:
                for pid, path, pane in s["panes"]:
                    rows.append(fmt.replace("#{session_name}", n).replace("#{pane_pid}", str(pid))
                                .replace("#{pane_current_path}", path).replace("#{pane_id}", pane)
                                .replace("#{session_created}", str(s["created"]))
                                .replace("#{session_attached}", s["attached"]))
            return cp(a, 0, "\n".join(rows))
        if c == "new-session":
            name = a[a.index("-s") + 1]
            self.sessions[name] = {"panes": [(1, a[a.index("-c") + 1], "%9")], "attached": "0", "created": int(time.time())}
            if len(a) > 6:
                self._resume_started(a[-1])
            return cp(a, 0)
        if c == "capture-pane":
            return cp(a, 0, self.screens.get(a[a.index("-t") + 1], ""))
        if c in ("send-keys", "kill-session", "detach-client", "has-session"):
            if c == "kill-session":
                self.sessions.pop(a[a.index("-t") + 1], None)
            return cp(a, 0)
        return cp(a, 1)

    def _osa(self, script):
        if script == cir.LIST_OSA:
            if not self.iterm_running:
                return cp([], 1, "", "not running")
            return cp([], 0, "".join(f"{w}|{','.join(map(str, b))}|{t}|{tty}\n" for w, b, t, tty in self.windows))
        if "count windows" in script:
            return cp([], 0, "1")
        if "get id of (windows" in script:
            return cp([], 0, "")
        if "create window" in script or "create tab" in script:
            self.created.append(script)
            self._resume_started(script)
            self.next_win += 1
            return cp([], 0, f"{self.next_win}|/dev/ttys0{self.next_win % 100:02d}")
        return cp([], 0, "")  # set bounds, get bounds, select, close: accepted, nothing to return


class Base(unittest.TestCase):
    def setUp(self):
        for d in ("state", "logs", "claude"):
            shutil.rmtree(os.path.join(TMP, d), ignore_errors=True)
        self.fs = FakeSystem()
        self.patches = [mock.patch.object(cir, "run", self.fs.run), mock.patch.object(gc_mod, "run", self.fs.run),
                        mock.patch.object(app_mod, "run", self.fs.run), mock.patch.object(sk_common, "run", self.fs.run),
                        mock.patch("time.sleep", lambda s: None), mock.patch.object(cir, "HAS_TMUX", True),
                        mock.patch.object(save_mod, "my_tty", lambda: None),
                        mock.patch.object(cir, "log", lambda msg: None)]
        for p in self.patches:
            p.start()

    def tearDown(self):
        for p in reversed(self.patches):
            p.stop()
        for k in ("SESSION_KEEPER_NOTIFY", "SESSION_KEEPER_IGNORE_SESSIONS", "SESSION_KEEPER_CLAUDE_ARGS"):
            os.environ.pop(k, None)

    def out(self, fn, *a, argv=None):
        buf = io.StringIO()
        with redirect_stdout(buf), mock.patch.object(sys, "argv", ["x"] + (argv or [])):
            rc = fn(*a)
        return rc, buf.getvalue()

    def world(self):
        """Three iTerm windows (tmux+Claude with 2 tabs, Claude outside tmux, shell) and three detached
        tmux sessions (Claude, a node server, an idle shell)."""
        fs = self.fs
        fs.windows = [(101, [0, 25, 800, 600], 1, "/dev/ttys001"), (101, [0, 25, 800, 600], 2, "/dev/ttys002"),
                      (102, [810, 25, 1600, 600], 1, "/dev/ttys003"), (103, [0, 610, 800, 1000], 1, "/dev/ttys004")]
        fs.clients = {"/dev/ttys001": "work"}
        fs.sessions = {
            "work": {"panes": [(200, f"{HOME}/work", "%1")], "attached": "1", "created": 0},
            "bg-claude": {"panes": [(300, f"{HOME}/bg", "%2")], "attached": "0", "created": 0},
            "bg-node": {"panes": [(400, f"{HOME}/site", "%3")], "attached": "0", "created": 0},
            "bg-idle": {"panes": [(500, f"{HOME}/idle", "%4")], "attached": "0", "created": 0},
        }
        fs.proc(200, 1, "-zsh")
        fs.claude(201, 200, SID_A, f"{HOME}/work", args="claude --remote-control",
                  env="CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 PATH=/bin", name="api", tmux="work:0")
        fs.proc(250, 1, "-zsh", tty="ttys002")
        fs.claude(301, 1, SID_B, f"{HOME}/other", tty="ttys003", name="docs")
        fs.proc(350, 1, "-zsh", tty="ttys004")
        fs.proc(300, 1, "-zsh")
        fs.claude(302, 300, SID_C, f"{HOME}/bg", tmux="bg-claude:0", env=f"{save_mod.PRESENCE_VAR}=1")
        fs.proc(400, 1, "-zsh")
        fs.proc(401, 400, "node server.js --port 3000")
        fs.proc(500, 1, "-zsh")

    def saved(self):
        with open(save_mod.SAVE) as f:
            return json.load(f)


class TestConfig(unittest.TestCase):
    def test_env_wins_over_file_and_quotes_and_tilde(self):
        p = os.path.join(TMP, "cfg-test")
        with open(p, "w") as f:
            f.write("# comment\nexport A_ONE='~/x'\nB_TWO=\"two\"\nNOT A LINE\nSESSION_KEEPER_GC_PREFIX=file\n")
        c = sk_common._read_config(p)
        self.assertEqual(c["A_ONE"], os.path.join(HOME, "x"))
        self.assertEqual(c["B_TWO"], "two")
        self.assertNotIn("NOT A LINE", c)
        with mock.patch.dict(sk_common._CONFIG, c), mock.patch.dict(os.environ, {"SESSION_KEEPER_GC_PREFIX": "env"}):
            self.assertEqual(sk_common.cfg("SESSION_KEEPER_GC_PREFIX"), "env")
        with mock.patch.dict(sk_common._CONFIG, c):
            self.assertEqual(sk_common.cfg("SESSION_KEEPER_GC_PREFIX"), "file")
            self.assertEqual(sk_common.cfg("MISSING_X", "dflt"), "dflt")

    def test_run_missing_program_returns_127(self):
        r = sk_common.run(["definitely-not-a-program-sk"])
        self.assertEqual(r.returncode, 127)


class TestSnapshot(Base):
    def test_classifies_tmux_claude_and_shell(self):
        self.world()
        snap = cir.take_snapshot()
        kinds = [(w["window"], w["tab"], w["kind"]) for w in snap["windows"]]
        self.assertEqual(kinds, [(101, 1, "tmux"), (101, 2, "shell"), (102, 1, "claude"), (103, 1, "shell")])
        tm = snap["windows"][0]
        self.assertEqual((tm["session"], tm["claude_id"], tm["remote"]), ("work", SID_A, True))
        self.assertEqual(snap["windows"][2]["claude_id"], SID_B)
        self.assertTrue(os.path.exists(cir.SNAPSHOT))
        self.assertIn("tmux work (api)", cir.describe(tm))

    def test_no_snapshot_when_iterm_closed(self):
        self.fs.iterm_running = False
        self.assertIsNone(cir.take_snapshot())

    def test_reopen_creates_back_to_front_tabs_and_attaches(self):
        self.world()
        snap = cir.take_snapshot()
        cir.reopen(snap)
        made = self.fs.created
        self.assertEqual(len(made), 4)
        self.assertIn("{0, 610, 800, 1000}", made[0])          # back window first
        self.assertIn("claude --resume " + SID_B, made[1])
        self.assertIn("attach-session -t work", made[2])
        self.assertIn("create tab", made[3])                   # 2nd tab of the front window

    def test_cli_without_iterm_and_unknown_option(self):
        env = dict(os.environ, SESSION_KEEPER_ITERM_APP=os.path.join(TMP, "nope.app"))
        r = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "claude-iterm-restart")], env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("needs macOS and iTerm2", r.stdout)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "bin", "claude-iterm-restart"), "--bogus"], env=env,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertIn("unknown option", r.stdout)


class TestSave(Base):
    def test_save_everything(self):
        self.world()
        os.environ["SESSION_KEEPER_IGNORE_SESSIONS"] = "bg-idle"
        rc, out = self.out(save_mod.save, False)
        self.assertEqual(rc, 0)
        d = self.saved()
        self.assertEqual(len(d["windows"]), 4)
        w = d["windows"][0]
        self.assertIn(f"claude --resume {SID_A} --remote-control", w["cmd"])
        self.assertIn("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1", w["cmd"])
        self.assertNotIn("PATH=", w["cmd"])
        self.assertIn(f"claude --resume {SID_B}", d["windows"][2]["cmd"])
        self.assertNotIn("--remote-control", d["windows"][2]["cmd"])
        names = {s["session"]: s for s in d["detached"]}
        self.assertEqual(set(names), {"bg-claude", "bg-node"})
        self.assertIn(f"{save_mod.PRESENCE_VAR}=1 claude --resume {SID_C}", names["bg-claude"]["cmd"])
        self.assertEqual(names["bg-node"]["command"], "node server.js --port 3000")
        self.assertEqual(len([f for f in os.listdir(save_mod.STATE) if f.startswith("save-")]), 1)
        self.assertIn("Ready to restart", out)

    def test_busy_session_warns(self):
        self.world()
        self.fs.claude(301, 1, SID_B, f"{HOME}/other", tty="ttys003", status="busy")
        rc, out = self.out(save_mod.save, False)
        self.assertIn("working right now", out)

    def test_dry_run_writes_nothing(self):
        self.world()
        rc, out = self.out(save_mod.save, True)
        self.assertFalse(os.path.exists(save_mod.SAVE))
        self.assertIn("dry-run", out)

    def test_typed_cmd_per_shell(self):
        with mock.patch.dict(os.environ, {"SESSION_KEEPER_SHELL": "/bin/zsh"}):
            self.assertIn("print -z -- 'npm run dev'", save_mod.typed_cmd("/x", "npm run dev"))
        with mock.patch.dict(os.environ, {"SESSION_KEEPER_SHELL": "/bin/bash"}):
            c = save_mod.typed_cmd("/x", "npm run dev")
            self.assertNotIn("print -z", c)
            self.assertIn("was running: npm run dev", c)

    def test_extra_claude_args(self):
        os.environ["SESSION_KEEPER_CLAUDE_ARGS"] = "--model opus"
        self.assertTrue(save_mod.claude_cmd("/x", SID_A, None).endswith(f"claude --resume {SID_A} --model opus"))


class TestAuto(Base):
    def test_auto_skips_when_unchanged_and_pauses_after_reboot(self):
        self.world()
        self.out(save_mod.save, False, True)
        first = self.saved()["saved_at"]
        self.out(save_mod.save, False, True)
        self.assertEqual(self.saved()["saved_at"], first)              # unchanged: not rewritten
        self.fs.tmux_start = int(time.time()) + 10                     # "reboot": tmux started after the save
        self.fs.claude(301, 1, SID_B, f"{HOME}/elsewhere", tty="ttys003")
        self.out(save_mod.save, False, True)
        self.assertEqual(self.saved()["saved_at"], first)              # paused
        with open(os.path.join(os.environ["SESSION_KEEPER_LOG_DIR"], "claude-save.log")) as f:
            self.assertIn("paused until --reopen", f.read())

    def test_warn_hook(self):
        self.world()
        self.out(save_mod.save, False)
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps({"session_id": "zzz"}))):
            rc, out = self.out(save_mod.warn_sessionstart)
        self.assertEqual(out, "")                                     # not paused: silent
        self.fs.tmux_start = int(time.time()) + 10
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps({"session_id": "zzz"}))):
            rc, out = self.out(save_mod.warn_sessionstart)
        msg = json.loads(out)
        self.assertIn("Auto-save PAUSED", msg["systemMessage"])
        self.assertEqual(msg["hookSpecificOutput"]["hookEventName"], "SessionStart")
        with mock.patch.object(sys, "stdin", io.StringIO(json.dumps({"session_id": SID_A}))):
            rc, out = self.out(save_mod.warn_sessionstart)
        self.assertEqual(out, "")                                     # a session being reopened

    def test_auto_guard_with_iterm_closed_but_saves_without_iterm(self):
        self.world()
        self.fs.iterm_running = False
        self.out(save_mod.save, False, True)
        self.assertFalse(os.path.exists(save_mod.SAVE))               # iTerm installed but closed: no partial save
        with mock.patch.object(cir, "iterm_installed", lambda: False):
            self.out(save_mod.save, False, True)
        d = self.saved()
        self.assertEqual(d["windows"], [])
        self.assertIn(SID_A, [s.get("claude_id") for s in d["detached"]])  # 'work' is now window-less


class TestReopen(Base):
    def make_save(self):
        self.world()
        self.out(save_mod.save, False)
        # after the "reboot": nothing alive, no tmux sessions, no windows
        for pid in list(self.fs.procs):
            self.fs.procs.pop(pid)
        shutil.rmtree(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "sessions"))
        self.fs.sessions, self.fs.clients, self.fs.windows = {}, {}, []

    def test_dry_run(self):
        self.make_save()
        rc, out = self.out(save_mod.reopen, save_mod.SAVE, True, False, argv=["--reopen", "--dry-run"])
        self.assertEqual(rc, 0)
        self.assertIn("will open 6 window(s)/tab(s) and 0 tmux session(s)", out)
        self.assertEqual(self.fs.created, [])

    def test_reopen_and_refuse_second_time(self):
        self.make_save()
        rc, out = self.out(save_mod.reopen, save_mod.SAVE, False, False, argv=["--reopen", "--keep-window"])
        self.assertEqual(rc, 0, out)
        self.assertIn("done: 3 of 3 conversation(s) up", out)
        self.assertEqual(len(self.fs.created), 6)
        detached_win = [s for s in self.fs.created if SID_C in s][0]
        self.assertNotIn(save_mod.PRESENCE_VAR, detached_win)       # got a window: presence var dropped
        self.assertTrue(self.saved()["restored_at"])
        rc, out = self.out(save_mod.reopen, save_mod.SAVE, False, False, argv=["--reopen"])
        self.assertEqual(rc, 1)
        self.assertIn("already restored", out)

    def test_no_window_flag_starts_detached_tmux(self):
        self.make_save()
        rc, out = self.out(save_mod.reopen, save_mod.SAVE, False, False, argv=["--reopen", "--no-window", "--keep-window"])
        self.assertIn("bg-claude", self.fs.sessions)
        self.assertIn("bg-node", self.fs.sessions)
        sends = [c for c in self.fs.calls if c[:2] == ["tmux", "send-keys"]]
        self.assertEqual(sends[0][-1], "node server.js --port 3000")  # typed, no Enter

    def test_problem_is_reported_through_notifier(self):
        self.make_save()
        self.fs.never_start.add(SID_B)
        os.environ["SESSION_KEEPER_NOTIFY"] = "notifier --to me"
        rc, out = self.out(save_mod.reopen, save_mod.SAVE, False, False, argv=["--reopen", "--keep-window"])
        self.assertIn("done: 2 of 3", out)
        sent = [c for c in self.fs.calls if c[0] == "notifier"]
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0][1:3], ["--to", "me"])
        self.assertIn("2 of 3 conversation(s) came back", sent[0][3])

    def test_without_iterm_and_tmux_prints_commands(self):
        self.make_save()
        with mock.patch.object(cir, "iterm_installed", lambda: False), mock.patch.object(cir, "HAS_TMUX", False):
            rc, out = self.out(save_mod.reopen, save_mod.SAVE, True, False, argv=["--reopen", "--dry-run"])
        self.assertIn("neither iTerm2 nor tmux found", out)
        self.assertIn(f"claude --resume {SID_A}", out)

    def test_pick_save_prefers_copy_with_more_conversations(self):
        self.make_save()
        big = self.saved()
        small = dict(big, windows=[], detached=[], saved_at=big["saved_at"] + 60)
        with open(save_mod.SAVE, "w") as f:
            json.dump(small, f)
        self.assertNotEqual(save_mod.pick_save(), save_mod.SAVE)
        with open(save_mod.pick_save()) as f:
            self.assertEqual(save_mod.n_conversations(json.load(f)), 3)

    def test_why_not_up_reads_trust_prompt(self):
        self.fs.sessions = {"s": {"panes": [(700, HOME, "%7")], "attached": "0", "created": 0}}
        self.fs.proc(700, 1, "-zsh")
        self.fs.proc(701, 700, f"claude --resume {SID_A}")
        self.fs.screens["%7"] = "Do you trust this folder?\n> Yes, I trust this folder\n"
        self.assertIn("trust this folder", save_mod.why_not_up(SID_A))


class TestTmuxGc(Base):
    def test_closes_only_empty_old_detached_sessions(self):
        old = int(time.time()) - 3600
        self.fs.sessions = {
            "claude-empty": {"panes": [(10, "/a", "%1")], "attached": "0", "created": old},
            "claude-attached": {"panes": [(20, "/b", "%2")], "attached": "1", "created": old},
            "claude-live": {"panes": [(30, "/c", "%3")], "attached": "0", "created": old},
            "claude-young": {"panes": [(40, "/d", "%4")], "attached": "0", "created": int(time.time())},
            "other": {"panes": [(50, "/e", "%5")], "attached": "0", "created": old},
        }
        for p in (10, 20, 30, 40, 50):
            self.fs.proc(p, 1, "-zsh")
        self.fs.proc(31, 30, "node /x/claude-auto-retry/src/launcher.js")
        with mock.patch.object(gc_mod, "find_tmux", lambda: "tmux"):
            rc, out = self.out(gc_mod.main, ["--dry-run"])
            self.assertIn("DRY summary: empty=1 kept=3", out)
            self.assertIn("claude-empty", self.fs.sessions)
            rc, out = self.out(gc_mod.main, [])
        self.assertNotIn("claude-empty", self.fs.sessions)
        self.assertEqual(set(self.fs.sessions), {"claude-attached", "claude-live", "claude-young", "other"})

    def test_without_tmux(self):
        with mock.patch.object(gc_mod, "find_tmux", lambda: None):
            rc, out = self.out(gc_mod.main, [])
        self.assertEqual(rc, 0)
        self.assertIn("tmux not found", out)


class TestRestartApp(Base):
    def test_dryrun_finds_the_right_process(self):
        sid = "local_" + "1" * 8 + "-1111-1111-1111-" + "1" * 12
        log = os.path.join(TMP, "main.log")
        with open(log, "w") as f:
            f.write(f"... [Stop hook] Query completed for session {sid}\n")
        cli = "/Applications/Claude.app/Contents/MacOS/claude --input-format stream-json"
        self.fs.proc(900, 1, cli, env=f"CLAUDE_CODE_HOST_SESSION_ID={sid}")
        self.fs.proc(901, 1, cli, env="CLAUDE_CODE_HOST_SESSION_ID=local_other")
        with mock.patch.object(app_mod, "MAINLOG", log), mock.patch.object(app_mod, "DRYRUN", True), \
                mock.patch.object(app_mod, "SID", sid):
            self.assertEqual(app_mod.main("0", 0), 0)
        with open(app_mod.LOG) as f:
            self.assertIn("DRYRUN would stop pid 900", f.read())


class TestFolderTitle(unittest.TestCase):
    BIN = os.path.join(ROOT, "bin", "claude-folder-title")

    def hook(self, env_extra, payload):
        env = dict(os.environ, **env_extra)
        return subprocess.run([sys.executable, self.BIN], input=json.dumps(payload), env=env,
                              capture_output=True, text=True)

    def test_self_test(self):
        r = subprocess.run([sys.executable, self.BIN, "--self-test"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_off_by_default_and_on_with_roots(self):
        root = os.path.join(TMP, "Projects")
        os.makedirs(os.path.join(root, "acme", "api"), exist_ok=True)
        p = {"hook_event_name": "SessionStart", "source": "startup", "cwd": os.path.join(root, "acme", "api"),
             "session_title": "billing export"}
        self.assertEqual(self.hook({}, p).stdout, "")
        r = self.hook({"SESSION_KEEPER_FOLDER_TITLE": "1", "SESSION_KEEPER_TITLE_ROOTS": root}, p)
        self.assertEqual(json.loads(r.stdout)["hookSpecificOutput"]["sessionTitle"], "acme/api · billing export")
        r = self.hook({"CLAUDE_PLUGIN_OPTION_FOLDER_TITLE": "on", "SESSION_KEEPER_TITLE_ROOTS": root},
                      dict(p, source="compact"))
        self.assertEqual(r.stdout, "")                                 # only startup|resume|fork

    def test_bad_input_is_silent(self):
        r = subprocess.run([sys.executable, self.BIN], input="not json", capture_output=True, text=True,
                           env=dict(os.environ, SESSION_KEEPER_FOLDER_TITLE="1"))
        self.assertEqual((r.returncode, r.stdout), (0, ""))


if __name__ == "__main__":
    try:
        unittest.main()
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
