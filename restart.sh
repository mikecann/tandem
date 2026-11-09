#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${TANDEM_APP_DIR:-$HOME/Applications/Tandem.app}"

TANDEM_BUILD_CONFIGURATION=debug bash "$SCRIPT_DIR/build-app.sh"
# Stopped only once the new bundle is in place. Stopping before the build
# left minutes for an agent's `tandem` command to reopen the old app, which
# then kept running from the swapped-out bundle and the new build never
# showed (9 Nov 2026).
bash "$SCRIPT_DIR/kill.sh" >/dev/null || true
if [[ $# -gt 0 ]]; then
  open -a "$APP_DIR" "$@"
else
  open "$APP_DIR"
fi
echo "Tandem launched."
