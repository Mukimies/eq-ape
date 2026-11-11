#!/bin/sh
# Build eqtap (release), re-sign ad hoc so the embedded __info_plist is bound into the signature,
# and wrap the same binary in a minimal eqtap.app (so it can be its own TCC "responsible process"
# when launched with `open`, instead of inheriting Terminal's identity).
set -e
cd "$(dirname "$0")"
swift build -c release
BIN=.build/release/eqtap
codesign --force --sign - --identifier org.eqape.eqtap "$BIN"
codesign -dvv "$BIN" 2>&1 | grep -E "^Identifier|Info.plist"

APP=build/eqtap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Sources/eqtap/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string eqtap" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.2" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/eqtap"
codesign --force --sign - "$APP"
echo "built $BIN and $APP"
