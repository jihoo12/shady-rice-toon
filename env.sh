# Sourced by run.sh, run-native.sh and capture.sh: where this rice, Shady
# (with Tide's compositor side, which Toon builds on) and shady-shell are.
#
#   SHADY_ROOT       a built Shady checkout (default: ../shady next to this one)
#   SHADY_SHELL_BIN  shady-shell (default: ../shady-shell/build/shady-shell,
#                    else the one on PATH)
RICE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SHADY_ROOT:-$RICE/../shady}"
if [[ ! -f "$ROOT/rices/tide/config.lua" ]]; then
  echo "Toon: no Shady checkout at $ROOT. Set SHADY_ROOT to a built one." >&2
  exit 1
fi
ROOT="$(cd "$ROOT" && pwd)"
SHADY_BUILD_DIR="$ROOT/${SHADY_BUILD:-build}"
if [[ -z "${SHADY_SHELL_BIN:-}" ]]; then
  if [[ -x "$RICE/../shady-shell/build/shady-shell" ]]; then
    SHADY_SHELL_BIN="$(cd "$RICE/../shady-shell/build" && pwd)/shady-shell"
  else
    SHADY_SHELL_BIN="$(command -v shady-shell || true)"
  fi
fi
if [[ ! -x "$SHADY_SHELL_BIN" ]]; then
  echo "Toon: no shady-shell. Build ../shady-shell or set SHADY_SHELL_BIN." >&2
  exit 1
fi
export SHADY_SHELL_BIN
export SHADY_ROOT="$ROOT"
# Rices are looked up by name: Toon under its own, Tide in Shady's rices/.
SHADY_RICE_PATH="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/shady-rices-$(id -u)"
mkdir -p "$SHADY_RICE_PATH"
ln -sfn "$RICE" "$SHADY_RICE_PATH/toon"
export SHADY_RICE_PATH
