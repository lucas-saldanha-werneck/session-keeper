#!/bin/bash
# Tests for the shell parts: claude-restart, claude-boot-reopen and install.sh.
# Fake tmux, ps, claude, osascript and launchctl come first on PATH, HOME is a temp folder, and
# CLAUDE_RESTART_DRYRUN=1 makes the restart log what it would do. Nothing touches the real system.
set -u
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) echo "SKIP shell tests: claude-restart drives tmux and ps, which do not run natively on Windows"; exit 0 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
FAKE="$T/fakebin"; mkdir -p "$FAKE" "$T/home" "$T/claude" "$T/proj"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL $1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }
has()  { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "expected '$2' in: $(head -c 400 <<<"$3")"; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$3"; then bad "$1" "did not expect '$2'"; else ok "$1"; fi; }
wait_for() { local i; for i in $(seq 1 50); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

cat >"$FAKE/tmux" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_DIR/tmux-calls"
case "$1" in
  list-sessions) cat "$FAKE_DIR/tmux-sessions" 2>/dev/null ;;
  has-session) grep -q "^$3|" "$FAKE_DIR/tmux-sessions" 2>/dev/null ;;
  list-panes) awk -F'|' -v s="$4" -v f="$6" '$1==s { print (f ~ /pane_pid/ ? $3 : $2) }' "$FAKE_DIR/panes" ;;
  display-message) awk -F'|' -v p="$4" '$2==p { print $1 }' "$FAKE_DIR/panes" ;;
  *) exit 0 ;;
esac
EOF
cat >"$FAKE/ps" <<'EOF'
#!/bin/bash
# lines in $FAKE_DIR/ps: "pid ppid args"
if [[ "$*" == "-axo pid=,args=" ]]; then awk '{ $2=""; print }' "$FAKE_DIR/ps"; exit 0; fi
pid=""; field=""
while (( $# )); do case "$1" in -p) pid="$2"; shift ;; -o) field="$2"; shift ;; esac; shift; done
line="$(awk -v p="$pid" '$1==p' "$FAKE_DIR/ps")"
[[ -n "$line" ]] || exit 1
case "$field" in ppid=) awk '{ print $2 }' <<<"$line" ;; *) cut -d' ' -f3- <<<"$line" ;; esac
EOF
cat >"$FAKE/claude" <<'EOF'
#!/bin/bash
[[ "$1 $2" == "agents --json" ]] && cat "$FAKE_DIR/agents.json"
EOF
for p in osascript launchctl; do
  printf '#!/bin/bash\necho "%s $*" >>"$FAKE_DIR/calls"\n' "$p" >"$FAKE/$p"
done
chmod +x "$FAKE"/*

export FAKE_DIR="$T" HOME="$T/home" CLAUDE_CONFIG_DIR="$T/claude" SESSION_KEEPER_CONFIG="$T/none"
export PATH="$FAKE:$PATH" CLAUDE_RESTART_DRYRUN=1 CLAUDE_RESTART_POLL=1 CLAUDE_RESTART_FIRE_DELAY=0
export SESSION_KEEPER_TMUX="$FAKE/tmux" SESSION_KEEPER_ITERM_APP="$T/no-iTerm.app"
unset TMUX_PANE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_HOST_SESSION_ID SESSION_KEEPER_TMUX_PREFIX || true
R="$ROOT/bin/claude-restart"
LOG="$T/claude/restart-pending/restart.log"

# the world: tmux session "work" in $T/proj, pane %1 (pid 100) running claude (pid 200, session S1)
SID="11111111-2222-4333-8444-555555555555"
OLD="99999999-2222-4333-8444-555555555555"
echo "work|$T/proj" >"$T/tmux-sessions"
echo "shell-only|$T/elsewhere" >>"$T/tmux-sessions"
echo "work|%1|100" >"$T/panes"
printf '100 1 -zsh\n200 100 /usr/local/bin/claude --remote-control\n' >"$T/ps"
echo "[{\"pid\": 200, \"sessionId\": \"$SID\"}]" >"$T/agents.json"
SLUG="$(printf '%s' "$T/proj" | sed 's#[^A-Za-z0-9]#-#g')"
mkdir -p "$T/claude/projects/$SLUG"
touch "$T/claude/projects/$SLUG/$OLD.jsonl"; sleep 1; touch "$T/claude/projects/$SLUG/$SID.jsonl"
touch -t 202001010000 "$T/claude/projects/$SLUG/$SID.jsonl"   # the live session is NOT the newest file

echo "== claude-restart"
out="$(cd "$T/proj" && "$R" 2>&1)"
has "plan finds the tmux session" "SESSION  : work" "$out"
has "plan uses the live Claude's id, not the newest transcript" "RESUME ID: $SID" "$out"
has "plan only, nothing done" "PLAN (nothing done" "$out"
has "warns that the Stop hook is not registered" "Stop hook is NOT registered" "$out"
mkdir -p "$T/claude/plugins"; echo '{"plugins": {"session-keeper@session-keeper": []}}' >"$T/claude/plugins/installed_plugins.json"
out="$(cd "$T/proj" && "$R" 2>&1)"
hasnt "plugin install counts as a registered hook" "NOT registered" "$out"

printf '100 1 -zsh\n' >"$T/ps"
out="$(cd "$T/proj" && "$R" 2>&1)"
has "no live Claude: falls back to the newest transcript" "RESUME ID: $OLD" "$out"
has "and says so" "using the folder's newest transcript" "$out"
printf '100 1 -zsh\n200 100 /usr/local/bin/claude --remote-control\n' >"$T/ps"

out="$("$R" "$T/proj" --yes 2>&1)"
has "--yes schedules" "SCHEDULED" "$out"
[[ -f "$T/claude/restart-pending/$SID.marker" ]] && ok "marker written" || bad "marker written"
has "marker has the folder" "TARGET=$T/proj" "$(cat "$T/claude/restart-pending/$SID.marker" 2>/dev/null)"
out="$("$R" "$T/proj" --yes 2>&1)"
has "second --yes does not schedule twice" "Already scheduled" "$out"
out="$("$R" --pending 2>&1)"
has "--pending lists it" "work  $SID" "$out"

out="$(echo '{"session_id": "someone-else"}' | "$R" --stop-hook 2>&1)"
[[ -f "$T/claude/restart-pending/$SID.marker" ]] && ok "stop hook of another session does not fire" || bad "stop hook of another session does not fire"
echo "{\"session_id\": \"$SID\"}" | TMUX_PANE=%1 CLAUDE_AUTO_RETRY_LAUNCHER="$T/none.js" "$R" --stop-hook
if wait_for "$LOG" "DRYRUN respawn %1 (work)"; then ok "stop hook fires: respawn in the same pane"; else bad "stop hook fires" "$(tail -3 "$LOG")"; fi
has "respawn resumes the right id" "claude --resume '$SID'" "$(grep 'DRYRUN respawn' "$LOG")"
"$R" "$T/proj" --yes >/dev/null 2>&1; : >"$LOG"; touch "$T/launcher.js"
echo "{\"session_id\": \"$SID\"}" | TMUX_PANE=%1 CLAUDE_AUTO_RETRY_LAUNCHER="$T/launcher.js" "$R" --stop-hook
wait_for "$LOG" "DRYRUN respawn" ; has "uses the claude-auto-retry launcher when present" "node '$T/launcher.js' '--resume' '$SID'" "$(cat "$LOG")"
[[ ! -e "$T/claude/restart-pending/$SID.marker" && ! -e "$T/claude/restart-pending/$SID.firing" ]] && ok "marker consumed" || bad "marker consumed"

"$R" "$T/proj" --yes >/dev/null 2>&1
out="$("$R" --cancel "$T/proj" 2>&1)"
has "--cancel removes it" "cancelled: 1" "$out"

: >"$T/tmux-sessions"
out="$("$R" "$T/proj" --yes --now 2>&1)"
has "--now fires right away" "killing and reopening now" "$out"
if wait_for "$LOG" "DRYRUN would open: cd"; then ok "no tmux session left: reopens in a new window"; else bad "fallback to a new window" "$(tail -3 "$LOG")"; fi

start=$(date +%s); echo '{}' | "$R" --stop-hook; [[ $(( $(date +%s) - start )) -le 1 ]] && ok "stop hook fast path with nothing scheduled" || bad "stop hook fast path"
out="$("$R" --bogus 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && has "unknown option fails" "unknown option" "$out" || bad "unknown option fails"
out="$("$R" "$T/missing" 2>&1)"; has "missing folder fails" "folder does not exist" "$out"

echo "== claude-boot-reopen"
"$ROOT/bin/claude-boot-reopen" --dry-run
BLOG="$(ls "$T"/home/Library/Logs/claude-boot-reopen.log "$T"/home/.local/state/session-keeper/logs/claude-boot-reopen.log 2>/dev/null | head -1)"
has "without iTerm it runs claude-save --reopen directly" "no iTerm2: running claude-save --reopen --dry-run" "$(cat "$BLOG" 2>/dev/null)"
has "and claude-save reports there is no save yet" "Run claude-save before restarting" "$(cat "$BLOG" 2>/dev/null)"
hasnt "no post-boot command when none is set" "post-boot" "$(cat "$BLOG" 2>/dev/null)"
SESSION_KEEPER_POST_BOOT="echo hi" "$ROOT/bin/claude-boot-reopen" --dry-run
has "--dry-run only names the post-boot command" "dry-run: would run the post-boot command: echo hi" "$(cat "$BLOG")"
# claude-boot-reopen sets its own PATH (launchd has almost none): ~/.local/bin is on it, our fakes are not
UB="$T/home/.local/bin"; mkdir -p "$UB"
printf '#!/bin/bash\necho "$*" >>"$FAKE_DIR/notified"\n' >"$UB/notifier"; chmod +x "$UB/notifier"
printf '#!/bin/bash\necho "restarted: $1"\n' >"$UB/boot-report"; chmod +x "$UB/boot-report"
printf 'SESSION_KEEPER_POST_BOOT=boot-report "two words"\nSESSION_KEEPER_NOTIFY="notifier"\nSESSION_KEEPER_POST_BOOT_DELAY=0\n' >"$T/sk-config"
SESSION_KEEPER_CONFIG="$T/sk-config" "$ROOT/bin/claude-boot-reopen"
has "post-boot runs after the reopen (config file)" "post-boot finished (exit 0)" "$(cat "$BLOG")"
has "what it prints goes to the notifier" "restarted: two words" "$(cat "$T/notified" 2>/dev/null)"
printf 'SESSION_KEEPER_POST_BOOT=boot-report-missing\n' >"$T/sk-config"
SESSION_KEEPER_CONFIG="$T/sk-config" "$ROOT/bin/claude-boot-reopen"
rm -f "$UB/notifier" "$UB/boot-report"
has "a failing post-boot command is logged with its exit code" "post-boot finished (exit 1)" "$(cat "$BLOG")"

echo "== claude-boot-reopen: post-boot only after the reopen, with its result (review #2)"
UB="$T/home/.local/bin"; mkdir -p "$UB"; L2="$T/blogs"; B2="$L2/claude-boot-reopen.log"
printf '#!/bin/bash\necho "$*" >>"$FAKE_DIR/notified"\n' >"$UB/notifier"
printf '#!/bin/bash\necho "result=$SESSION_KEEPER_REOPEN_RESULT up=$SESSION_KEEPER_REOPEN_UP total=$SESSION_KEEPER_REOPEN_TOTAL"\n' >"$UB/boot-report"
printf '#!/bin/bash\necho Darwin\n' >"$UB/uname"
# fake osascript that, like iTerm, runs the reopen.command in the background
printf '#!/bin/bash\nc="$(sed -n "s/.* -l \\(.*\\)\\"$/\\1/p" <<<"$2")"\n[ -n "$c" ] && (bash "$c" </dev/null >/dev/null 2>&1 &)\nexit 0\n' >"$UB/osascript"
chmod +x "$UB"/*
mkdir -p "$T/iTerm.app"
printf 'SESSION_KEEPER_POST_BOOT=boot-report\nSESSION_KEEPER_NOTIFY=notifier\n' >"$T/sk-config2"
: >"$T/notified"
SHELL=/bin/bash SESSION_KEEPER_CONFIG="$T/sk-config2" SESSION_KEEPER_ITERM_APP="$T/iTerm.app" SESSION_KEEPER_LOG_DIR="$L2" \
  CLAUDE_BOOT_REOPEN_DELAY=0 SESSION_KEEPER_POST_BOOT_WAIT=30 "$ROOT/bin/claude-boot-reopen"
has "iTerm path: waits for the reopen window, then passes its result" "result=failed up= total=" "$(cat "$T/notified")"
has "the result is logged before the post-boot command" "reopen result: failed" "$(cat "$B2")"
o="$(grep -n 'reopen result' "$B2" | head -1 | cut -d: -f1)"; f="$(grep -n 'post-boot finished' "$B2" | head -1 | cut -d: -f1)"
[[ -n "$o" && -n "$f" && "$o" -lt "$f" ]] && ok "post-boot runs after the reopen finished" || bad "post-boot order" "$(cat "$B2")"

: >"$T/notified"; : >"$B2"
printf '#!/bin/bash\nexit 1\n' >"$UB/osascript"; chmod +x "$UB/osascript"
SHELL=/bin/bash SESSION_KEEPER_CONFIG="$T/sk-config2" SESSION_KEEPER_ITERM_APP="$T/iTerm.app" SESSION_KEEPER_LOG_DIR="$L2" \
  CLAUDE_BOOT_REOPEN_DELAY=0 CLAUDE_BOOT_RETRY_DELAY=0 SESSION_KEEPER_POST_BOOT_WAIT=2 "$ROOT/bin/claude-boot-reopen"; rc=$?
[[ $rc -eq 1 ]] && ok "iTerm could not be opened: exit 1" || bad "iTerm could not be opened: exit 1" "rc=$rc"
hasnt "and the post-boot command is skipped" "result=" "$(cat "$T/notified")"
has "the failure goes to the notifier instead" "could not open iTerm after login" "$(cat "$T/notified")"
rm -f "$UB/uname" "$UB/osascript" "$UB/notifier" "$UB/boot-report"

echo "== config readers agree (review #3, #4, #6, #10)"
cat >"$T/parity.conf" <<'PARITY'
# comment
P_PLAIN=plain value
P_SQ='single quoted $HOME'
P_DQ="double quoted"
P_INNER=cmd "two words" 'and $X'
P_TILDE=~/x
P_TILDE_ONLY=~
P_TILDE_USER=~root/x
P_HOME=$HOME/bin/push --url https://example.com//a
P_HOME_BRACES=${HOME}
P_HOMEX=$HOMEX/y
P_VAR=$USER and ${PATH}
  export P_EXPORT = spaced
P_EMPTY=
P_EQ=a=b=c
NOT A KEY=1
P_CRLF=windows
PARITY
printf 'P_CR=x\r\n' >>"$T/parity.conf"
keys="P_PLAIN P_SQ P_DQ P_INNER P_TILDE P_TILDE_ONLY P_TILDE_USER P_HOME P_HOME_BRACES P_HOMEX P_VAR P_EXPORT P_EMPTY P_EQ P_CRLF P_CR"
PYV="$(cd "$ROOT" && python3 -c 'import sys; sys.path.insert(0, "lib"); import sk_common as c
d = c._read_config(sys.argv[1])
for k in sys.argv[2].split(): print(k + "=" + d.get(k, "<unset>"))' "$T/parity.conf" "$keys")"
SHV="$(env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1/lib/sk_config.sh"; sk_load_config "$2"
for k in $3; do if [[ -n "${!k+x}" ]]; then printf "%s=%s\n" "$k" "${!k}"; else printf "%s=<unset>\n" "$k"; fi; done' _ "$ROOT" "$T/parity.conf" "$keys")"
if [[ "$PYV" == "$SHV" ]]; then ok "Python and bash readers give the same values"; else bad "readers differ" "$(diff <(echo "$PYV") <(echo "$SHV"))"; fi
has "single-quoted \$HOME is not expanded" "P_SQ=single quoted \$HOME" "$SHV"
has "a URL inside a command keeps its //" "P_HOME=$HOME/bin/push --url https://example.com//a" "$SHV"
has "other variables are not expanded" 'P_VAR=$USER and ${PATH}' "$SHV"

echo "== install.sh"
: >"$T/calls"
out="$(SESSION_KEEPER_INSTALL_OS=Darwin "$ROOT/install.sh" --dry-run 2>&1)"
[[ ! -e "$T/home/.local/bin/claude-save" && ! -e "$T/home/Library/LaunchAgents" ]] && ok "--dry-run changes nothing" || bad "--dry-run changes nothing"
has "--dry-run shows the plan" "would write $T/home/Library/LaunchAgents/com.claude-tools.session-keeper.autosave.plist" "$out"

out="$(SESSION_KEEPER_INSTALL_OS=Darwin "$ROOT/install.sh" --prefix org.example.sk 2>&1)"
for c in claude-save claude-iterm-restart claude-restart claude-restart-app claude-boot-reopen claude-tmux-gc claude-folder-title; do
  [[ -L "$T/home/.local/bin/$c" && -x "$T/home/.local/bin/$c" ]] || bad "linked $c"
done
ok "all 7 commands linked"
out2="$("$T/home/.local/bin/claude-save" --dry-run 2>&1)"
has "installed claude-save runs from its symlink (finds lib/)" "dry-run: nothing saved" "$out2"
SEEDED="$T/seeded/session-keeper/config"
SESSION_KEEPER_CONFIG="$SEEDED" "$T/home/.local/bin/claude-save" --dry-run >/dev/null 2>&1
cmp -s "$SEEDED" "$ROOT/config.example" && ok "installed claude-save seeds the config from its installed starter" \
  || bad "installed claude-save seeds the config" "$(ls -la "$T/seeded/session-keeper" "$T/home/.local/share/session-keeper" 2>&1)"
SHV="$(env -i HOME="$HOME" PATH="$PATH" bash -c '. "$1/lib/sk_config.sh"; before="$(export -p)"; sk_load_config "$2"
[[ "$(export -p)" == "$before" ]] && echo same' _ "$ROOT" "$SEEDED")"
[[ "$SHV" == same ]] && ok "the bash reader exports nothing from the seeded config" || bad "bash reader exported from the starter"
out2="$("$T/home/.local/bin/claude-restart" --pending 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && hasnt "installed claude-restart finds lib/sk_config.sh through its symlink" "sk_config.sh" "$out2" \
  || bad "installed claude-restart runs from its symlink" "rc=$rc $out2"
A="$T/home/Library/LaunchAgents"
for l in autosave tmux-gc boot-reopen; do
  f="$A/org.example.sk.$l.plist"
  if python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert d["Label"]==sys.argv[2]' "$f" "org.example.sk.$l" 2>/dev/null; then
    ok "plist $l is valid and labelled"; else bad "plist $l"; fi
done
has "autosave goes through tmux" "<string>$FAKE/tmux</string>" "$(cat "$A/org.example.sk.autosave.plist")"
has "plists use the real home" "$T/home/.local/share/session-keeper/bin/claude-boot-reopen" "$(cat "$A/org.example.sk.boot-reopen.plist")"
calls="$(cat "$T/calls")"
has "autosave job started" "launchctl bootstrap gui/$(id -u) $A/org.example.sk.autosave.plist" "$calls"
has "tmux-gc job started" "org.example.sk.tmux-gc.plist" "$calls"
hasnt "boot-reopen NOT started now" "bootstrap gui/$(id -u) $A/org.example.sk.boot-reopen.plist" "$calls"

echo "not ours" >"$T/home/.local/bin/claude-tmux-gc.keep"
out="$(SESSION_KEEPER_INSTALL_OS=Darwin "$ROOT/install.sh" --uninstall --prefix org.example.sk 2>&1)"
[[ ! -e "$T/home/.local/bin/claude-save" && ! -e "$A/org.example.sk.autosave.plist" && ! -d "$T/home/.local/share/session-keeper" ]] \
  && ok "--uninstall removes commands, plists and the copy" || bad "--uninstall"
[[ -f "$T/home/.local/bin/claude-tmux-gc.keep" ]] && ok "--uninstall leaves other files" || bad "--uninstall leaves other files"
has "--uninstall stops the jobs" "launchctl bootout gui/$(id -u)/org.example.sk.autosave" "$(cat "$T/calls")"

echo "mine" >"$T/home/.local/bin/claude-save"
out="$(SESSION_KEEPER_INSTALL_OS=Linux "$ROOT/install.sh" 2>&1)"
[[ "$(cat "$T/home/.local/bin/claude-save")" == mine ]] && ok "does not overwrite a foreign file without --force" || bad "foreign file overwritten"
has "Linux: no launchd jobs" "not macOS: no launchd jobs" "$out"
out="$("$ROOT/install.sh" --prefix 'bad prefix' 2>&1)"; has "rejects a bad prefix" "invalid --prefix" "$out"

echo
echo "shell tests: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
