# sk_config.sh - the config-file reader for the bash commands (claude-restart, claude-boot-reopen).
# Sourced, not run. Same rules as _read_config() in sk_common.py (tests/test_shell.sh checks they agree):
#   - KEY=VALUE lines; blank lines and lines starting with # are skipped; an optional "export " prefix
#   - one pair of matching surrounding quotes ("..." or '...') is removed; nothing else is unquoted
#   - only a leading ~ / ~/ or $HOME / ${HOME} (alone or followed by /) is replaced by your home folder;
#     no other $VARIABLE is expanded, so command settings reach their program as written
#   - a variable that is already set (non-empty) in the environment wins over the file
# (sk_common.py also normalizes the slashes of the path settings, which matters only on Windows.)

sk_load_config() {  # $1 = config file; exports each KEY found
  local conf="$1" line k v
  [[ -f "$conf" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" || "$line" != *=* ]] && continue
    k="${line%%=*}"; v="${line#*=}"
    k="${k%"${k##*[![:space:]]}"}"
    if [[ "$k" == "export "* ]]; then k="${k#export }"; k="${k#"${k%%[![:space:]]*}"}"; fi
    v="${v#"${v%%[![:space:]]*}"}"
    [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!k:-}" ]] && continue
    if [[ ${#v} -ge 2 && ( ( "${v:0:1}" == '"' && "${v: -1}" == '"' ) || ( "${v:0:1}" == "'" && "${v: -1}" == "'" ) ) ]]; then
      v="${v:1:${#v}-2}"
    fi
    if [[ "$v" == "~" || "$v" == "~/"* ]]; then v="$HOME${v:1}"
    elif [[ "$v" == '$HOME' || "$v" == '$HOME/'* ]]; then v="$HOME${v:5}"
    elif [[ "$v" == '${HOME}' || "$v" == '${HOME}/'* ]]; then v="$HOME${v:7}"
    fi
    printf -v "$k" '%s' "$v"; export "${k?}"
  done < "$conf"
}

