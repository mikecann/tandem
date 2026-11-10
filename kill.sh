#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"

# Also an app still running from a bundle build-app.sh swapped out
# (".Tandem.app.old.<pid>"), which the installed path no longer matches.
PATTERN="($APP_DIR|$(dirname "$APP_DIR")/\.$(basename "$APP_DIR")\.old\.[0-9]+)/Contents/MacOS/tandem-app"

# An agent's export or review clip runs in the app, and stopping the app
# kills it partway (10 Nov 2026: a rebuild's restart cut off the 1080p
# export of a video about to be uploaded). So refuse while one runs, unless
# TANDEM_FORCE_KILL=1. Exit 3 tells restart.sh not to carry on.
if [[ "${TANDEM_FORCE_KILL:-}" != "1" ]]; then
  RUNNING="$(pgrep -fl "$(dirname "$APP_DIR")/.*/Contents/MacOS/tandem (export|clip) " 2>/dev/null || true)"
  if [[ -n "$RUNNING" ]]; then
    echo "Not stopping Tandem: an export or review clip is running in it, and stopping it would cut it off:" >&2
    echo "$RUNNING" | cut -c1-200 >&2
    echo "Wait for it to finish, or set TANDEM_FORCE_KILL=1 to stop it anyway." >&2
    exit 3
  fi
fi

if pkill -f "$PATTERN" 2>/dev/null; then
  # Wait for it to go, so an `open` straight after starts the new one
  # rather than bringing the quitting one forward.
  for _ in $(seq 50); do pgrep -f "$PATTERN" >/dev/null || break; sleep 0.1; done
  echo "Tandem stopped."
else
  echo "No running Tandem instance found."
fi
