#!/usr/bin/env bash
# Makes a signed, notarized DMG and prints the Sparkle appcast entry.
#
#   ./scripts/release.sh
#
# Needs: a "Developer ID Application" certificate, NOTARY_PROFILE in config.env
# (create it once with `xcrun notarytool store-credentials`), and your Sparkle
# private key in the login keychain (from Sparkle's generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a

./scripts/build-app.sh release
APP="build/release/${APP_NAME}.app"
DMG="build/release/${APP_NAME}-${VERSION}.dmg"

echo "› Making $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
ditto "$APP" "$STAGING/${APP_NAME}.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "› Notarizing (this takes a few minutes)…"
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG" 2>/dev/null || true
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "! NOTARY_PROFILE is empty: skipping notarization. Other Macs will warn when opening it."
fi

SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -path '*Sparkle*' | head -1)"
if [[ -n "$SIGN_UPDATE" ]]; then
  echo "› Sparkle signature:"
  SIGNATURE="$("$SIGN_UPDATE" "$DMG")"
  cat <<ITEM

Add this <item> to your appcast.xml (hosted at SPARKLE_FEED_URL):

<item>
  <title>Version ${VERSION}</title>
  <sparkle:version>${BUILD}</sparkle:version>
  <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>${MIN_MACOS}</sparkle:minimumSystemVersion>
  <pubDate>$(date -R)</pubDate>
  <enclosure url="https://YOUR-HOST/${APP_NAME}-${VERSION}.dmg" ${SIGNATURE} type="application/octet-stream"/>
</item>
ITEM
fi
echo "✓ $DMG"
