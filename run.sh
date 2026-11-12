#!/usr/bin/env bash
# Toon in a window on your current desktop (nested), from a Shady build tree
# and shady-shell (env.sh says where they are looked for).
set -euo pipefail
source "$(dirname "$0")/env.sh"

export SHADY_LUA_INIT="$RICE/init.lua"
export WLR_BACKENDS="${WLR_BACKENDS:-wayland}"
export SHADY_SHELL_CONFIG="${SHADY_SHELL_CONFIG:-$RICE/shell.lua}"

if [[ $# -eq 0 ]]; then
  default_startup="'$SHADY_SHELL_BIN' & exec ${TERMINAL:-foot}"
  set -- -s "${SHADY_STARTUP:-$default_startup}"
fi

exec "$SHADY_BUILD_DIR/shady" -c "$RICE/config.lua" "$@"
