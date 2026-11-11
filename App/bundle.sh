#!/bin/sh
# Build EQ Ape (release, Apple Silicon only) and assemble build/EQ Ape.app, ad-hoc signed with the
# hardened runtime and the entitlements file that a later Developer ID signature will use.
# This script never launches the app.
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/EQApe

APP="build/EQ Ape.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/EQApe"

# Icon (generated; skipped if it fails for any reason)
ICONSET=build/AppIcon.iconset
if [ ! -f build/AppIcon.icns ]; then
  rm -rf "$ICONSET"
  if swift Resources/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o build/AppIcon.icns; then
    rm -rf "$ICONSET"
  else
    echo "warning: icon generation failed; bundling without an icon"
  fi
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
