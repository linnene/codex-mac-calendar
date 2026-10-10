#!/usr/bin/env bash
# Build the mac-calendar-bridge helper.
#
# The interesting part is SDK selection: CommandLineTools ships several SDKs and
# only the ones built with a Swift version the local compiler understands can be
# used. Compiling without an explicit -sdk fails on machines where the default
# SDK is newer than the toolchain, so probe for a working pairing first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/plugins/mac-calendar/bin"
BIN="$OUT_DIR/mac-calendar-bridge"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"
SDK_OVERRIDE="${MAC_CALENDAR_SDK:-}"

log() { printf '\033[2m%s\033[0m\n' "$*"; }

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found. Install the Xcode Command Line Tools:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT
printf 'import Foundation\nimport EventKit\nimport AppKit\nprint("ok")\n' > "$probe_dir/probe.swift"

try_sdk() {
  local sdk="${1:-}"
  if [[ -n "$sdk" ]]; then
    swiftc -sdk "$sdk" -target "$TARGET" "$probe_dir/probe.swift" -o "$probe_dir/probe" >/dev/null 2>&1
  else
    swiftc -target "$TARGET" "$probe_dir/probe.swift" -o "$probe_dir/probe" >/dev/null 2>&1
  fi
}

CHOSEN_SDK=""
if [[ -n "$SDK_OVERRIDE" ]]; then
  if try_sdk "$SDK_OVERRIDE"; then
    CHOSEN_SDK="$SDK_OVERRIDE"
  else
    echo "error: MAC_CALENDAR_SDK='$SDK_OVERRIDE' cannot compile a trivial program." >&2
    exit 1
  fi
else
  shopt -s nullglob
  candidates=()
  for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
    [[ "$sdk" == *".sdk" ]] || continue
    candidates+=("$sdk")
  done
  # Newest first: MacOSX27, MacOSX26.5, MacOSX26, MacOSX15.4 … string sort is
  # good enough because the names are version-prefixed.
  IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -rV)); unset IFS

  for sdk in "${candidates[@]}"; do
    if try_sdk "$sdk"; then CHOSEN_SDK="$sdk"; break; fi
  done
  if [[ -z "$CHOSEN_SDK" ]] && try_sdk ""; then
    CHOSEN_SDK=""
  fi
fi

if [[ -z "$CHOSEN_SDK" && -z "$SDK_OVERRIDE" ]]; then
  echo "error: no usable SDK found for swiftc $(swiftc --version 2>/dev/null | head -1)." >&2
  echo "       Try: MAC_CALENDAR_SDK=/path/to/MacOSX.sdk $0" >&2
  exit 1
fi

if [[ -n "$CHOSEN_SDK" ]]; then
  log "sdk:    $CHOSEN_SDK"
else
  log "sdk:    toolchain default"
fi

mkdir -p "$OUT_DIR"
log "target: $TARGET"
log "output: $BIN"

swiftc \
  -O \
  ${CHOSEN_SDK:+-sdk "$CHOSEN_SDK"} \
  -target "$TARGET" \
  -framework EventKit \
  -framework AppKit \
  -framework CoreLocation \
  -framework Foundation \
  -o "$BIN" \
  "$ROOT"/Sources/MacCalendarBridge/*.swift

# A stable code-signing identity keeps the TCC grant alive across rebuilds.
# Ad-hoc signing changes the cdhash on every rebuild, so re-granting may still be
# needed; set MAC_CALENDAR_SIGN_IDENTITY to use a real identity.
SIGN_IDENTITY="${MAC_CALENDAR_SIGN_IDENTITY:--}"
if codesign --force --sign "$SIGN_IDENTITY" --identifier "com.mac-calendar.bridge" "$BIN" >/dev/null 2>&1; then
  log "signed: $SIGN_IDENTITY (identifier com.mac-calendar.bridge)"
else
  log "signed: skipped (codesign failed; the binary still runs)"
fi

log "built:  $("$BIN" version | head -1)"
