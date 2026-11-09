#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"

# Also an app still running from a bundle build-app.sh swapped out
# (".Tandem.app.old.<pid>"), which the installed path no longer matches.
PATTERN="($APP_DIR|$(dirname "$APP_DIR")/\.$(basename "$APP_DIR")\.old\.[0-9]+)/Contents/MacOS/tandem-app"

if pkill -f "$PATTERN" 2>/dev/null; then
  # Wait for it to go, so an `open` straight after starts the new one
  # rather than bringing the quitting one forward.
  for _ in $(seq 50); do pgrep -f "$PATTERN" >/dev/null || break; sleep 0.1; done
  echo "Tandem stopped."
else
  echo "No running Tandem instance found."
fi
