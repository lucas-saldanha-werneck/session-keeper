"""Shared helpers for the session-keeper commands: config, paths, logging and a safe subprocess runner.

Config comes from, in order: the environment, then ~/.config/session-keeper/config (KEY=VALUE lines,
shell style, '#' comments). The file exists so launchd jobs, which do not see your shell profile,
get the same settings.
"""
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CONFIG_FILE = os.environ.get("SESSION_KEEPER_CONFIG") or os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "session-keeper", "config")


# Settings that hold one path: their slashes are normalized (Windows: "C:\\Users\\me/x" -> "C:\\Users\\me\\x").
# Never applied to other settings: a command line or a URL must reach its program as written.
PATH_KEYS = {"SESSION_KEEPER_STATE_DIR", "SESSION_KEEPER_LOG_DIR", "SESSION_KEEPER_TMUX", "SESSION_KEEPER_SHELL",
             "SESSION_KEEPER_ITERM_APP", "CLAUDE_AUTO_RETRY_LAUNCHER"}


def _expand_home(v):
    """Only a leading ~ or $HOME / ${HOME} (alone or followed by /) becomes the home folder; nothing else is
    expanded. lib/sk_config.sh follows the same rule."""
    for prefix in ("~", "$HOME", "${HOME}"):
        if v == prefix or v.startswith(prefix + "/"):
            return HOME + v[len(prefix):]
    return v


def _read_config(path):
    """KEY=VALUE lines, shell style. Same rules as sk_load_config in lib/sk_config.sh."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.strip()
                if k.startswith("export "):
                    k = k[len("export "):].strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                v = _expand_home(v)
                if k in PATH_KEYS and v:
                    v = os.path.normpath(v)
                out[k] = v
    except OSError:
        pass
    return out


_CONFIG = _read_config(CONFIG_FILE)


def cfg(name, default=""):
    """Setting from the environment, else the config file, else default."""
    v = os.environ.get(name) or _CONFIG.get(name)  # a non-empty environment variable wins, as in sk_config.sh
    return default if v is None or v == "" else v


def cfg_number(name, default):
    """A numeric setting; a value that is not a number falls back to `default` with a warning on stderr."""
    raw = cfg(name)
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        print(f"warning: {name}={raw!r} is not a number; using {default:g}", file=sys.stderr)
        return default


def claude_dir():
    return os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")


def state_dir():
    return cfg("SESSION_KEEPER_STATE_DIR", os.path.join(HOME, ".local", "state", "session-keeper"))


def log_dir():
    default = os.path.join(HOME, "Library", "Logs") if sys.platform == "darwin" else os.path.join(state_dir(), "logs")
    return cfg("SESSION_KEEPER_LOG_DIR", default)


def is_macos():
    return sys.platform == "darwin" or os.environ.get("SESSION_KEEPER_ASSUME_MACOS") == "1"


def find_tmux():
    """Path to tmux, or None. launchd jobs have a short PATH, so Homebrew locations are tried too."""
    p = cfg("SESSION_KEEPER_TMUX")
    if p:
        return p if os.path.exists(p) or shutil.which(p) else None
    found = shutil.which("tmux")
    if found:
        return found
    for c in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if os.path.exists(c):
            return c
    return None


def run(cmd, **kw):
    """subprocess.run with captured text output. A missing program returns code 127 instead of raising,
    so every optional tool (tmux, osascript, lsof...) can simply be absent."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except (FileNotFoundError, PermissionError, NotADirectoryError) as e:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: {e}")


def short_path(p):
    p = p or ""
    if p == HOME:
        return "~"
    return "~/" + p[len(HOME) + 1:] if p.startswith(HOME + "/") else p


def make_logger(filename, quiet=False):
    def log(msg):
        line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
        if not quiet:
            print(msg, flush=True)
        try:
            os.makedirs(log_dir(), exist_ok=True)
            with open(os.path.join(log_dir(), filename), "a") as f:
                f.write(line + "\n")
        except OSError:
            pass
    return log


def run_configured(name, log=None):
    """Run the command in setting `name` (split like a shell line, no pipes; wrap those in `sh -c '...'`).
    Returns None when the setting is empty, else a CompletedProcess. A timeout
    (SESSION_KEEPER_HOOK_TIMEOUT seconds, default 30) or a crash comes back as code 124 / 127."""
    cmd = cfg(name)
    if not cmd:
        return None
    import shlex
    timeout = cfg_number("SESSION_KEEPER_HOOK_TIMEOUT", 30.0)
    try:
        r = run(shlex.split(cmd), timeout=timeout)
    except subprocess.TimeoutExpired:
        r = subprocess.CompletedProcess(cmd, 124, "", f"timed out after {timeout:g} s")
    except Exception as e:  # a bad setting must never break a save or a restore
        r = subprocess.CompletedProcess(cmd, 127, "", str(e))
    if log:
        log(f"{name}: rc={r.returncode} {((r.stdout or '') + (r.stderr or '')).strip()[:120]}")
    return r


def notify(text, log=None):
    """Send one line of text through SESSION_KEEPER_NOTIFY (any program that takes the text as its only
    argument, e.g. a push-message script). Not set = just print it."""
    cmd = cfg("SESSION_KEEPER_NOTIFY")
    if not cmd:
        print(text)
        return False
    import shlex
    try:
        r = run(shlex.split(cmd) + [text], timeout=60)
        if log:
            log(f"notify: rc={r.returncode} {(r.stdout + r.stderr).strip()[:80]}")
        return r.returncode == 0
    except Exception as e:  # never let a notifier break a restore
        if log:
            log(f"notify failed: {e}")
        return False
