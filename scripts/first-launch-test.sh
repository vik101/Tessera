#!/usr/bin/env bash
# Launches an app bundle the way a new user would: no saved settings, straight from Finder.
# Also tries a copy signed with the hardened runtime, to compare. Results go to ci-results/.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a
APP="${1:-build/release/$APP_NAME.app}"
OUT=ci-results
mkdir -p "$OUT"
pkill -x "$APP_NAME"; sleep 1

{ echo "== csrutil"; csrutil status; echo "== spctl"; spctl --status; } > "$OUT/system.txt" 2>&1
{ codesign -dv --verbose=4 "$APP"; codesign -dv "$APP/Contents/Frameworks/Sparkle.framework"; } > "$OUT/codesign.txt" 2>&1

launch() {  # $1 = app, $2 = label
  pkill -x "$APP_NAME"; sleep 1
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1
  "$1/Contents/MacOS/$APP_NAME" > "$OUT/launch-$2.txt" 2>&1 &
  sleep 8
  screencapture -x "$OUT/launch-$2.png" || true
  if pgrep -x "$APP_NAME" >/dev/null; then echo "running" >> "$OUT/launch-$2.txt"; else echo "NOT RUNNING" >> "$OUT/launch-$2.txt"; fi
  pkill -x "$APP_NAME"; sleep 1
}

launch "$APP" fresh

# Same app, re-signed the old way (ad-hoc + hardened runtime).
rm -rf /tmp/hardened && mkdir -p /tmp/hardened && ditto "$APP" "/tmp/hardened/$APP_NAME.app"
H="/tmp/hardened/$APP_NAME.app"
for item in "$H/Contents/Frameworks/Sparkle.framework" "$H"; do codesign --force --deep --options runtime --sign - "$item" >/dev/null 2>&1; done
launch "$H" hardened

head -5 "$OUT/launch-fresh.txt" "$OUT/launch-hardened.txt"
grep -q "^running" "$OUT/launch-fresh.txt"
