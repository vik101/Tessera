#!/usr/bin/env bash
# CI: puts the signing certificate from the repo's secrets into a temporary keychain and prints
# SIGN_IDENTITY=<sha1> for $GITHUB_ENV. A Developer ID certificate wins over Tessera Signing.
set -euo pipefail
KC="$RUNNER_TEMP/signing.keychain-db"
PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
security create-keychain -p "$PW" "$KC" >&2
security set-keychain-settings -lut 7200 "$KC" >&2
security unlock-keychain -p "$PW" "$KC" >&2
add() {   # base64 p12, password
  printf '%s' "$1" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security import "$RUNNER_TEMP/cert.p12" -k "$KC" -P "$2" -T /usr/bin/codesign >&2
  rm -f "$RUNNER_TEMP/cert.p12"
}
[[ -n "${DEVELOPER_ID_P12:-}" ]] && add "$DEVELOPER_ID_P12" "${DEVELOPER_ID_PASSWORD:-}"
[[ -n "${SIGNING_P12:-}" ]] && add "$SIGNING_P12" "${SIGNING_PASSWORD:-}"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -p codesigning "$KC" >&2
ID=$(security find-identity -v -p codesigning "$KC" | awk '/"Developer ID Application/{print $2; exit}')
[[ -n "$ID" ]] || ID=$(security find-identity -p codesigning "$KC" | awk '/"Tessera Signing"/{print $2; exit}')
[[ -n "$ID" ]] && echo "SIGN_IDENTITY=$ID"
