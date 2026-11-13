# Changelog

All notable changes to this project are documented here. Versions follow [Semantic Versioning](https://semver.org/).

## [0.2.11] - 2026-11-13
- Skill schema and score: version and tags in the frontmatter, third-person description, Purpose, Prerequisites, Limitations and Troubleshooting sections; skill score badge.
- README: demo video and badges; adds SECURITY.md.

## [0.2.10] - 2026-11-13
- Author metadata, Instructions and Examples in the skills.

## [0.2.9] - 2026-11-12
- `claude-restart` survives a closed pipe before it writes its marker.

## [0.2.8] - 2026-11-12
- `claude-iterm-restart` never kills a busy Claude and closes a window only when every tab is idle; `claude-restart` restarts the pane where the turn ended.
- `claude-save`: atomic writes, reboot detected by the boot id, a reused pid is not killed.
- `claude-tmux-gc` keeps panes running any program; autosave falls back to `claude-save --auto` when no tmux server runs.

## [0.2.7] - 2026-11-11
- `claude-restart` uses tmux mode when a terminal is above, even with an inherited app entrypoint.

## [0.2.6] - 2026-11-11
- Scrubs the calling Claude session's variables before starting tmux.

## [0.2.5] - 2026-11-11
- Points to the catalog repo's new name, `lucas-tools`.

## [0.2.4] - 2026-11-11
- Catalog renamed to `lucas-tools`.

## [0.2.3] - 2026-11-11
- `claude-save --reopen` runs one at a time.

## [0.2.2] - 2026-11-10
- `claude-save --auto` runs one at a time, with a deadline.

## [0.2.1] - 2026-11-09
- Docs: short description, catalog install, settings headings.

## [0.2.0] - 2026-11-08
- Config file: pre-save, pre-reopen and post-boot commands, `drop-env`; created on first run (private, `0600`).

## [0.1.0] - 2026-11-08
- First release: save and reopen iTerm2 windows, tmux sessions and Claude Code conversations across restarts.
