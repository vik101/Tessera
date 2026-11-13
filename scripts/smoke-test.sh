#!/usr/bin/env bash
# Runs the built app against real windows (TextEdit, Finder, Safari, Chrome) and checks
# every snap and auto-tile layout. Used by CI. Results go to ci-results/.
#
#   ./scripts/smoke-test.sh build/debug/Tessera.app
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a
APP="${1:-build/debug/$APP_NAME.app}"
OUT=ci-results
mkdir -p "$OUT"
# Log every command with a timestamp, and never let one command hang the run.
export PS4='+ $(date +%H:%M:%S) '
set -x
limit() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }

swiftc -O scripts/ci/keys.swift -o /tmp/keys || exit 1

# CI only: allow Accessibility for Tessera (the runner's TCC database is writable).
if [[ "${CI:-}" == "true" ]]; then
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAccessibility', '$BUNDLE_ID', 0, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $(date +%s));" \
      && echo "accessibility granted in $db" || echo "could not write $db"
  done
fi
defaults delete "$BUNDLE_ID" >/dev/null 2>&1
# Chrome on the runner is quarantined, so macOS would ask before opening it.
[[ "${CI:-}" == "true" ]] && sudo xattr -dr com.apple.quarantine "/Applications/Google Chrome.app"
limit 20 /tmp/keys resolution > "$OUT/resolution.txt" 2>&1
sleep 2
defaults write "$BUNDLE_ID" TesseraTestHooks -bool YES


mkdir -p /tmp/tessera-docs
for i in 1 2 3; do echo "Tessera test document $i" > "/tmp/tessera-docs/doc$i.txt"; done
echo "<html><body><h1>Tessera test page</h1></body></html>" > /tmp/tessera-docs/page.html

limit 30 open -a TextEdit /tmp/tessera-docs/doc1.txt /tmp/tessera-docs/doc2.txt
limit 30 open /tmp/tessera-docs
limit 30 open -a Safari /tmp/tessera-docs/page.html
limit 30 open -na "Google Chrome" --args --no-first-run --no-default-browser-check --use-mock-keychain \
  --password-store=basic --new-window file:///tmp/tessera-docs/page.html
sleep 8
limit 20 /tmp/keys windows > "$OUT/windows-before.json"

limit 30 open "$APP"
sleep 6
screencapture -x "$OUT/0-start.png"

limit 660 python3 scripts/ci/check.py "$OUT" 2>&1 | tee "$OUT/check.log"
status=${PIPESTATUS[0]}

limit 90 log show --last 10m --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" > "$OUT/tessera.log" 2>&1
pgrep -x "$APP_NAME" >/dev/null && echo "Tessera still running" >> "$OUT/check.log" || echo "TESSERA CRASHED OR QUIT" >> "$OUT/check.log"
ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i tessera > "$OUT/crashes.txt" && cp ~/Library/Logs/DiagnosticReports/*essera* "$OUT/" 2>/dev/null
pkill -x "$APP_NAME"
exit $status
