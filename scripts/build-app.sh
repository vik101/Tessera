#!/usr/bin/env bash
# Builds Tessera.app.
#
#   ./scripts/build-app.sh            debug build for this Mac   → build/debug/Tessera.app
#   ./scripts/build-app.sh release    universal (Apple silicon + Intel) → build/release/Tessera.app
#
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a

CONFIG="${1:-debug}"
if [[ "$CONFIG" == "release" ]]; then
  ARGS=(-c release --arch arm64 --arch x86_64)
else
  ARGS=(-c debug)
fi

echo "› Compiling ($CONFIG)…"
swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

APP="build/${CONFIG}/${APP_NAME}.app"
echo "› Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Tessera" "$APP/Contents/MacOS/$APP_NAME"

# Sparkle.framework (SwiftPM puts it next to the binary; fall back to the downloaded artifact).
SPARKLE="$BIN_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE" ]]; then
  SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
fi
if [[ -z "$SPARKLE" || ! -d "$SPARKLE" ]]; then
  echo "error: Sparkle.framework not found. Run 'swift package resolve' and try again." >&2
  exit 1
fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

python3 scripts/make_plist.py > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
python3 scripts/strings.py compile Resources/Localizable.xcstrings "$APP/Contents/Resources"

# Signing: a real identity keeps macOS's Accessibility permission across rebuilds.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="-"
  echo "! No signing identity found; signing ad-hoc. Re-allow Accessibility after each rebuild."
fi
echo "› Signing with: $IDENTITY"

sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
if [[ "$CONFIG" == "release" && "$IDENTITY" != "-" ]]; then
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
fi

FW="$APP/Contents/Frameworks/Sparkle.framework"
# Sign Sparkle's helpers inside-out, as Sparkle's docs describe.
for helper in \
  "$FW/Versions/B/XPCServices/Installer.xpc" \
  "$FW/Versions/B/XPCServices/Downloader.xpc" \
  "$FW/Versions/B/Autoupdate" \
  "$FW/Versions/B/Updater.app"; do
  if [[ -e "$helper" ]]; then
    if [[ "$helper" == *Downloader.xpc ]]; then
      sign --preserve-metadata=entitlements "$helper"
    else
      sign "$helper"
    fi
  fi
done
sign "$FW"
sign "$APP"

codesign --verify --deep --strict "$APP" && echo "✓ Built $APP"
