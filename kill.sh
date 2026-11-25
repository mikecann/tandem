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
  RUNNING="$(pgrep -fl "$(dirname "$APP_DIR")/.*/Contents/MacOS/tandem (export|clip|archive)( |$)" 2>/dev/null || true)"
  if [[ -n "$RUNNING" ]]; then
    echo "Not stopping Tandem: an export or review clip is running in it, and stopping it would cut it off:" >&2
    echo "$RUNNING" | cut -c1-200 >&2
    echo "Wait for it to finish, or set TANDEM_FORCE_KILL=1 to stop it anyway." >&2
    exit 3
  fi
fi

# A "Reopen to update" waiting to start the new build would bring Tandem
# straight back after this stopped it (AppUpdate.waitThenOpen).
stop_reopen() { pkill -f "tandem-reopen [0-9]+ $(dirname "$APP_DIR")/$(basename "$APP_DIR") " 2>/dev/null || true; }
stop_reopen
if pkill -f "$PATTERN" 2>/dev/null; then
  # Wait for it to go, so an `open` straight after starts the new one
  # rather than bringing the quitting one forward. The app itself refuses
  # the first signal while an export or review clip renders in it (one
  # from its own menu or MCP, which the check above can't see); forced, a
  # SIGUSR1 straight after quits it anyway.
  # Up to 10 seconds: closing saves each project and makes its icon.
  for i in $(seq 100); do
    pgrep -f "$PATTERN" >/dev/null || break
    # SIGUSR1 is the app's "quit anyway" (an older app without it just ends).
    if [[ $i -eq 2 && "${TANDEM_FORCE_KILL:-}" == "1" ]]; then pkill -USR1 -f "$PATTERN" 2>/dev/null || true; fi
    sleep 0.1
  done
  # Saying "stopped" when it hadn't left the next open bringing the old
  # app forward again.
  if pgrep -f "$PATTERN" >/dev/null; then
    echo "Tandem is still running 10 seconds after being asked to quit: an export, review clip or archive is running in it (it won't quit then), or it's asking Mike about edits that won't save. Wait for the export, or set TANDEM_FORCE_KILL=1 to stop it anyway." >&2
    exit 3
  fi
  echo "Tandem stopped."
else
  echo "No running Tandem instance found."
fi
# Again now it has gone: one quitting on its way to a reopen may have
# started its helper meanwhile.
stop_reopen
