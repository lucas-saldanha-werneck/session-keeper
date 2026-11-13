# Security Policy

## Reporting a vulnerability

Please report it privately: open the repository's **Security** tab and choose **Report a vulnerability**
(https://github.com/lucas-saldanha-werneck/session-keeper/security/advisories/new). Please do not open a public issue for a
security problem.

## Supported versions

Only the latest release (0.2.10) is supported. Fixes go into a new release.

## What session-keeper accesses

- Reads `~/.claude/sessions/<pid>.json` (session id, folder, status) and the process list, and drives iTerm2 with AppleScript (`osascript`) and tmux, to save and reopen your windows and conversations.
- Saves snapshots (window positions, folders, session ids, tmux names) under `~/.local/state/session-keeper`, and keeps its settings in `~/.config/session-keeper/config`, created private (`0600`) because it can hold commands that carry a token.
- `install.sh` copies the tools to `~/.local/share/session-keeper`, links them into `~/.local/bin` and, on macOS, writes three launchd jobs (one runs `claude-save --auto` every 5 minutes).
- Runs the commands you set in the config (pre-save, pre-reopen, post-boot, notify) and resumes `claude` with them.
- Network: only `claude-iterm-restart --update` uses it. It downloads the newest iTerm2 from iterm2.com, checks the signature against iTerm2's Apple team id, and swaps the app.
