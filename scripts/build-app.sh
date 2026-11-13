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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tessera" "$APP/Contents/MacOS/$APP_NAME"
python3 scripts/make_plist.py > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing. A real certificate keeps macOS's Accessibility permission across updates.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  echo "! No signing certificate found; signing ad-hoc."
  codesign --force --timestamp=none --sign - "$APP"
elif [[ "$CONFIG" == "release" ]]; then
  echo "› Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "› Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
fi

codesign --verify --strict "$APP" && echo "✓ Built $APP"
