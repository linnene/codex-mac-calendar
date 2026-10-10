#!/usr/bin/env bash
# Regenerate docs/tools.md from the tool schemas so the reference cannot drift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/plugins/mac-calendar/bin/mac-calendar-bridge"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN is missing. Run scripts/build.sh first." >&2
  exit 1
fi

mkdir -p "$ROOT/docs"
"$BIN" tools --markdown > "$ROOT/docs/tools.md"
echo "wrote docs/tools.md ($(grep -c '^## ' "$ROOT/docs/tools.md") tools)"
