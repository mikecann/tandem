#!/usr/bin/env bash
# Exercise installation in a disposable folder, without building or opening the app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
BIN="$SCRATCH/bin with spaces"

bash "$SCRIPT_DIR/install.sh" "$BIN"
[[ -L "$BIN/tandem" && "$(readlink "$BIN/tandem")" == "$SCRIPT_DIR/tandem" ]]
bash "$SCRIPT_DIR/install.sh" "$BIN"

# Moving from an older clone should replace its dangling symlink.
ln -sfn "$SCRATCH/old-clone/tandem" "$BIN/tandem"
bash "$SCRIPT_DIR/install.sh" "$BIN"
[[ "$(readlink "$BIN/tandem")" == "$SCRIPT_DIR/tandem" ]]

# Invoke the installed link with a fake app bundle to check path resolution
# and argument forwarding, without triggering setup or touching the real app.
APP="$SCRATCH/app with spaces/Tandem.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/MacOS/tandem" <<'CLI'
#!/usr/bin/env bash
printf '%s\n' "$@"
CLI
chmod +x "$APP/Contents/MacOS/tandem"
[[ "$(TANDEM_APP_DIR="$APP" "$BIN/tandem" 'two words' --json)" == $'two words\n--json' ]]

# A regular executable or directory with the same name belongs to the user.
rm "$BIN/tandem"
printf 'keep me\n' > "$BIN/tandem"
if bash "$SCRIPT_DIR/install.sh" "$BIN"; then
  echo "FAIL: installer overwrote a regular file" >&2
  exit 1
fi
[[ "$(cat "$BIN/tandem")" == "keep me" ]]
rm "$BIN/tandem"
mkdir "$BIN/tandem"
if bash "$SCRIPT_DIR/install.sh" "$BIN"; then
  echo "FAIL: installer replaced a directory" >&2
  exit 1
fi
[[ -d "$BIN/tandem" && ! -L "$BIN/tandem/tandem" ]]

bash "$SCRIPT_DIR/install.sh" --help
if bash "$SCRIPT_DIR/install.sh" --unknown; then
  echo "FAIL: installer accepted an unknown option" >&2
  exit 1
fi
if bash "$SCRIPT_DIR/install.sh" "$BIN" extra; then
  echo "FAIL: installer accepted extra arguments" >&2
  exit 1
fi
echo "Installer tests passed."
