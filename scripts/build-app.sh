#!/usr/bin/env bash
# Builds Tessera.app.
#
#   ./scripts/build-app.sh            debug build for this Mac   → build/debug/Tessera.app
#   ./scripts/build-app.sh release    universal (Apple silicon + Intel) → build/release/Tessera.app
#
# Signing, best first:
#   1. "Developer ID Application" (or "Apple Development"): hardened runtime, ready to notarize.
#   2. "Tessera Signing", the self-made certificate from setup-release-keys.sh: macOS keeps the
#      Accessibility permission across updates, but still warns on the very first open.
#   3. Ad-hoc: works, but macOS asks for Accessibility again after every update.
# SIGN_IDENTITY (a name or SHA-1) picks one by hand.
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
# The command line tool, for scripts and agents. Homebrew links it; Settings can too.
mkdir -p "$APP/Contents/Resources/bin"
cp "$BIN_DIR/TesseraCLI" "$APP/Contents/Resources/bin/tessera"
python3 scripts/make_plist.py > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle.framework: SwiftPM leaves it beside the binary; else take the downloaded copy.
SPARKLE="$BIN_DIR/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
if [[ -z "$SPARKLE" || ! -d "$SPARKLE" ]]; then
  echo "error: Sparkle.framework not found. Run 'swift package resolve' and try again." >&2
  exit 1
fi
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks" \
  || install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/$APP_NAME"

# Pick the signing identity.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [[ -z "$IDENTITY" ]]; then
  # Self-made certificates aren't "trusted", so list without -v and match by name.
  IDENTITY="$(security find-identity -p codesigning 2>/dev/null | grep '"Tessera Signing"' | head -1 | awk '{print $2}' || true)"
fi
[[ -n "$IDENTITY" ]] || IDENTITY="-"

# Hardened runtime only with an Apple-issued certificate. With ad-hoc or self-made signing it turns
# on library validation, which needs an Apple team ID, and macOS then refuses to load Sparkle.
APPLE_ISSUED=no
if [[ "$IDENTITY" != "-" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -F "$IDENTITY" | grep -qE '"(Developer ID Application|Apple Development)'; then
  APPLE_ISSUED=yes
fi
echo "› Signing with: $IDENTITY (Apple-issued: $APPLE_ISSUED)"
if [[ "$APPLE_ISSUED" == yes && "$CONFIG" == "release" ]]; then
  sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
elif [[ "$APPLE_ISSUED" == yes ]]; then
  sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
else
  sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }
fi

# Sign Sparkle's helpers inside-out, as Sparkle's docs describe, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework"
for helper in "$FW/Versions/B/XPCServices/Installer.xpc" "$FW/Versions/B/XPCServices/Downloader.xpc" \
              "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
  [[ -e "$helper" ]] || continue
  if [[ "$helper" == *Downloader.xpc ]]; then sign --preserve-metadata=entitlements "$helper"; else sign "$helper"; fi
done
sign "$FW"
sign "$APP/Contents/Resources/bin/tessera"
sign "$APP"

codesign --verify --deep --strict "$APP" && echo "✓ Built $APP"
