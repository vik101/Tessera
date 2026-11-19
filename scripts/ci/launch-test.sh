#!/usr/bin/env bash
# Opens the exact Tessera people download, the way a person would, in several starting
# states, and records whether it stays open, plus any crash report. Used by CI.
#
#   ./scripts/ci/launch-test.sh launch-results
set -uo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-launch-results}"
mkdir -p "$OUT"
BUNDLE=com.vikram.Tessera
APP=/Applications/Tessera.app
export PS4='+ $(date +%H:%M:%S) '
set -x
limit() { local secs=$1; shift; perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; }
result() { echo "$1" | tee -a "$OUT/results.txt"; }

{ sw_vers; uname -m; } > "$OUT/system.txt" 2>&1

# The exact file on the download link.
for try in 1 2 3 4 5; do
  limit 60 curl -fsSL -o /tmp/Tessera.zip "${TESSERA_ZIP_URL:-https://github.com/vik101/tessera/raw/tessera-ci/Tessera-release.zip}" && break
  sleep 20
done
rm -rf /tmp/dl && mkdir /tmp/dl && ditto -x -k /tmp/Tessera.zip /tmp/dl || { result "FAIL could not download Tessera"; exit 1; }
sudo rm -rf "$APP"
sudo ditto /tmp/dl/Tessera.app "$APP"
{ codesign -dv --verbose=2 "$APP"; codesign --verify --deep --strict "$APP" && echo "signature verified"; } > "$OUT/codesign.txt" 2>&1
plutil -p "$APP/Contents/Info.plist" > "$OUT/info-plist.txt" 2>&1
swiftc -O scripts/ci/keys.swift -o /tmp/keys

mkdir -p /tmp/tessera-docs
for i in 1 2 3; do echo "Document $i" > "/tmp/tessera-docs/doc$i.txt"; done
limit 30 open -a TextEdit /tmp/tessera-docs/doc1.txt /tmp/tessera-docs/doc2.txt /tmp/tessera-docs/doc3.txt
limit 30 open /tmp/tessera-docs
sleep 4

alive() {   # name, seconds to wait
  sleep "$2"
  if pgrep -x Tessera >/dev/null; then result "PASS $1: still running"; else result "FAIL $1: Tessera is not running"; fi
}

launch() {   # name
  pkill -x Tessera; sleep 1
  limit 30 open "$APP"
  alive "$1 (opened)" 10
  screencapture -x "$OUT/$1.png"
}

grant_accessibility() {
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAccessibility', '$BUNDLE', 0, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $(date +%s));" || true
  done
}

# Settings as Tessera 2.0 left them after a day of use.
settings_from_2_0() {
  defaults delete "$BUNDLE" >/dev/null 2>&1
  defaults write "$BUNDLE" settingsVersion -int 2
  defaults write "$BUNDLE" autoTile -bool YES
  defaults write "$BUNDLE" gap -int 0
  defaults write "$BUNDLE" askedAboutMacTiling -bool YES
  defaults write "$BUNDLE" layouts -dict "x-display" "columns"
  defaults write "$BUNDLE" shortcuts -data "$(printf '{"cleared":[],"custom":{}}' | xxd -p | tr -d '\n')"
}

# 1. A brand-new install: no settings, no Accessibility.
defaults delete "$BUNDLE" >/dev/null 2>&1
launch "1-fresh"

# 2. Updating from 2.0: old settings, Accessibility entry missing (as after an update).
settings_from_2_0
launch "2-update-no-permission"

# 3. Updating from 2.0 with Accessibility allowed: auto-tile starts straight away.
settings_from_2_0
grant_accessibility
defaults write "$BUNDLE" TesseraTestHooks -bool YES
launch "3-update-with-permission"
/tmp/keys post menu; sleep 2; screencapture -x "$OUT/3-menu-open.png"
/tmp/keys press "" 0x35; alive "3 after opening the menu" 1
/tmp/keys post settings; sleep 2; screencapture -x "$OUT/3-settings.png"
/tmp/keys post close-settings; alive "3 after opening Settings" 1
for key in 0x13 0x14 0x15 0x17 0x12; do /tmp/keys press ctrl,opt "$key"; sleep 1.5; done
alive "3 after ⌃⌥2 … ⌃⌥1" 1
for i in 1 2 3 4 5; do /tmp/keys press ctrl,opt 0x25; sleep 1.2; done
alive "3 after ⌃⌥L five times" 1
/tmp/keys press ctrl,opt,fn,num 0x7B; sleep 1; alive "3 after ⌃⌥←" 1
/tmp/keys press ctrl,opt 0x00; sleep 1; alive "3 after ⌃⌥A" 1
/tmp/keys post dump; sleep 1; cp /tmp/tessera-dump.json "$OUT/3-dump.json" 2>/dev/null

# 6. Two screens: a pretend second display, like an external monitor.
if clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/ci/vdisplay.m -o /tmp/vdisplay 2> "$OUT/vdisplay-build.txt"; then
  /tmp/vdisplay 1920 1080 > "$OUT/vdisplay.txt" 2>&1 &
  VDISPLAY=$!
  sleep 4
  /tmp/keys displays > "$OUT/6-displays.txt" 2>&1
  if [[ $(grep -c "^display" "$OUT/6-displays.txt") -ge 2 ]]; then
    result "PASS 6: a second screen is attached"
    # 6a. Fresh install, two screens.
    pkill -x Tessera; sleep 1
    defaults delete "$BUNDLE" >/dev/null 2>&1
    defaults write "$BUNDLE" TesseraTestHooks -bool YES
    launch "6a-two-screens-fresh"
    screencapture -x "$OUT/6a-screen1.png" "$OUT/6a-screen2.png"
    # 6b. Update from 2.0 with permission, auto-tile on, two screens.
    settings_from_2_0
    grant_accessibility
    defaults write "$BUNDLE" TesseraTestHooks -bool YES
    launch "6b-two-screens-update"
    screencapture -x "$OUT/6b-screen1.png" "$OUT/6b-screen2.png"
    /tmp/keys post menu; sleep 2; screencapture -x "$OUT/6b-menu1.png" "$OUT/6b-menu2.png"
    /tmp/keys press "" 0x35; alive "6b after opening the menu" 1
    /tmp/keys activate com.apple.TextEdit
    /tmp/keys press ctrl,opt,cmd,fn,num 0x7C; sleep 1.5; alive "6b after ⌃⌥⌘→ (next display)" 1
    for i in 1 2 3; do /tmp/keys press ctrl,opt 0x25; sleep 1.2; done
    alive "6b after ⌃⌥L three times" 1
    /tmp/keys post dump; sleep 1; cp /tmp/tessera-dump.json "$OUT/6b-dump.json" 2>/dev/null
    screencapture -x "$OUT/6b-end1.png" "$OUT/6b-end2.png"
  else
    result "SKIP 6: the pretend second screen did not appear"
  fi
  kill "$VDISPLAY" 2>/dev/null; sleep 2
  alive "6 after the second screen goes away" 2
else
  result "SKIP 6: could not build the pretend screen tool"
fi

# 4. Rectangle running too (it asks to quit it).
if limit 240 brew install --cask --quiet rectangle >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine /Applications/Rectangle.app 2>/dev/null
  limit 30 open -a Rectangle; sleep 4
  settings_from_2_0
  launch "4-with-rectangle"
  pkill -x Rectangle
else
  result "SKIP 4-with-rectangle: could not install Rectangle"
fi

# 5. Downloaded with a browser (quarantined): what does macOS show?
pkill -x Tessera; sleep 1
sudo xattr -w com.apple.quarantine "0083;$(printf %x "$(date +%s)");Safari;" "$APP"
spctl --assess --type execute -vv "$APP" > "$OUT/5-gatekeeper.txt" 2>&1
limit 30 open "$APP"
sleep 6
screencapture -x "$OUT/5-quarantined.png"
pgrep -x Tessera >/dev/null && result "INFO 5-quarantined: running" || result "INFO 5-quarantined: blocked by Gatekeeper (expected)"

# Crash reports and logs.
for dir in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
  ls "$dir" 2>/dev/null | grep -i tessera | while read -r f; do cp "$dir/$f" "$OUT/" 2>/dev/null; result "CRASH REPORT $f"; done
done
limit 90 log show --last 15m --info --style compact --predicate "subsystem == \"$BUNDLE\" OR process == \"Tessera\"" > "$OUT/tessera.log" 2>&1
pkill -x Tessera
grep -q "^FAIL" "$OUT/results.txt" && exit 1 || exit 0
