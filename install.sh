#!/bin/bash
# install.sh - install the session-keeper commands into ~/.local/bin and (macOS) the launchd jobs.
#
#   ./install.sh                 install (copies to ~/.local/share/session-keeper, symlinks into ~/.local/bin)
#   ./install.sh --dry-run       show what would be done, change nothing
#   ./install.sh --uninstall     remove the commands and the launchd jobs (keeps your saves and config;
#                                removes the copy folder only when it holds a session-keeper install)
#   ./install.sh --no-launchd    commands only, no launchd jobs
#   ./install.sh --prefix P      launchd label prefix (default com.claude-tools.session-keeper)
#   ./install.sh --bin-dir D     where the command symlinks go (default ~/.local/bin)
#   ./install.sh --force         replace existing files in the bin dir that are not ours
#
# launchd jobs (macOS):
#   <prefix>.autosave      claude-save --auto every 5 minutes (through tmux when a tmux server is up:
#                          tmux, started from iTerm, already has the Automation permission for iTerm;
#                          directly when no tmux server runs)
#   <prefix>.tmux-gc       claude-tmux-gc daily at 05:30 (only when tmux is installed)
#   <prefix>.boot-reopen   claude-boot-reopen at login. Written but NOT started now (it would open
#                          windows right away); launchd loads it at your next login.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0; UNINSTALL=0; LAUNCHD=1; FORCE=0
PREFIX="com.claude-tools.session-keeper"
BIN_DIR="$HOME/.local/bin"
SHARE="${SESSION_KEEPER_SHARE_DIR:-$HOME/.local/share/session-keeper}"
AGENTS="$HOME/Library/LaunchAgents"
OS="${SESSION_KEEPER_INSTALL_OS:-$(uname -s)}"
CMDS=(claude-save claude-iterm-restart claude-restart claude-restart-app claude-boot-reopen claude-tmux-gc claude-folder-title)

while (( $# )); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --no-launchd) LAUNCHD=0 ;;
    --force) FORCE=1 ;;
    --prefix) shift; PREFIX="${1:?--prefix needs a value}" ;;
    --bin-dir) shift; BIN_DIR="${1:?--bin-dir needs a value}" ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "invalid --prefix: $PREFIX" >&2; exit 2; }

do_() {  # run, or print in --dry-run
  if (( DRY )); then printf 'would run:'; printf ' %q' "$@"; printf '\n'; else "$@"; fi
}
xml() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }

if [[ "$OS" == Darwin ]]; then LOGDIR="$HOME/Library/Logs"; else LOGDIR="$HOME/.local/state/session-keeper/logs"; fi
TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux; do [[ -z "$TMUX_BIN" && -x "$c" ]] && TMUX_BIN="$c"; done
PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
UID_="$(id -u)"
LABELS=("$PREFIX.autosave" "$PREFIX.tmux-gc" "$PREFIX.boot-reopen")

# ---------- uninstall ----------
if (( UNINSTALL )); then
  if [[ "$OS" == Darwin ]]; then
    for l in "${LABELS[@]}"; do
      if [[ -f "$AGENTS/$l.plist" ]]; then
        do_ launchctl bootout "gui/$UID_/$l" || true
        do_ rm -f "$AGENTS/$l.plist"
      fi
    done
  fi
  for c in "${CMDS[@]}"; do
    t="$BIN_DIR/$c"
    if [[ -L "$t" && "$(readlink "$t")" == "$SHARE/bin/$c" ]]; then do_ rm -f "$t"; fi
  done
  # SHARE can come from SESSION_KEEPER_SHARE_DIR: never rm -rf it. Only the files install.sh copies are
  # removed, and the folders only when that leaves them empty.
  if [[ -d "$SHARE" ]]; then
    if [[ -f "$SHARE/bin/claude-save" && -f "$SHARE/lib/sk_common.py" ]]; then
      for c in "${CMDS[@]}"; do [[ -e "$SHARE/bin/$c" ]] && do_ rm -f "$SHARE/bin/$c"; done
      for f in lib/sk_common.py lib/sk_config.sh config.example; do [[ -e "$SHARE/$f" ]] && do_ rm -f "$SHARE/$f"; done
      [[ -d "$SHARE/lib/__pycache__" ]] && do_ rm -rf "$SHARE/lib/__pycache__"
      for d in "$SHARE/bin" "$SHARE/lib" "$SHARE"; do [[ -d "$d" ]] && { do_ rmdir "$d" 2>/dev/null || echo "kept $d: it holds other files" >&2; }; done
    else
      echo "not removing $SHARE: it does not look like a session-keeper install (no bin/claude-save and lib/sk_common.py)" >&2
    fi
  fi
  echo "session-keeper removed. Kept: your saves (~/.local/state/session-keeper) and config (~/.config/session-keeper)."
  exit 0
fi

# ---------- install ----------
command -v python3 >/dev/null || echo "WARNING: python3 not found; the commands need Python 3.8+." >&2
do_ mkdir -p "$SHARE/bin" "$SHARE/lib" "$BIN_DIR"
for c in "${CMDS[@]}"; do
  do_ cp "$SRC/bin/$c" "$SHARE/bin/$c"
  do_ chmod 755 "$SHARE/bin/$c"
done
do_ cp "$SRC/lib/sk_common.py" "$SHARE/lib/sk_common.py"
do_ cp "$SRC/lib/sk_config.sh" "$SHARE/lib/sk_config.sh"
do_ cp "$SRC/config.example" "$SHARE/config.example"   # starter the commands copy to ~/.config on first run
for c in "${CMDS[@]}"; do
  t="$BIN_DIR/$c"
  if [[ -e "$t" && ! -L "$t" && "$FORCE" != 1 ]]; then
    echo "skipped $t: a file that is not ours is already there (use --force to replace it)" >&2
    continue
  fi
  do_ ln -sfn "$SHARE/bin/$c" "$t"
done
echo "commands linked into $BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "NOTE: $BIN_DIR is not on your PATH; add it to use the commands by name." ;; esac

write_plist() {  # $1 label, $2 schedule xml, $3.. program arguments
  local label="$1" sched="$2" f="$AGENTS/$1.plist" a body
  shift 2
  body=""
  for a in "$@"; do body+="		<string>$(xml "$a")</string>"$'\n'; done
  if (( DRY )); then echo "would write $f ($*)"; return 0; fi
  mkdir -p "$AGENTS" "$LOGDIR"
  cat >"$f" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(xml "$label")</string>
	<key>ProgramArguments</key>
	<array>
${body}	</array>
${sched}
	<key>StandardOutPath</key>
	<string>$(xml "$LOGDIR/$label.out.log")</string>
	<key>StandardErrorPath</key>
	<string>$(xml "$LOGDIR/$label.out.log")</string>
</dict>
</plist>
EOF
}
load_job() {
  do_ launchctl bootout "gui/$UID_/$1" 2>/dev/null || true
  do_ launchctl bootstrap "gui/$UID_" "$AGENTS/$1.plist"
}

if (( LAUNCHD )) && [[ "$OS" == Darwin ]]; then
  if [[ -n "$TMUX_BIN" ]]; then
    # Through tmux when a server is up (it has iTerm's Automation permission); `tmux run-shell` fails
    # without a server, so then claude-save runs directly. Every path is shell-quoted (spaces are fine).
    SAVE_CMD="$(printf '%q' "$SHARE/bin/claude-save") --auto >/dev/null 2>&1 || true"
    T_="$(printf '%q' "$TMUX_BIN")"
    JOB="if $T_ has-session 2>/dev/null; then exec $T_ run-shell -b $(printf '%q' "$SAVE_CMD"); else exec $(printf '%q' "$PY") $(printf '%q' "$SHARE/bin/claude-save") --auto; fi"
    write_plist "$PREFIX.autosave" $'\t<key>StartInterval</key>\n\t<integer>300</integer>' /bin/sh -c "$JOB"
  else
    write_plist "$PREFIX.autosave" $'\t<key>StartInterval</key>\n\t<integer>300</integer>' "$PY" "$SHARE/bin/claude-save" --auto
  fi
  load_job "$PREFIX.autosave"
  if [[ -n "$TMUX_BIN" ]]; then
    write_plist "$PREFIX.tmux-gc" $'\t<key>StartCalendarInterval</key>\n\t<dict>\n\t\t<key>Hour</key>\n\t\t<integer>5</integer>\n\t\t<key>Minute</key>\n\t\t<integer>30</integer>\n\t</dict>' "$PY" "$SHARE/bin/claude-tmux-gc"
    load_job "$PREFIX.tmux-gc"
  else
    echo "tmux not found: skipped the tmux-gc job"
  fi
  write_plist "$PREFIX.boot-reopen" $'\t<key>RunAtLoad</key>\n\t<true/>' "$SHARE/bin/claude-boot-reopen"
  echo "launchd jobs written to $AGENTS (prefix $PREFIX); boot-reopen starts at your next login"
elif (( LAUNCHD )); then
  echo "not macOS: no launchd jobs. To run claude-tmux-gc daily, add a cron line, e.g.: 30 5 * * * $SHARE/bin/claude-tmux-gc"
fi

cat <<EOF

Optional, for claude-iterm-restart --reopen after a crash (keeps a fresh snapshot), add to ~/.tmux.conf:
  set-hook -g client-attached 'run-shell -b "$SHARE/bin/claude-iterm-restart --snapshot --quiet >/dev/null 2>&1 || true"'
  set-hook -g client-focus-in 'run-shell -b "$SHARE/bin/claude-iterm-restart --snapshot --quiet >/dev/null 2>&1 || true"'
Hooks (auto-save warning, claude-restart at end of turn, folder titles) come with the Claude Code plugin:
  /plugin marketplace add lucas-saldanha-werneck/lucas-tools
  /plugin install session-keeper@lucas-tools
EOF
