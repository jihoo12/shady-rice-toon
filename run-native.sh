#!/usr/bin/env bash
# Toon on a real VT (Ctrl+Alt+F3, log in, run this), from a Shady build tree
# and shady-shell (env.sh says where they are looked for).
set -euo pipefail
source "$(dirname "$0")/env.sh"

export SHADY_LUA_INIT="$RICE/init.lua"
export SHADY_SHELL_CONFIG="${SHADY_SHELL_CONFIG:-$RICE/shell.lua}"

if [[ $# -eq 0 ]]; then
  set -- -s "${SHADY_STARTUP:-'$SHADY_SHELL_BIN'}"
fi

exec "$ROOT/tools/run-native.sh" -c "$RICE/config.lua" "$@"
