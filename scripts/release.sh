#!/usr/bin/env bash
# Makes a DMG for sharing, notarized if NOTARY_PROFILE is set in config.env.
#
#   ./scripts/release.sh
#
# Notarizing needs a "Developer ID Application" certificate and a profile saved once with
# `xcrun notarytool store-credentials`.
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
  codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "! NOTARY_PROFILE is empty: not notarized. Other Macs will ask before opening it."
fi
echo "✓ $DMG"
