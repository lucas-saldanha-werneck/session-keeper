# Security Policy

## Reporting a vulnerability

Please report it privately: open the repository's **Security** tab and choose **Report a vulnerability**
(https://github.com/lucas-saldanha-werneck/session-keeper/security/advisories/new). Please do not open a public issue for a
security problem.

## Supported versions

Only the latest release is supported. Fixes go into a new release.

## What session-keeper accesses

- Reads `~/.claude/sessions/<pid>.json`, the process list (command lines, and with `ps -E` the environment of Claude processes, to copy the variables named in `SESSION_KEEPER_KEEP_ENV`), tmux pane contents, transcript names under `~/.claude/projects`, and the desktop app's `~/Library/Logs/Claude/main.log`.
- Controls other apps and processes: through AppleScript (`osascript`) it opens, closes and quits iTerm2 windows and runs commands in them (Terminal.app as a fallback), briefly turns off iTerm2's quit prompts with `defaults write` and restores them, shows a dialog, and stops `claude` processes (SIGTERM, then SIGKILL) to restart them. It kills or respawns tmux sessions and types a program's last command (without Enter) into a restored tmux session.
- Writes snapshots (window positions, folders, session ids, tmux names, the command lines of programs running in tmux, and the kept variable values) to `~/.local/state/session-keeper` (owner-only files), restart markers and a log to `~/.claude/restart-pending` (markers are read back as shell code), logs to `~/Library/Logs`, and its settings to `~/.config/session-keeper/config`, created owner-only (`0600`) because it can hold commands that carry a token.
- `install.sh` copies the tools to `~/.local/share/session-keeper`, links them into `~/.local/bin` and, on macOS, writes launchd jobs: `claude-save --auto` every 5 minutes, `claude-tmux-gc` daily (only if tmux is installed) and `claude-boot-reopen` at your next login.
- Runs the commands you set in the config (pre-save, pre-reopen, post-boot, notify, app nudge; the text is passed as an argument) and resumes `claude --resume <id>` with your `SESSION_KEEPER_CLAUDE_ARGS`.
- Network: only `claude-iterm-restart --update` uses it. It reads iTerm2's appcast from iterm2.com, downloads the zip it lists with `curl`, checks the code signature and iTerm2's Apple team id, and replaces `/Applications/iTerm.app` (the old copy stays in a temporary folder).
