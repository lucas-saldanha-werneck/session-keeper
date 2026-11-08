# session-keeper

Restart your Mac, iTerm2, or a single Claude Code session without losing your windows or your
conversations.

With ten Claude Code sessions open across iTerm2 windows and tmux sessions, a reboot or an iTerm2
update means finding every folder and every conversation id again by hand. session-keeper takes a
snapshot of what is open (window positions, tabs, tmux sessions, the folder and the Claude session
id in each) and later reopens it all, with `claude --resume <id>` in the right place.

| Command | What it does |
|---|---|
| `claude-save` | Saves iTerm2 windows/tabs and tmux sessions with their Claude session ids. `--reopen` brings them back after a reboot. `--auto` (launchd, every 5 min) keeps the save fresh |
| `claude-iterm-restart` | Quits and reopens iTerm2 with every window where it was. `--update` installs the newest iTerm2 while it is closed |
| `claude-restart` | Restarts one Claude Code session at the end of its current turn, so new settings, hooks, plugins or MCP servers load without losing the conversation |
| `claude-boot-reopen` | Runs at login and calls `claude-save --reopen` in a new iTerm2 window |
| `claude-tmux-gc` | Closes empty tmux sessions left behind by Claude (no Claude process, no client attached) |
| `claude-folder-title` | Optional hook that puts the folder at the start of each session title (`acme/api · billing export`) |

## Example

Before a reboot:

```
$ claude-save
3 iTerm window(s)/tab(s):
  Claude 3f2a9c1e (api) [~/Projects/acme/api]  pos [0, 25, 800, 600]
  shell [~/Projects/acme/web]  pos [0, 25, 800, 600] (tab 2)
  Claude 8b41d0aa (docs) [~/Projects/docs]  pos [810, 25, 1600, 600]
1 tmux session(s) without a window:
  bg-worker: program `node server.js --port 3000` [~/Projects/acme/worker]

Ready to restart. Afterwards, in an iTerm window: claude-save --reopen
```

After it (or automatically at login, through `claude-boot-reopen`):

```
$ claude-save --reopen
save from 2026-11-08 10:15:02 (0.1 h ago)
will open 4 window(s)/tab(s) and 0 tmux session(s) without a window:
  ...
done: 2 of 2 conversation(s) up
```

A program that was running (like `node server.js`) comes back typed at the prompt but not started
(zsh only; other shells get an `echo` reminder). Sessions that were busy when you saved are listed
so you can wait for them first.

Reload config in the session you are in:

```
$ claude-restart --yes        # restarts at the end of the current turn
```

## Install

As a Claude Code plugin (hooks + skill):

```
/plugin marketplace add lucas-saldanha-werneck/session-keeper
/plugin install session-keeper@session-keeper
```

The command-line tools and the launchd jobs:

```
git clone https://github.com/lucas-saldanha-werneck/session-keeper
cd session-keeper
./install.sh --dry-run    # see what it would do
./install.sh
```

`install.sh` copies the tools to `~/.local/share/session-keeper`, links them into `~/.local/bin`,
and on macOS writes three launchd jobs (label prefix `com.claude-tools.session-keeper`, change it
with `--prefix`):

- `.autosave`: `claude-save --auto` every 5 minutes. It goes through `tmux run-shell` when tmux is
  installed, because tmux started from iTerm2 already has the macOS Automation permission to talk
  to iTerm2; a launchd job calling `osascript` directly can hang on that permission prompt.
- `.tmux-gc`: `claude-tmux-gc` daily at 05:30 (only when tmux is installed).
- `.boot-reopen`: `claude-boot-reopen` at login. It is written but not started during install;
  launchd loads it at your next login.

Other options: `--no-launchd`, `--bin-dir DIR`, `--force` (replace files in the bin dir that are
not ours).

The plugin adds three hooks: a SessionStart warning when auto-save is paused waiting for a
`--reopen`, the Stop hook that `claude-restart` needs, and the folder-title hook (off unless you
turn it on). Without the plugin, add `claude-restart --stop-hook` as a Stop hook in
`~/.claude/settings.json` yourself, or `claude-restart` schedules restarts that never fire (it
warns you about that).

Requires Python 3.8+ and bash.

## Configuration

Environment variables, or the same `KEY=VALUE` lines in `~/.config/session-keeper/config`
(launchd jobs do not see your shell profile, so the file is the place for settings they need).

**Your settings survive updates.** The config file lives outside both the plugin folder (which
Claude Code replaces on every plugin update) and the `install.sh` copy in
`~/.local/share/session-keeper` (replaced when you re-run it), so updating never touches it. The
plugin's `userConfig` (`/config` in Claude Code) only reaches the plugin's hooks; the commands run
from your shell and from launchd, so everything they read is in this file or the environment.
`SESSION_KEEPER_CONFIG` points to another file.

| Variable | Default | What it does |
|---|---|---|
| `SESSION_KEEPER_STATE_DIR` | `~/.local/state/session-keeper` | Saves, history copies (last 10) and the iTerm2 snapshot |
| `SESSION_KEEPER_LOG_DIR` | `~/Library/Logs` (macOS) | Log files |
| `SESSION_KEEPER_NOTIFY` | empty | A command that gets one line of text when `--reopen` finds sessions that did not come back, e.g. a script that sends you a push message |
| `SESSION_KEEPER_CLAUDE_ARGS` | empty | Extra arguments added to every `claude --resume` (e.g. `--remote-control`) |
| `SESSION_KEEPER_KEEP_ENV` | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS CLAUDE_CODE_DISABLE_NOTIFICATION_PRESENCE_CHECK` | Environment variables copied from each running Claude into its resume command |
| `SESSION_KEEPER_IGNORE_SESSIONS` | empty | tmux session names `claude-save` skips |
| `SESSION_KEEPER_TMUX` | found on `PATH` or in Homebrew | Path to tmux |
| `SESSION_KEEPER_SHELL` | `$SHELL` | Shell used for detached tmux sessions and for typed-back commands |
| `SESSION_KEEPER_ITERM_APP` | `/Applications/iTerm.app` | Where iTerm2 is |
| `SESSION_KEEPER_TMUX_PREFIX` | empty (all) | `claude-restart` only considers tmux sessions whose name starts with this |
| `SESSION_KEEPER_GC_PREFIX` | `claude-` | `claude-tmux-gc` only closes sessions whose name starts with this |
| `SESSION_KEEPER_FOLDER_TITLE` | off | `1` turns on the folder-title hook (or the plugin option `folder_title`) |
| `SESSION_KEEPER_TITLE_ROOTS` | empty | Colon-separated folders that titles are relative to (e.g. `~/Projects`); otherwise `~/<path>` |
| `SESSION_KEEPER_APP_NUDGE` | empty | Desktop app only: a command that gets `<session id> <message>` after `claude-restart` stopped an app session, to send it a message so it restarts right away |
| `CLAUDE_AUTO_RETRY_LAUNCHER` | Homebrew/npm global path | `claude-restart` restarts through the claude-auto-retry launcher when it is installed |
| `CLAUDE_SAVE_WAIT` | `60` | Seconds `--reopen` waits for the conversations to come up |
| `SESSION_KEEPER_PRE_SAVE` | empty | A command run before a manual `claude-save` (not `--auto`, not `--dry-run`). If it fails, a warning with its last output line is shown; the save still happens |
| `SESSION_KEEPER_PRE_REOPEN` | empty | A command run before `--reopen` opens anything, e.g. a check that your secrets manager is unlocked. If it fails, a warning is shown and the reopen goes on |
| `SESSION_KEEPER_PRE_REOPEN_FAIL_ENV` | empty | `KEY=VALUE` pairs put in front of every resumed `claude` command when `SESSION_KEEPER_PRE_REOPEN` failed (e.g. a flag that tells your shell wrapper not to wait for secrets) |
| `SESSION_KEEPER_POST_BOOT` | empty | A command `claude-boot-reopen` runs after it started the reopen (through `claude-save --post-boot`). Whatever it prints is sent to `SESSION_KEEPER_NOTIFY`, so it can report on the reboot |
| `SESSION_KEEPER_POST_BOOT_DELAY` | `0` | Seconds `claude-boot-reopen` waits before the post-boot command, so the sessions have time to come up |
| `SESSION_KEEPER_HOOK_TIMEOUT` | `30` | Seconds each of the three commands above may take; a timeout counts as a failure |
| `SESSION_KEEPER_DROP_ENV` | empty | Extra environment variables (space-separated) not passed to an iTerm2 that session-keeper launches, so new shells start clean (e.g. a "secrets already loaded" flag) |

The command settings are split like a shell line (quotes work; pipes and `&&` do not, wrap those in
`sh -c '...'`). launchd jobs run with a short `PATH` (`~/.local/bin`, Homebrew, system folders), so
use a full path for anything else.

Example `~/.config/session-keeper/config` for someone who keeps secrets in a password manager and
wants a phone message after a reboot:

```
SESSION_KEEPER_NOTIFY=~/.local/bin/push-me
SESSION_KEEPER_CLAUDE_ARGS=--remote-control
SESSION_KEEPER_TITLE_ROOTS=~/Projects
# warn before reopening when the vault is locked; sessions then start without waiting for it
SESSION_KEEPER_PRE_REOPEN=/bin/zsh -lic 'my-secrets --check'
SESSION_KEEPER_PRE_REOPEN_FAIL_ENV=SECRETS_LOADED=1
SESSION_KEEPER_DROP_ENV=SECRETS_LOADED
# 3 minutes after login, a script prints a one-line report that goes to push-me
SESSION_KEEPER_POST_BOOT=~/.local/bin/after-reboot-report
SESSION_KEEPER_POST_BOOT_DELAY=180
```

`CLAUDE_CONFIG_DIR` is respected.

## Optional requirements

None of these are needed for the rest to work.

- **iTerm2**: windows and tabs are saved and restored. Without it, `claude-save` saves only tmux
  sessions, and `--reopen` brings windows back as detached tmux sessions. `claude-iterm-restart`
  needs it and exits with a message otherwise. `claude-restart` falls back to Terminal.app, then to
  a detached tmux session.
- **tmux**: sessions without a window are saved and restored, and `claude-restart` restarts a session
  inside its own pane. Without tmux, Claude sessions running directly in iTerm2 tabs are still saved
  and resumed. If neither iTerm2 nor tmux is there, `--reopen` prints the commands to run.
- **A notifier** for `SESSION_KEEPER_NOTIFY`. Without one, problems go to the log and the screen.
- **[claude-auto-retry](https://www.npmjs.com/package/claude-auto-retry)**: used for the restarted
  session when installed; otherwise plain `claude --resume`.
- **The Claude desktop app**: `claude-restart` run from inside an app session stops only that
  session's process; the next message you send resumes it with the new config.
- **zsh**: needed to put a program's command back at the prompt. Other shells get a reminder line.

## Platform

macOS, with iTerm2 for the window parts and launchd for the scheduled jobs. `claude-restart`,
`claude-tmux-gc` and `claude-folder-title` also work on Linux with tmux, and `claude-save` there
saves and restores tmux sessions only (tested with fakes, not on a real Linux desktop).
`install.sh` on Linux installs the commands and skips launchd. Windows is not supported; only the
Python unit tests run there in CI.

## How it works

- Claude Code writes `~/.claude/sessions/<pid>.json` for each running interactive session, with its
  session id, folder and status (`busy` or idle). The tools read those files and match each process
  to its iTerm2 tab (by tty) or tmux pane (by process tree).
- iTerm2 is driven with AppleScript (`osascript`): list windows, create windows and tabs at the saved
  bounds, write the command into the new session.
- `claude-save --auto` does not overwrite a save made before the tmux server started (a reboot)
  until it has been reopened, so the Mac starting empty cannot erase the good save. After 24 hours
  the old save is treated as abandoned.
- Windows close one by one before a restart, and `--auto` may save the shrinking list. `--reopen`
  therefore uses, among the copies from the hour before the newest save, the one with the most
  conversations.
- `claude-iterm-restart` runs its second half from `tmux run-shell -b` (or a detached process) so it
  survives iTerm2 quitting. It turns off iTerm2's two quit prompts for the quit and puts them back.
  `--update` reads iTerm2's official appcast, checks the code signature and team id of the download,
  and keeps the old app if the check fails.
- `claude-restart` writes a marker; the Stop hook sees it at the end of the session's turn and
  restarts the session in the same tmux pane (`respawn-pane`), or in a new window. If no turn ends
  within `--wait` minutes, a macOS dialog asks whether to kill it now.

## Uninstall

```
./install.sh --uninstall
/plugin uninstall session-keeper@session-keeper
```

Your saves (`~/.local/state/session-keeper`) and config (`~/.config/session-keeper`) are kept;
delete them yourself if you want. If you added the tmux snapshot hook to `~/.tmux.conf`, remove it.

## Test

```
bash tests/run.sh
```

The Python tests run every command against a simulated system (process table, tmux sessions and
iTerm2 windows in memory). The shell tests run `claude-restart`, `claude-boot-reopen` and
`install.sh` with fake `tmux`, `ps`, `claude`, `osascript` and `launchctl` on `PATH` and a temporary
`HOME`. Nothing real is restarted. Not tested here: a real reboot, a real iTerm2 quit and update,
and the desktop app path.

## License

MIT

Built with Claude Code
