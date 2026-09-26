#!/bin/bash
# Builds, signs, notarizes, and packages Aktar as a distributable DMG.
#
# One-time setup before running this:
#   security find-identity -v -p codesigning   # confirm a "Developer ID Application" cert exists
#   xcrun notarytool store-credentials aktar-notarization \
#     --key <path-to-AuthKey.p8> --key-id <key-id> --issuer <issuer-id>
#
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="Aktar.xcodeproj"
SCHEME="Aktar"
TEAM_ID="${TEAM_ID:-Y86FU5TSPQ}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Mert Topuz (${TEAM_ID})}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-aktar-notarization}"
VERSION="${VERSION:-$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')}"

DIST="dist"
ARCHIVE="$DIST/Aktar.xcarchive"
EXPORT="$DIST/export"
APP="$EXPORT/Aktar.app"
ZIP="$DIST/Aktar.zip"
DMG="$DIST/Aktar-$VERSION.dmg"
DMG_ROOT="$DIST/dmg-root"
EXPORT_PLIST="$DIST/ExportOptions.plist"

echo "==> Cleaning $DIST"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Archiving Aktar $VERSION"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID"

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

echo "==> Done: $DMG"
