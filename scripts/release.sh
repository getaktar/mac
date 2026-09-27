#!/bin/bash
# Builds, signs, notarizes, and packages Aktar as a distributable DMG.
#
# One-time setup before running this:
#   security find-identity -v -p codesigning   # confirm a "Developer ID Application" cert exists
#   xcrun notarytool store-credentials aktar-notarization \
#     --key <path-to-AuthKey.p8> --key-id <key-id> --issuer <issuer-id>
#   Sparkle's EdDSA private key in the login Keychain (created once with
#   Sparkle's generate_keys; its public half is SUPublicEDKey in project.yml)
#
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Aktar.xcodeproj"
SCHEME="Aktar"
TEAM_ID="${TEAM_ID:-Y86FU5TSPQ}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Mert Topuz (${TEAM_ID})}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-aktar-notarization}"
# Read the build settings themselves (`KEY: "value"` lines), not comments or
# Info.plist entries that merely mention them.
setting() { grep -E "^ *$1: " project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/'; }
VERSION="${VERSION:-$(setting MARKETING_VERSION)}"
BUILD="$(setting CURRENT_PROJECT_VERSION)"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "Could not read MARKETING_VERSION ($VERSION) / CURRENT_PROJECT_VERSION ($BUILD) from project.yml" >&2
  exit 1
fi
REPO_URL="https://github.com/getaktar/mac"
FEED_URL="$REPO_URL/releases/latest/download/appcast.xml"

DIST="dist"
ARCHIVE="$DIST/Aktar.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/Aktar.app"
ZIP="$DIST/Aktar.zip"
DMG="$DIST/Aktar-$VERSION.dmg"
DMG_ROOT="$DIST/dmg-root"
EXPORT_PLIST="$DIST/ExportOptions.plist"
APPCAST="$DIST/appcast.xml"

# Sparkle only offers an update whose build number (CFBundleVersion) is
# higher than the installed one, so a release that forgets to bump
# CURRENT_PROJECT_VERSION would silently never reach anyone.
echo "==> Checking build number against the published appcast"
PUBLISHED_BUILD="$(curl -fsSL "$FEED_URL" 2>/dev/null | sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' | head -1 || true)"
if [ -n "$PUBLISHED_BUILD" ] && [ "$BUILD" -le "$PUBLISHED_BUILD" ]; then
  echo "CURRENT_PROJECT_VERSION ($BUILD) must be higher than the published build ($PUBLISHED_BUILD). Bump it in project.yml." >&2
  exit 1
fi

echo "==> Cleaning $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Archiving Aktar $VERSION"
# C code in the dependencies (BoringSSL in swift-nio-ssl) embeds source
# paths for its assertions; map the home folder away so the shipped binary
# doesn't carry the release machine's user name.
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$HOME=/build"

cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_PLIST"

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP"

echo "==> Building DMG"
rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -sf /Applications "$DMG_ROOT/Applications"
rm -f "$DMG"
hdiutil create -volname "Aktar" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

echo "==> Signing, notarizing, and stapling DMG"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vvv --type execute "$APP"
spctl -a -vvv --type install "$DMG"

echo "==> Signing the update for Sparkle"
# sign_update ships with the Sparkle package; Xcode resolved it into
# DerivedData while archiving. Override with SPARKLE_BIN=/path/to/bin.
SPARKLE_BIN="${SPARKLE_BIN:-$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -print -quit 2>/dev/null)")}"
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
  echo "Could not find Sparkle's sign_update. Set SPARKLE_BIN to Sparkle's bin directory." >&2
  exit 1
fi
# Prints: sparkle:edSignature="..." length="..."
SIGNATURE="$("$SPARKLE_BIN/sign_update" "$DMG")"

echo "==> Writing $APPCAST"
# Release notes come from this version's CHANGELOG section.
NOTES="$(python3 scripts/changelog_notes.py "$VERSION")"

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Aktar</title>
    <link>https://getaktar.com</link>
    <item>
      <title>Aktar $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES
      ]]></description>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$DMG")" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

echo "==> Done: $DMG"
echo "    Upload $APPCAST with it; the running apps read it from the latest release."
