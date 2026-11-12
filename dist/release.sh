#!/bin/bash
# release.sh - local, reproducible release build of EQ Ape (Apple Silicon only).
#
# Usage:   dist/release.sh <version>        e.g. dist/release.sh 0.1.0-beta.1   (a leading "v" is accepted)
# Output:  dist/out/EQ-Ape-<version>.dmg, dist/out/EQ-Ape-<version>.dmg.sha256 and
#          dist/out/RELEASE-NOTES.md (docs/releases/v<version>.md with {{SHA256}} / {{VERSION}} filled in,
#          only if that notes file exists)
#
# Steps: tests (EQCore, App) -> App/bundle.sh with the version stamped into Info.plist -> ad-hoc signature
# (done by bundle.sh after stamping) -> dist/make-dmg.sh. Never launches the app.
#
# Info.plist stamping:
#   CFBundleShortVersionString = numeric part of the version (0.1.0)
#   CFBundleVersion            = build number: $EQAPE_BUILD, else the number of commits on HEAD
#   EQApeReleaseVersion        = full label including any pre-release suffix (0.1.0-beta.1)
#
# Environment (all optional):
#   SKIP_TESTS=1       skip `swift test`
#   CLEAN=1            delete EQCore/.build and App/.build first (slow, fully clean build)
#   EQAPE_BUILD=<n>    override the build number
#   DEVELOPER_ID, ENTITLEMENTS, NOTARY_PROFILE   passed through to make-dmg.sh (Developer ID signing, notarization)
#
# Reproducibility: SOURCE_DATE_EPOCH is set to the HEAD commit time; the build number derives from the commit
# count; no timestamps or absolute paths go into the binary. See docs/DISTRIBUTION.md for what still varies.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[ $# -eq 1 ] || die "usage: $0 <version>   (e.g. 0.1.0-beta.1)"
VERSION="${1#v}"
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[0-9A-Za-z.]+)?$ ]] || die "version must look like 0.1.0 or 0.1.0-beta.1"
NUMERIC="${BASH_REMATCH[1]}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "$(uname -m)" = "arm64" ] || die "an Apple Silicon Mac is required (EQ Ape is arm64 only)"

if git rev-parse --git-dir >/dev/null 2>&1; then
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
  BUILD="${EQAPE_BUILD:-$(git rev-list --count HEAD)}"
  COMMIT="$(git rev-parse --short=12 HEAD)"
  [ -z "$(git status --porcelain)" ] || echo "warning: working tree has uncommitted changes; this build is not reproducible from the commit" >&2
else
  export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
  BUILD="${EQAPE_BUILD:-1}"; COMMIT="unknown"
fi
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "build number must be an integer, got '$BUILD'"
echo "==> EQ Ape $VERSION (CFBundleShortVersionString $NUMERIC, build $BUILD, commit $COMMIT, SOURCE_DATE_EPOCH $SOURCE_DATE_EPOCH)"

if [ "${CLEAN:-}" = "1" ]; then
  echo "==> clean build directories"
  rm -rf EQCore/.build App/.build App/build
fi

if [ "${SKIP_TESTS:-}" != "1" ]; then
  # Tests that need a real config file skip themselves when EQAPE_REAL_CONFIG is unset (expected).
  echo "==> swift test (EQCore)"
  ( cd EQCore && swift test )
  echo "==> swift test (App)"
  ( cd App && swift test )
fi

echo "==> bundle (arm64, ad-hoc signed)"
# SIGN_IDENTITY=- forces the ad-hoc signature: a local development identity ("EQ Ape Local Dev") must never leak into
# a release. In signed mode dist/make-dmg.sh re-signs the app with $DEVELOPER_ID afterwards.
SIGN_IDENTITY=- EQAPE_VERSION="$NUMERIC" EQAPE_BUILD="$BUILD" EQAPE_RELEASE_LABEL="$VERSION" ./App/bundle.sh
APP="$ROOT/App/build/EQ Ape.app"
[ -d "$APP" ] || die "bundle.sh did not produce $APP"
[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = "$NUMERIC" ] || die "version stamp missing in Info.plist"

echo "==> DMG"
dist/make-dmg.sh "$APP" "$VERSION"

DMG="dist/out/EQ-Ape-$VERSION.dmg"
SHA="$(cut -d' ' -f1 "$DMG.sha256")"

NOTES="docs/releases/v$VERSION.md"
if [ -f "$NOTES" ]; then
  sed -e "s/{{SHA256}}/$SHA/g" -e "s/{{VERSION}}/$VERSION/g" "$NOTES" > dist/out/RELEASE-NOTES.md
  echo "==> wrote dist/out/RELEASE-NOTES.md from $NOTES"
else
  echo "note: $NOTES not found; no release notes file written" >&2
fi

echo "==> release build finished"
echo "    $DMG ($(stat -f %z "$DMG") bytes)"
echo "    sha256 $SHA"
