#!/bin/bash
# make-dmg.sh - package a .app into a compressed DMG with an /Applications symlink.
#
# Usage:   dist/make-dmg.sh <path/to/App.app> <version> [volume-name]
# Output:  dist/out/<AppName>-<version>.dmg  and  dist/out/<AppName>-<version>.dmg.sha256
#
# Uses only tools that ship with macOS (hdiutil, ditto, shasum, codesign, xcrun).
# Optional, only when the environment variables are set:
#   DEVELOPER_ID     e.g. "Developer ID Application: Your Name (TEAMID)"
#                    -> signs the app (hardened runtime + timestamp) and the DMG
#   ENTITLEMENTS     path to an entitlements .plist used when signing the app (optional)
#   NOTARY_PROFILE   notarytool keychain profile name (created once with
#                    `xcrun notarytool store-credentials`); requires DEVELOPER_ID
#                    -> notarizes + staples the app, then notarizes + staples the DMG
#   APP_NAME         override the artifact base name (default: the .app name without .app, spaces replaced by hyphens)
# Without DEVELOPER_ID the app is left exactly as given (e.g. ad-hoc signed by the
# bundling script) and nothing is sent anywhere.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -ge 2 ] || die "usage: $0 <App.app> <version> [volume-name]"
APP_SRC="$1"; VERSION="$2"
[ -d "$APP_SRC" ] && [[ "$APP_SRC" == *.app ]] || die "not an .app bundle: $APP_SRC"
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "version must be like 1.2.3 or 1.0.0-beta.1"

APP_BASENAME="$(basename "$APP_SRC" .app)"
# File names use hyphens instead of spaces ("EQ Ape.app" -> "EQ-Ape-<version>.dmg"); the volume keeps the app name.
NAME="${APP_NAME:-${APP_BASENAME// /-}}"
VOLNAME="${3:-$APP_BASENAME}"
[ -z "${NOTARY_PROFILE:-}" ] || [ -n "${DEVELOPER_ID:-}" ] || die "NOTARY_PROFILE needs DEVELOPER_ID"

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"
DMG="$OUT/$NAME-$VERSION.dmg"
rm -f "$DMG" "$DMG.sha256"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE"

# ditto keeps symlinks, resource forks and permissions intact
ditto "$APP_SRC" "$STAGE/$APP_BASENAME.app"
APP="$STAGE/$APP_BASENAME.app"

notarize() {  # notarize <file>
  echo "==> notarizing $(basename "$1") (this can take a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> signing app with: $DEVELOPER_ID"
  ENT=(); [ -z "${ENTITLEMENTS:-}" ] || ENT=(--entitlements "$ENTITLEMENTS")
  # Sign nested code first (inside-out), then the bundle. No --deep on purpose.
  while IFS= read -r -d '' f; do
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$f"
  done < <(find "$APP/Contents" \( -name '*.framework' -o -name '*.xpc' -o -name '*.dylib' -o -name '*.appex' \) -print0 2>/dev/null)
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" ${ENT[@]+"${ENT[@]}"} "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent "$APP" "$WORK/app.zip"
    notarize "$WORK/app.zip"
    xcrun stapler staple "$APP"
  fi
fi

ln -s /Applications "$STAGE/Applications"

echo "==> creating $DMG"
# UDZO = zlib-compressed read-only image; HFS+ is the most compatible filesystem for a DMG.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"

if [ -n "${DEVELOPER_ID:-}" ]; then
  echo "==> signing DMG"
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
  fi
fi

# Checksum file uses the bare file name so `shasum -c` works next to the DMG.
( cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "==> done"
ls -l "$DMG" "$DMG.sha256"
cat "$DMG.sha256"
