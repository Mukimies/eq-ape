#!/bin/sh
# Build EQ Ape (release, Apple Silicon only) and assemble $BUILD_DIR/EQ Ape.app (default build/), signed with the
# hardened runtime and the entitlements file.
# Signing identity (printed at the end together with the designated requirement):
#   SIGN_IDENTITY=<name|SHA-1|->   wins ("-" = ad hoc; dist/release.sh always sets it explicitly)
#   else EQAPE_LOCAL_SIGN=1, or (not in CI and the identity "EQ Ape Local Dev" is in the keychain): that local
#        self-signed identity, so the audio-capture grant can survive rebuilds (docs/APP-NOTES.md, "Stable local signing")
#   else ad hoc, as before.
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

# Optional version stamping (used by dist/release.sh). Without these variables the checked-in
# Info.plist values are kept.
#   EQAPE_VERSION        numeric CFBundleShortVersionString, e.g. 0.1.0
#   EQAPE_BUILD          integer CFBundleVersion
#   EQAPE_RELEASE_LABEL  full release label (custom key EQApeReleaseVersion), e.g. 0.1.0-beta.1
PB=/usr/libexec/PlistBuddy
PLIST="$APP/Contents/Info.plist"
[ -z "${EQAPE_VERSION:-}" ] || "$PB" -c "Set :CFBundleShortVersionString $EQAPE_VERSION" "$PLIST"
[ -z "${EQAPE_BUILD:-}" ] || "$PB" -c "Set :CFBundleVersion $EQAPE_BUILD" "$PLIST"
if [ -n "${EQAPE_RELEASE_LABEL:-}" ]; then
  "$PB" -c "Add :EQApeReleaseVersion string $EQAPE_RELEASE_LABEL" "$PLIST"
fi
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

# Signature: hardened runtime, entitlements, fixed identifier (the designated requirement names it).
LOCAL_IDENTITY="EQ Ape Local Dev"
if [ -n "${SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SIGN_IDENTITY"; WHY="SIGN_IDENTITY"
elif [ "${EQAPE_LOCAL_SIGN:-}" = "1" ]; then
  IDENTITY="$LOCAL_IDENTITY"; WHY="EQAPE_LOCAL_SIGN=1"
elif [ -z "${CI:-}" ] && [ -z "${GITHUB_ACTIONS:-}" ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$LOCAL_IDENTITY\""; then
  IDENTITY="$LOCAL_IDENTITY"; WHY="found in the keychain (local build)"
else
  IDENTITY="-"; WHY="default"
fi
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/EQApe.entitlements \
  --identifier org.eqape.EQApe "$APP"

echo "--- verify"
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - 2>/dev/null || true
codesign -dvv "$APP" 2>&1 | grep -E "^Identifier|^Format|flags|Info.plist"
lipo -archs "$APP/Contents/MacOS/EQApe"
if [ "$IDENTITY" = "-" ]; then echo "signed: ad hoc ($WHY)"; else echo "signed: $IDENTITY ($WHY)"; fi
echo "designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/.*designated => //p')"
echo "cdhash: $(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
echo "built $APP (not launched)"
