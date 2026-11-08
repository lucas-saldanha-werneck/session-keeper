#!/bin/bash
# Run all tests. Works on macOS, Linux and Windows (Git Bash); the shell tests skip themselves on Windows.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PY="$(command -v python3 || command -v python)"
rc=0
"$PY" -m py_compile lib/sk_common.py && for f in bin/claude-save bin/claude-iterm-restart bin/claude-restart-app bin/claude-tmux-gc bin/claude-folder-title; do
  "$PY" -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$f" || rc=1
done
for f in bin/claude-restart bin/claude-boot-reopen install.sh tests/*.sh; do bash -n "$f" || rc=1; done
"$PY" tests/test_python.py -v || rc=1
bash tests/test_shell.sh || rc=1
exit $rc
