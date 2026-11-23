#!/usr/bin/env bash
# CI: publishes build/release/Tessera.app as the GitHub release v<VERSION>, once per version.
#   - notarized first, when it's signed with a Developer ID and the notary secrets exist
#   - with a signed appcast.xml for auto-update, when the Sparkle key exists
# Needs GH_TOKEN. Only for release commits (see below). Safe to run again: it fills in what's missing.
set -euo pipefail
cd "$(dirname "$0")/../.."
set -a; source scripts/config.env; set +a
OUT="${1:-ci-results}"
TAG="v$VERSION"
REPO_SLUG="${GITHUB_REPOSITORY:-$REPO}"
APP=build/release/Tessera.app
DIST=dist && rm -rf "$DIST" && mkdir -p "$DIST"
log() { echo "$*" | tee -a "$OUT/release-publish.txt"; }

# Only release commits publish: their subject starts with "Tessera <VERSION>" (e.g. "Tessera 2.5.0: …").
SUBJECT=$(git log -1 --format=%s)
if [[ "$SUBJECT" != "Tessera $VERSION"* && "${FORCE_RELEASE:-}" != yes ]]; then
  log "not a release commit ($SUBJECT)"
  exit 0
fi

if gh release view "$TAG" --repo "$REPO_SLUG" --json assets -q '.assets[].name' > "$DIST/assets.txt" 2>/dev/null \
   && grep -qx Tessera.zip "$DIST/assets.txt"; then
  log "$TAG is already published"
  exit 0
fi

if [[ -n "${NOTARY_KEY:-}" ]] && codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  log "notarizing…"
  printf '%s' "$NOTARY_KEY" | base64 --decode > "$RUNNER_TEMP/notary.p8"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --key "$RUNNER_TEMP/notary.p8" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" --wait 2>&1 | tee -a "$OUT/release-publish.txt"
  xcrun stapler staple "$APP" 2>&1 | tee -a "$OUT/release-publish.txt"
  rm -f "$RUNNER_TEMP/notary.p8" "$DIST/notarize.zip"
else
  log "not notarized (needs a Developer ID certificate and notary secrets)"
fi

ditto -c -k --keepParent "$APP" "$DIST/Tessera.zip"
FILES=("$DIST/Tessera.zip")

if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] && plutil -p "$APP/Contents/Info.plist" | grep -q SUPublicEDKey; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" > "$RUNNER_TEMP/ed-private"
  SIGN_UPDATE=$(find .build/artifacts -type f -name sign_update -perm -u+x | head -1)
  SIG=$("$SIGN_UPDATE" --ed-key-file "$RUNNER_TEMP/ed-private" "$DIST/Tessera.zip")
  rm -f "$RUNNER_TEMP/ed-private"
  python3 scripts/make_appcast.py --version "$VERSION" --build "$BUILD" --signature "$SIG" \
    --url "https://github.com/$REPO_SLUG/releases/download/$TAG/Tessera.zip" > "$DIST/appcast.xml"
  FILES+=("$DIST/appcast.xml")
  log "appcast signed for auto-update"
else
  log "no appcast (needs the SPARKLE_PRIVATE_KEY secret and SPARKLE_PUBLIC_KEY variable)"
fi

# Release notes: this version's changelog section.
python3 - "$VERSION" > "$DIST/notes.md" <<'PY'
import re, sys
text = open("CHANGELOG.md", encoding="utf-8").read()
m = re.search(rf"^## {re.escape(sys.argv[1])}\b.*?$(.*?)(?=^## |\Z)", text, re.S | re.M)
print((m.group(1).strip() if m else "") + "\n\nInstall: unzip, move Tessera to Applications, open it. Or with Homebrew:\n\n"
      "```\nbrew tap vik101/tessera https://github.com/vik101/Tessera\nbrew install --cask vik101/tessera/tessera\n```")
PY

if gh release view "$TAG" --repo "$REPO_SLUG" >/dev/null 2>&1; then
  gh release upload "$TAG" "${FILES[@]}" --clobber --repo "$REPO_SLUG"
  log "filled in the assets of $TAG"
else
  gh release create "$TAG" "${FILES[@]}" --repo "$REPO_SLUG" --title "Tessera $VERSION" \
    --notes-file "$DIST/notes.md" --target "${GITHUB_SHA:-main}" --latest
  log "published $TAG"
fi
