---
name: session-keeper
description: Restart the Mac, iTerm2 or one Claude Code session without losing windows or conversations. Use when the user says "restart my Mac without losing my sessions", "save my sessions before I reboot", "reopen my sessions", "restart iTerm", "update iTerm without losing windows", "restart this session so the new config loads", "reload settings/hooks/plugins/MCP", or "clean up empty tmux sessions".
metadata:
  author: Lucas Saldanha Werneck <lucas@2olhares.com>
---

# session-keeper

The commands live in `${CLAUDE_PLUGIN_ROOT}/bin/` (or in `~/.local/bin` after `./install.sh`).
Run them with `python3 "${CLAUDE_PLUGIN_ROOT}/bin/<name>"` for the Python ones and
`bash "${CLAUDE_PLUGIN_ROOT}/bin/claude-restart"` when they are not on `PATH`.

## Instructions

1. Pick the command from the table by what the user wants.
2. Run the `--dry-run` form first and show the plan.
3. Run the real command, following the rules below.

Pick by what the user wants:

| User wants | Command |
|---|---|
| Restart the Mac and get everything back | `claude-save` before; after the reboot, in an iTerm window, `claude-save --reopen` |
| See what would be saved / reopened | `claude-save --dry-run`, `claude-save --reopen --dry-run` |
| Restart (or update) iTerm2 only | `claude-iterm-restart` (`--update` installs the newest iTerm2) |
| Load new config in THIS session | `claude-restart --yes` (restarts at the end of the turn) |
| Close empty tmux sessions | `claude-tmux-gc --dry-run`, then without `--dry-run` |

Rules:

1. Always run the `--dry-run` form first and show the user the plan. `claude-restart` without `--yes`
   is already a dry run.
2. Before a Mac restart, read the end of the `claude-save` output. If it lists sessions that are
   working right now, tell the user to wait for them and run `claude-save` again.
3. When `claude-save --reopen` is run from inside a Claude session, add `--keep-window`, or the
   window it was run from may be closed.
4. `claude-iterm-restart` quits iTerm2. Claude sessions outside tmux are stopped after they go idle
   and resumed afterwards. Tell the user before running it.
5. If a SessionStart message says "Auto-save PAUSED", tell the user first and offer
   `claude-save --reopen --keep-window`.
6. macOS only for the iTerm parts. Do not run them on other systems.

## Examples

- "restart my Mac without losing my sessions": `claude-save` before the reboot; afterwards, in an iTerm window, `claude-save --reopen`.
- "restart iTerm": `claude-iterm-restart` (after telling the user it quits iTerm2).
- "restart this session so the new config loads": `claude-restart --yes` restarts it at the end of the turn.
- "clean up empty tmux sessions": `claude-tmux-gc --dry-run`, then without `--dry-run`.
