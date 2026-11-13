#!/usr/bin/env bash
# Runs the built app against real TextEdit windows and records what happened.
# Used by CI; also handy on your own Mac. Results go to ci-results/.
#
#   ./scripts/smoke-test.sh build/debug/Tessera.app
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a
APP="${1:-build/debug/$APP_NAME.app}"
OUT=ci-results
SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
mkdir -p "$OUT" "$SUPPORT"

dump() {
  rm -f "$SUPPORT/dump.txt"
  touch "$SUPPORT/dump-request"
  sleep 4
  cp "$SUPPORT/dump.txt" "$OUT/$1" 2>/dev/null || echo "no state dump (app not answering)" > "$OUT/$1"
}

# On CI only: allow Accessibility for the app (needs a writable TCC database).
if [[ "${CI:-}" == "true" ]]; then
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity, flags, last_modified) VALUES ('kTCCServiceAccessibility', '$BUNDLE_ID', 0, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $(date +%s));" \
      && echo "accessibility granted in $db" || echo "could not write $db"
  done
  # Skip the welcome tour and What's New.
  defaults write "$BUNDLE_ID" onboardingComplete -bool true
  defaults write "$BUNDLE_ID" openAtLogin -bool false
  defaults write "$BUNDLE_ID" lastSeenVersion -string "$VERSION"
fi

mkdir -p /tmp/tessera-docs
for i in 1 2 3 4; do echo "Tessera test document $i" > "/tmp/tessera-docs/doc$i.txt"; done

open -a TextEdit /tmp/tessera-docs/doc1.txt /tmp/tessera-docs/doc2.txt /tmp/tessera-docs/doc3.txt
sleep 3
open "$APP"
sleep 10
screencapture -x "$OUT/1-three-windows.png" || true
dump state-1-three-windows.txt

# A fourth window on a screen set to 3 should join a stack.
open -a TextEdit /tmp/tessera-docs/doc4.txt
sleep 5
screencapture -x "$OUT/2-four-windows.png" || true
dump state-2-four-windows.txt

# Keyboard shortcuts, pressed by a tiny helper (needs Accessibility for the runner).
if [[ "${CI:-}" == "true" ]] && swiftc -O scripts/ci/keys.swift -o /tmp/keys 2>"$OUT/keys-build.log"; then
  press() { /tmp/keys "$1" "$2"; sleep 2; }
  dump() {
    rm -f "$SUPPORT/dump.txt"; touch "$SUPPORT/dump-request"; sleep 4
    { cat "$SUPPORT/dump.txt" 2>/dev/null || echo "no state dump"; echo "— Window server (front to back) —"; /tmp/keys windows; } > "$OUT/$1"
  }
  dump state-2b-ids.txt
  press ctrl,opt 0x32;        dump state-3-stack-next.txt            # ⌃⌥` next in stack
  press ctrl,opt,shift 0x13;  dump state-4-columns.txt               # ⌃⌥⇧2 Columns
  press ctrl,opt 0x24;        dump state-5-make-primary.txt          # ⌃⌥↩ primary
  press ctrl,opt 0x7C;        dump state-6-swap-right.txt            # ⌃⌥→ swap
  press ctrl,opt 0x06;        screencapture -x "$OUT/4-focus-mode.png"; dump state-7-focus.txt   # ⌃⌥Z
  press ctrl,opt 0x06
  press ctrl,opt 0x02;        screencapture -x "$OUT/5-no-peek.png"  # ⌃⌥D
  press ctrl,opt 0x02
  press ctrl,opt 0x2C;        screencapture -x "$OUT/6-cheat-sheet.png"  # ⌃⌥/
  press "" 0x35                                                      # Esc
  /tmp/keys tabview "$OUT/7-tab-view.png"; sleep 2                   # ⌥⇥
  press ctrl,opt,shift 0x12;  dump state-8-grid.txt                  # ⌃⌥⇧1 Grid
  press cmd 0x0D;             sleep 2; dump state-9-closed-one.txt   # ⌘W closes a window
  press ctrl,opt 0x11;        dump state-10-paused.txt               # ⌃⌥T pause
  press ctrl,opt 0x11;        dump state-11-resumed.txt              # ⌃⌥T resume
  screencapture -x "$OUT/8-final.png"
fi

# Opening the app again shows Settings.
open "$APP"
sleep 4
screencapture -x "$OUT/3-settings.png" || true

if pgrep -x "$APP_NAME" >/dev/null; then echo "running" > "$OUT/alive.txt"; else echo "NOT RUNNING" > "$OUT/alive.txt"; fi
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i "$APP_NAME" > "$OUT/crashes.txt" || true
for report in ~/Library/Logs/DiagnosticReports/*"$APP_NAME"*; do
  [[ -f "$report" ]] && head -120 "$report" >> "$OUT/crashes.txt"
done
log show --last 3m --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" > "$OUT/app-log.txt" 2>&1 || true
cat "$OUT/alive.txt"
grep -q running "$OUT/alive.txt"
