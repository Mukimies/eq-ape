#!/bin/sh
# Build EQ Ape (release, Apple Silicon only) and assemble $BUILD_DIR/EQ Ape.app (default build/), ad-hoc signed
# with the hardened runtime and the entitlements file that a later Developer ID signature will use.
# BUILD_DIR=build-dev ./bundle.sh builds a development copy without touching build/ (for example while the
# app in build/ is running). This script never launches the app.
set -e
cd "$(dirname "$0")"
BUILD_DIR="${BUILD_DIR:-build}"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/EQApe

APP="$BUILD_DIR/EQ Ape.app"
rm -rf "$APP"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/EQApe"

# Icon (generated; skipped if it fails for any reason)
ICONSET="$BUILD_DIR/AppIcon.iconset"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ]; then
  rm -rf "$ICONSET"
  if swift Resources/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"; then
    rm -rf "$ICONSET"
  else
    echo "warning: icon generation failed; bundling without an icon"
  fi
fi
[ -f "$BUILD_DIR/AppIcon.icns" ] && cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature, hardened runtime, entitlements (replace "-" with a Developer ID identity later).
codesign --force --sign - --options runtime --entitlements Resources/EQApe.entitlements \
  --identifier org.eqape.EQApe "$APP"

echo "--- verify"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true
codesign -dvv "$APP" 2>&1 | grep -E "^Identifier|^Format|flags|Info.plist"
lipo -archs "$APP/Contents/MacOS/EQApe"
echo "built $APP (not launched)"
