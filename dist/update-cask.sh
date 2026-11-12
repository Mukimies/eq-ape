#!/bin/bash
# update-cask.sh - print the Homebrew cask (dist/eq-ape.rb) with version and sha256 filled in.
#
# Usage:   dist/update-cask.sh <version> <sha256 | path/to/EQ-Ape-<version>.dmg | path/to/....dmg.sha256>
# Output:  the updated cask on stdout. Nothing is written or pushed. To update the tap:
#   dist/update-cask.sh 0.1.0-beta.1 dist/out/EQ-Ape-0.1.0-beta.1.dmg.sha256 > ../homebrew-tap/Casks/eq-ape.rb
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
[ $# -eq 2 ] || die "usage: $0 <version> <sha256|dmg|dmg.sha256>"
VERSION="${1#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "bad version: $VERSION"

if [ -f "$2" ]; then
  case "$2" in
    *.sha256) SHA="$(cut -d' ' -f1 "$2")" ;;
    *)        SHA="$(shasum -a 256 "$2" | cut -d' ' -f1)" ;;
  esac
else
  SHA="$2"
fi
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "not a SHA-256 hex digest: $SHA"

CASK="$(cd "$(dirname "$0")" && pwd)/eq-ape.rb"
sed -E \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  "$CASK"
