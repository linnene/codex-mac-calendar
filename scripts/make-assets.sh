#!/usr/bin/env bash
# Regenerate the plugin artwork into plugins/mac-calendar/assets.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
OUT="$ROOT/plugins/mac-calendar/assets"

# Same SDK pairing problem as build.sh: probe for a usable SDK first.
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
printf 'import AppKit\nprint("ok")\n' > "$probe_dir/probe.swift"

SDK=""
shopt -s nullglob
for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
  if swiftc -sdk "$candidate" -target "$TARGET" "$probe_dir/probe.swift" -o "$probe_dir/probe" >/dev/null 2>&1; then
    SDK="$candidate"
    break
  fi
done
if [[ -z "$SDK" ]]; then
  echo "error: no usable SDK found for swiftc" >&2
  exit 1
fi

BIN="$probe_dir/make-icon"
swiftc -O -sdk "$SDK" -target "$TARGET" -framework AppKit -o "$BIN" "$ROOT/scripts/make-icon.swift"
"$BIN" "$OUT"
