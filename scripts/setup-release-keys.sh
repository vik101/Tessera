#!/usr/bin/env bash
# One-time setup for signed releases and auto-update. Run it on your Mac, in this folder:
#
#   ./scripts/setup-release-keys.sh
#
# It makes two keys and stores them as GitHub secrets on the Tessera repo (needs `gh auth login`):
#   1. "Tessera Signing": a code-signing certificate of your own. Builds signed with it keep the
#      Accessibility permission across updates. It is also added to your login keychain, so your
#      own builds use it too.
#   2. A Sparkle update key (Ed25519). The app only installs updates signed with it.
# The private halves never leave your Mac except as encrypted GitHub secrets.
# Run it again only if you want new keys (people on older versions would then need one manual update).
#
# If you later get an Apple Developer ID, add these secrets too and releases will be notarized:
#   DEVELOPER_ID_P12 (base64 of the .p12), DEVELOPER_ID_PASSWORD,
#   NOTARY_KEY (base64 of the App Store Connect .p8 key), NOTARY_KEY_ID, NOTARY_ISSUER.
set -euo pipefail
cd "$(dirname "$0")/.."

make_certificate() {   # folder → tessera-signing.p12 and p12-password in it
  local dir="$1"
  mkdir -p "$dir"
  local password
  password=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)
  cat > "$dir/cert.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Tessera Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  # macOS's own openssl (LibreSSL) writes a .p12 that the Keychain can import.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" -config "$dir/cert.cnf"
  /usr/bin/openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" \
    -name "Tessera Signing" -out "$dir/tessera-signing.p12" -passout "pass:$password"
  printf '%s' "$password" > "$dir/p12-password"
  rm -f "$dir/key.pem" "$dir/cert.cnf"
}

if [[ "${1:-}" == "--make-certificate" ]]; then   # used by scripts/ci/signing-test.sh
  make_certificate "${2:?folder}"
  exit 0
fi

set -a; source scripts/config.env; set +a
command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in first: gh auth login"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "› Making the Tessera Signing certificate…"
make_certificate "$WORK"
PASSWORD=$(cat "$WORK/p12-password")
security import "$WORK/tessera-signing.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASSWORD" -T /usr/bin/codesign
base64 < "$WORK/tessera-signing.p12" | gh secret set SIGNING_P12 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set SIGNING_PASSWORD --repo "$REPO"

echo "› Making the Sparkle update key…"
swift package resolve >/dev/null
GENERATE_KEYS=$(find .build/artifacts -type f -name generate_keys -perm -u+x | head -1)
[[ -n "$GENERATE_KEYS" ]] || { echo "Sparkle's generate_keys wasn't found. Run 'swift build' once and try again."; exit 1; }
"$GENERATE_KEYS" --account tessera >/dev/null       # stores the private key in your keychain
"$GENERATE_KEYS" --account tessera -x "$WORK/ed-private" >/dev/null
PUBLIC=$("$GENERATE_KEYS" --account tessera -p)
gh secret set SPARKLE_PRIVATE_KEY --repo "$REPO" < "$WORK/ed-private"
gh variable set SPARKLE_PUBLIC_KEY --repo "$REPO" --body "$PUBLIC"

echo "✓ Done. The next version bump on main publishes a signed release with auto-update."
echo "  Public update key: $PUBLIC"
