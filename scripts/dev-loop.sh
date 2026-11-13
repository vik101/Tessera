#!/usr/bin/env bash
# Builds on request, so a helper (like Claude) can trigger builds without typing into Terminal.
#
# Write one word into .devloop/request (plus anything after it, to make it unique):
#   build | test | app | run | quit | release | log | state | resolve
# Only those fixed commands can run. Output goes to .devloop/result.log,
# and .devloop/status says when it's done. Stop with Ctrl-C.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source scripts/config.env; set +a
mkdir -p .devloop
: > .devloop/request
SUPPORT_DIR="$HOME/Library/Application Support/$BUNDLE_ID"
echo "Tessera dev loop is ready in $(pwd). Press Ctrl-C to stop."

last=""
while true; do
  request="$(cat .devloop/request 2>/dev/null || true)"
  if [[ -n "$request" && "$request" != "$last" ]]; then
    last="$request"
    command="${request%% *}"
    echo "▶ $command"
    echo "running: $request" > .devloop/status
    log=.devloop/result.log
    case "$command" in
      resolve) swift package resolve > "$log" 2>&1 ;;
      build)   swift build > "$log" 2>&1 ;;
      test)    swift test > "$log" 2>&1 ;;
      app)     ./scripts/build-app.sh debug > "$log" 2>&1 ;;
      release) ./scripts/build-app.sh release > "$log" 2>&1 ;;
      run)
        { pkill -x "$APP_NAME"; sleep 1; ./scripts/build-app.sh debug && open "build/debug/$APP_NAME.app"; } > "$log" 2>&1 ;;
      quit)    pkill -x "$APP_NAME" > "$log" 2>&1 ;;
      log)
        log show --last 5m --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" 2>&1 | tail -400 > "$log" ;;
      state)
        mkdir -p "$SUPPORT_DIR"
        rm -f "$SUPPORT_DIR/dump.txt"
        touch "$SUPPORT_DIR/dump-request"
        sleep 4
        cat "$SUPPORT_DIR/dump.txt" > "$log" 2>&1 || echo "The app didn't answer. Is it running?" > "$log" ;;
      *) echo "unknown command: $command" > "$log"; false ;;
    esac
    code=$?
    echo "done: $request (exit $code)" > .devloop/status
    echo "✓ $command (exit $code)"
  fi
  sleep 1
done
