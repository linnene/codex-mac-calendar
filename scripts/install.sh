#!/usr/bin/env bash
# Build the bridge, then register this repository as a Codex plugin marketplace
# and install the mac-calendar plugin from it.
#
#   scripts/install.sh            build, register, install
#   scripts/install.sh --no-build skip the build step
#   scripts/install.sh --check    only report what is currently registered
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_NAME="mac-calendar"
MARKETPLACE_NAME="mac-calendar-local"
DO_BUILD=1
CHECK_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --no-build) DO_BUILD=0 ;;
    --check) CHECK_ONLY=1 ;;
  esac
done

# ---------------------------------------------------------------- locate codex
find_codex() {
  if [[ -n "${CODEX_CLI_PATH:-}" && -x "${CODEX_CLI_PATH}" ]]; then
    printf '%s' "$CODEX_CLI_PATH"
    return 0
  fi
  local candidate
  for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
    "$(command -v codex 2>/dev/null || true)"
  do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    # The PATH shim forwards to the real binary; make sure it answers.
    if "$candidate" --version >/dev/null 2>&1; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

if ! CODEX="$(find_codex)"; then
  echo "error: could not find a working codex CLI." >&2
  echo "       Set CODEX_CLI_PATH to the codex binary and retry." >&2
  exit 1
fi
echo "codex: $CODEX ($("$CODEX" --version 2>&1 | head -1))"

if [[ "$CHECK_ONLY" == "1" ]]; then
  "$CODEX" plugin marketplace list
  echo ""
  "$CODEX" plugin list
  exit 0
fi

# ---------------------------------------------------------------------- build
if [[ "$DO_BUILD" == "1" ]]; then
  "$ROOT/scripts/build.sh"
fi

BIN="$ROOT/plugins/mac-calendar/bin/mac-calendar-bridge"
if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN is missing. Run scripts/build.sh first." >&2
  exit 1
fi

# ------------------------------------------------------------------ register
if "$CODEX" plugin marketplace list 2>/dev/null | grep -q "^${MARKETPLACE_NAME}\b"; then
  echo "marketplace '$MARKETPLACE_NAME' already registered"
else
  "$CODEX" plugin marketplace add "$ROOT"
fi

if "$CODEX" plugin list 2>/dev/null | grep -q "$PLUGIN_NAME"; then
  echo "plugin '$PLUGIN_NAME' already installed; refreshing cache"
  "$CODEX" plugin remove "$PLUGIN_NAME" >/dev/null 2>&1 || true
fi
"$CODEX" plugin add "${PLUGIN_NAME}@${MARKETPLACE_NAME}"

echo ""
echo "installed. next steps:"
echo "  1. \"$CODEX\" plugin list                 # confirm mac-calendar is enabled"
echo "  2. $BIN status                          # confirm Calendar/Reminders access"
echo "  3. restart Codex so the MCP server is picked up"
echo ""
echo "If access is missing, grant Full Access to the app running Codex in"
echo "System Settings › Privacy & Security › Calendars and › Reminders."
