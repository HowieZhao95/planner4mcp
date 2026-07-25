#!/usr/bin/env bash
# Build the Swift EventKit bridge binary.
#
# The Info.plist is embedded into the __TEXT,__info_plist section — without it
# macOS kills the process the moment it touches EventKit (no usage description).
# The binary is then ad-hoc signed with a stable identifier so TCC can remember
# the grant across rebuilds.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/swift/ekbridge.swift"
PLIST="$ROOT/swift/Info.plist"
OUT_DIR="$ROOT/build"
OUT="$OUT_DIR/ekbridge"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TARGET="arm64-apple-macos14.0" ;;
  x86_64) TARGET="x86_64-apple-macos14.0" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

mkdir -p "$OUT_DIR"

echo "==> Compiling ekbridge ($TARGET)"
swiftc -O -parse-as-library \
  -target "$TARGET" \
  -framework EventKit -framework CoreLocation -framework CoreGraphics \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
  -o "$OUT" "$SRC"

echo "==> Ad-hoc signing"
codesign --force --sign - \
  --identifier com.howiez.planner4mcp.ekbridge \
  "$OUT"

echo "==> Verifying embedded Info.plist"
if ! otool -s __TEXT __info_plist "$OUT" >/dev/null 2>&1; then
  echo "WARNING: could not verify __info_plist section" >&2
fi

echo "==> Built $OUT"
