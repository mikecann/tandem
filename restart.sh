#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"

TANDEM_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
# Stopped only once the new bundle is in place. Stopping before the build
# left minutes for an agent's `tandem` command to reopen the old app, which
# then kept running from the swapped-out bundle and the new build never
# showed (9 Nov 2026).
# kill.sh refuses (exit 3) while an export or review clip runs in the app;
# the new build is installed already and takes over at the next launch.
status=0
bash "$SCRIPT_DIR/kill.sh" >/dev/null || status=$?
if [[ $status -eq 3 ]]; then
  echo "The new build is installed and starts the next time Tandem opens." >&2
  exit 3
fi
if [[ $# -gt 0 ]]; then
  open -a "$APP_DIR" "$@"
else
  open "$APP_DIR"
fi
echo "Tandem launched."
