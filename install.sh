#!/usr/bin/env bash
# Run setup_mac.sh to build the app, then install this repo's launcher on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$HOME/.local/bin}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: bash install.sh [target_bin_dir]"
  echo "Links tandem into target_bin_dir (default: ~/.local/bin)."
  echo "Build the app first with bash setup_mac.sh."
  exit 0
fi
if [[ $# -gt 1 || "$TARGET_DIR" == -* ]]; then
  echo "Usage: bash install.sh [target_bin_dir]" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
DEST="$TARGET_DIR/tandem"
# Repoint old launcher symlinks, but don't overwrite someone's own executable.
if [[ -e "$DEST" && ! -L "$DEST" ]]; then
  echo "Refusing to replace $DEST: it is not a symlink." >&2
  exit 1
fi
chmod +x "$SCRIPT_DIR/tandem"
ln -sfn "$SCRIPT_DIR/tandem" "$DEST"
echo "Installed $DEST -> $SCRIPT_DIR/tandem"
case ":${PATH}:" in
  *":$TARGET_DIR:"*) ;;
  *) printf 'Add this directory to PATH in ~/.zshrc: export PATH="%s:$PATH"\n' "$TARGET_DIR" ;;
esac
echo "Run tandem app to open the editor, or tandem help for CLI commands."
