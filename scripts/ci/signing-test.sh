#!/usr/bin/env bash
# Proves the update pipeline on a real Mac, with throwaway keys made on the spot:
#   1. An update signed with the same self-made certificate keeps the Accessibility permission.
#   2. An ad-hoc signed update loses it (shows the test can tell the difference).
#   3. Sparkle's tools sign the download, and the appcast's signature checks out.
#
#   ./scripts/ci/signing-test.sh build/debug/Tessera.app signing-results
set -uo pipefail
cd "$(dirname "$0")/../.."
SRC="${1:-build/debug/Tessera.app}"
OUT="${2:-signing-results}"
mkdir -p "$OUT"
BUNDLE=com.vikram.Tessera
APP=/Applications/Tessera.app
WORK=$(mktemp -d)
export PS4='+ $(date +%H:%M:%S) '
set -x
limit() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
result() { echo "$1" | tee -a "$OUT/results.txt"; }
: > "$OUT/results.txt"

swiftc -O scripts/ci/keys.swift -o /tmp/keys

# --- A throwaway "Tessera Signing" certificate, made the way setup-release-keys.sh makes the real one.
./scripts/setup-release-keys.sh --make-certificate "$WORK" > "$OUT/certificate.txt" 2>&1
KC="$WORK/tessera-test.keychain-db"
security create-keychain -p test "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p test "$KC"
security import "$WORK/tessera-signing.p12" -k "$KC" -P "$(cat "$WORK/p12-password")" -T /usr/bin/codesign >> "$OUT/certificate.txt" 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k test "$KC" >> "$OUT/certificate.txt" 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -p codesigning "$KC" >> "$OUT/certificate.txt" 2>&1
IDENTITY=$(security find-identity -p codesigning "$KC" | awk '/"Tessera Signing"/{print $2; exit}')
[[ -n "$IDENTITY" ]] && result "PASS certificate imported ($IDENTITY)" || result "FAIL no Tessera Signing identity in the keychain"

resign() {   # app, identity
  local fw="$1/Contents/Frameworks/Sparkle.framework"
  for helper in "$fw/Versions/B/XPCServices/Installer.xpc" "$fw/Versions/B/XPCServices/Downloader.xpc" \
                "$fw/Versions/B/Autoupdate" "$fw/Versions/B/Updater.app"; do
    [[ -e "$helper" ]] || continue
    codesign --force --timestamp=none --preserve-metadata=entitlements --sign "$2" "$helper"
  done
  codesign --force --timestamp=none --sign "$2" "$fw"
  codesign --force --timestamp=none --sign "$2" "$1"
}

version_copy() {   # build number, identity → $WORK/v<build>/Tessera.app
  local dir="$WORK/v$1"
  rm -rf "$dir" && mkdir -p "$dir" && ditto "$SRC" "$dir/Tessera.app"
  plutil -replace CFBundleVersion -string "$1" "$dir/Tessera.app/Contents/Info.plist"
  resign "$dir/Tessera.app" "$2" >> "$OUT/codesign.txt" 2>&1
  { echo "== build $1"; codesign -dv --verbose=2 "$dir/Tessera.app"; codesign -d -r- "$dir/Tessera.app"; } >> "$OUT/codesign.txt" 2>&1
  echo "$dir/Tessera.app"
}

install_app() {   # app
  pkill -x Tessera; sleep 1
  sudo rm -rf "$APP"
  sudo ditto "$1" "$APP"
}

trusted_after_launch() {   # → prints true / false / none
  defaults write "$BUNDLE" TesseraTestHooks -bool YES
  defaults write "$BUNDLE" autoTile -bool NO
  limit 30 open "$APP"
  sleep 6
  rm -f /tmp/tessera-dump.json
  /tmp/keys post dump; sleep 2
  python3 -c "import json;print(str(json.load(open('/tmp/tessera-dump.json'))['trusted']).lower())" 2>/dev/null || echo none
}

grant_with_requirement() {   # app: allow Accessibility only for code that meets this app's designated requirement
  local dr
  dr=$(codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p')
  echo "$dr" > "$OUT/designated-requirement.txt"
  echo "$dr" | csreq -r- -b "$WORK/dr.bin"
  local hex
  hex=$(xxd -p "$WORK/dr.bin" | tr -d '\n')
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAccessibility', '$BUNDLE', 0, 2, 4, 1, X'$hex', NULL, 0, 'UNUSED', NULL, 0, $(date +%s));" || true
  done
}

if [[ -n "$IDENTITY" ]]; then
  V1=$(version_copy 101 "$IDENTITY")
  V2=$(version_copy 102 "$IDENTITY")
  V3=$(version_copy 103 -)

  dr1=$(codesign -d -r- "$V1" 2>&1 | sed -n 's/^designated => //p')
  dr2=$(codesign -d -r- "$V2" 2>&1 | sed -n 's/^designated => //p')
  [[ -n "$dr1" && "$dr1" == "$dr2" ]] && result "PASS two builds signed with the certificate share one requirement" \
    || result "FAIL the two builds' designated requirements differ"
  codesign --verify --deep --strict "$V2" >> "$OUT/codesign.txt" 2>&1 \
    && result "PASS a certificate-signed build verifies" || result "FAIL a certificate-signed build does not verify"

  install_app "$V1"
  grant_with_requirement "$APP"
  got=$(trusted_after_launch); screencapture -x "$OUT/1-first-version.png"
  [[ "$got" == true ]] && result "PASS first version has Accessibility" || result "FAIL first version has no Accessibility ($got)"

  install_app "$V2"
  got=$(trusted_after_launch); screencapture -x "$OUT/2-update-same-certificate.png"
  [[ "$got" == true ]] && result "PASS an update signed with the same certificate keeps Accessibility" \
    || result "FAIL an update signed with the same certificate lost Accessibility ($got)"

  install_app "$V3"
  got=$(trusted_after_launch); screencapture -x "$OUT/3-update-ad-hoc.png"
  if [[ "$got" == false ]]; then result "PASS an ad-hoc update loses Accessibility (the test can tell the difference)"
  else result "WARN an ad-hoc update kept Accessibility ($got): this Mac doesn't check the requirement, so the test above proves less"; fi
  pkill -x Tessera
fi

# --- Sparkle: sign a download with a throwaway key and check the appcast.
SIGN_UPDATE=$(find .build/artifacts -type f -name sign_update -perm -u+x | head -1)
[[ -n "$SIGN_UPDATE" ]] && result "PASS Sparkle's sign_update tool found" || result "FAIL Sparkle's sign_update tool not found"
python3 -m pip install --quiet --break-system-packages cryptography >/dev/null 2>&1 || python3 -m pip install --quiet cryptography >/dev/null 2>&1
if [[ -f "${ED_KEY_DIR:-}/ed-private" ]]; then
  cp "$ED_KEY_DIR/ed-private" "$ED_KEY_DIR/ed-public" "$WORK/"   # the key the test app was built with
else
  python3 scripts/ci/make-ed-key.py "$WORK"
fi
ditto -c -k --keepParent "$SRC" "$WORK/Tessera.zip"
if [[ -n "$SIGN_UPDATE" ]]; then
  "$SIGN_UPDATE" --ed-key-file "$WORK/ed-private" "$WORK/Tessera.zip" > "$WORK/signature.txt" 2> "$OUT/sign_update.txt"
  cat "$WORK/signature.txt" >> "$OUT/sign_update.txt"
  python3 scripts/make_appcast.py --version 9.9.9 --build 999 --signature "$(cat "$WORK/signature.txt")" \
    --url "https://example.invalid/Tessera.zip" --notes CHANGELOG.md > "$OUT/appcast.xml" 2>> "$OUT/sign_update.txt"
  python3 - "$OUT/appcast.xml" "$WORK/Tessera.zip" "$WORK/ed-public" <<'EOF' && result "PASS the appcast's signature matches the download" || result "FAIL the appcast's signature does not match the download"
import base64, sys, xml.etree.ElementTree as ET
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
item = ET.parse(sys.argv[1]).find("channel/item")
enc = item.find("enclosure")
sig = enc.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
data = open(sys.argv[2], "rb").read()
assert int(enc.get("length")) == len(data), "length"
assert item.find("sparkle:version", ns).text == "999"
assert item.find("sparkle:shortVersionString", ns).text == "9.9.9"
Ed25519PublicKey.from_public_bytes(base64.b64decode(open(sys.argv[3]).read())).verify(base64.b64decode(sig), data)
print("signature ok")
EOF
fi

# --- The app reports updates as configured when built with a feed and key.
plutil -p "$SRC/Contents/Info.plist" > "$OUT/info-plist.txt"
if grep -q SUPublicEDKey "$OUT/info-plist.txt"; then
  install_app "$SRC"
  got=$(trusted_after_launch)
  python3 -c "import json;d=json.load(open('/tmp/tessera-dump.json'))['updates'];print(d);assert d['configured'] and d['running']" > "$OUT/updates.txt" 2>&1 \
    && result "PASS a build with a feed and key starts Sparkle" || result "FAIL Sparkle did not start ($(tail -1 "$OUT/updates.txt"))"
  pkill -x Tessera
else
  result "FAIL the test build has no SUPublicEDKey in Info.plist"
fi
[[ -d "$SRC/Contents/Frameworks/Sparkle.framework" ]] && result "PASS Sparkle.framework is inside the app" || result "FAIL Sparkle.framework missing from the app"

ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i tessera > "$OUT/crashes.txt" && cp ~/Library/Logs/DiagnosticReports/*essera* "$OUT/" 2>/dev/null
security delete-keychain "$KC" 2>/dev/null
fails=$(grep -c '^FAIL' "$OUT/results.txt"); passes=$(grep -c '^PASS' "$OUT/results.txt"); warns=$(grep -c '^WARN' "$OUT/results.txt")
sed -i '' "1i\\
$passes passed, $warns warnings, $fails failed
" "$OUT/results.txt"
[[ "$fails" -eq 0 ]]
