#!/usr/bin/env bash
# Build the Swift EventKit bridge.
#
# The output is an .app bundle, not a bare executable, and that is load-bearing:
# some hosts (Claude among them) spawn child processes through a "disclaimer"
# helper that calls responsibility_spawnattrs_setdisclaim(), so the child becomes
# its OWN TCC responsible process instead of inheriting the host's identity.
# tccd will only show a consent dialog for a process it can resolve to a real
# bundle — a bare Mach-O gets silently denied and the status stays notDetermined.
#
# The Info.plist is also embedded into __TEXT,__info_plist so the binary still
# works when invoked directly, and the bundle is ad-hoc signed with a stable
# identifier so TCC remembers the grant across rebuilds.
#
# build/ekbridge is a symlink to the executable inside the bundle; running it
# resolves to the real path, so it keeps the bundle identity either way.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/swift/ekbridge.swift"
PLIST="$ROOT/swift/Info.plist"
OUT_DIR="$ROOT/build"
APP="$OUT_DIR/ekbridge.app"
EXEC="$APP/Contents/MacOS/ekbridge"
BUNDLE_ID="com.howiez.planner4mcp.ekbridge"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TARGET="arm64-apple-macos14.0" ;;
  x86_64) TARGET="x86_64-apple-macos14.0" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "==> Compiling ekbridge ($TARGET)"
swiftc -O -parse-as-library \
  -target "$TARGET" \
  -framework EventKit -framework CoreLocation -framework CoreGraphics \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLIST" \
  -o "$EXEC" "$SRC"

echo "==> Assembling bundle"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
ln -sfn "ekbridge.app/Contents/MacOS/ekbridge" "$OUT_DIR/ekbridge"

echo "==> Ad-hoc signing bundle"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Registering with LaunchServices"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo "==> Built $APP"
echo "    symlink: $OUT_DIR/ekbridge"
