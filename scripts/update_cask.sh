#!/bin/bash
# Points the Homebrew cask (getaktar/homebrew-tap) at a published release.
# Run it after `gh release create`: the sha256 is taken from the DMG that
# GitHub actually serves, not the local build.
#
# Usage: scripts/update_cask.sh [version]   (defaults to MARKETING_VERSION)
set -euo pipefail
cd "$(dirname "$0")/.."

setting() { grep -E "^ *$1: " project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/'; }
VERSION="${1:-$(setting MARKETING_VERSION)}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version: $VERSION" >&2
  exit 1
fi
TAP_REPO="getaktar/homebrew-tap"
DMG_URL="https://github.com/getaktar/mac/releases/download/v$VERSION/Aktar-$VERSION.dmg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Hashing $DMG_URL"
curl -fsSL -o "$WORK/Aktar.dmg" "$DMG_URL"
SHA256="$(shasum -a 256 "$WORK/Aktar.dmg" | cut -d' ' -f1)"

echo "==> Updating $TAP_REPO to $VERSION"
gh repo clone "$TAP_REPO" "$WORK/tap" -- --quiet
CASK="$WORK/tap/Casks/aktar.rb"
sed -i '' -E \
  -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
  "$CASK"
if git -C "$WORK/tap" diff --quiet; then
  echo "Cask is already at $VERSION"
  exit 0
fi
git -C "$WORK/tap" commit -q -am "Update aktar to $VERSION"
git -C "$WORK/tap" push -q origin HEAD
echo "==> Done: brew install --cask getaktar/tap/aktar now installs $VERSION"
