#!/usr/bin/env bash
# Exercise installation in a disposable folder, without building or opening the app.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
BIN="$SCRATCH/bin with spaces"
# The skill goes under HOME; keep it out of the real one.
export HOME="$SCRATCH/home dir"

bash "$SCRIPT_DIR/install.sh" "$BIN"
[[ -L "$BIN/tandem" && "$(readlink "$BIN/tandem")" == "$SCRIPT_DIR/tandem" ]]
bash "$SCRIPT_DIR/install.sh" "$BIN"

# The agent skill is linked where Claude Code and Codex look.
for dir in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
  [[ -L "$dir/tandem" && "$(readlink "$dir/tandem")" == "$SCRIPT_DIR/skills/tandem" ]]
done
[[ -f "$HOME/.claude/skills/tandem/SKILL.md" ]]
# Someone's own skill called tandem is left alone, and that's not an error.
rm "$HOME/.agents/skills/tandem"
mkdir "$HOME/.agents/skills/tandem"
bash "$SCRIPT_DIR/install.sh" "$BIN" 2>/dev/null
[[ -d "$HOME/.agents/skills/tandem" && ! -L "$HOME/.agents/skills/tandem" ]]
# TANDEM_SKILL_DIRS chooses the folders, or skips the skill when empty.
TANDEM_SKILL_DIRS="$SCRATCH/elsewhere" bash "$SCRIPT_DIR/install.sh" "$BIN" >/dev/null
[[ -L "$SCRATCH/elsewhere/tandem" ]]
rm "$HOME/.claude/skills/tandem"
TANDEM_SKILL_DIRS="" bash "$SCRIPT_DIR/install.sh" "$BIN" >/dev/null
[[ ! -e "$HOME/.claude/skills/tandem" ]]

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

# `tandem url` adds this Mac's key to a tandem:// link and opens it in
# the background. A fake `open` shows what it would have opened.
FAKE_BIN="$SCRATCH/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/open" <<'OPEN'
#!/usr/bin/env bash
printf '%s\n' "$@"
OPEN
chmod +x "$FAKE_BIN/open"
if PATH="$FAKE_BIN:$PATH" "$BIN/tandem" url 'debug?out=/tmp/tree.txt' 2>/dev/null; then
  echo "FAIL: tandem url sent a link without a key" >&2
  exit 1
fi
mkdir -p "$HOME/Library/Application Support/Tandem"
printf 'c0ffee' > "$HOME/Library/Application Support/Tandem/url-key"
[[ "$(PATH="$FAKE_BIN:$PATH" "$BIN/tandem" url 'screenshot?out=/tmp/a b.png')" == $'-g\ntandem://screenshot?out=/tmp/a b.png&key=c0ffee' ]]
[[ "$(PATH="$FAKE_BIN:$PATH" "$BIN/tandem" url 'command')" == $'-g\ntandem://command?key=c0ffee' ]]
[[ "$(PATH="$FAKE_BIN:$PATH" "$BIN/tandem" url 'tandem-dev://seek?t=3')" == $'-g\ntandem-dev://seek?t=3&key=c0ffee' ]]

# While an install swaps the app in, the launcher waits for it instead of
# starting a build of its own. A copy of it with a fake setup shows which.
LAUNCHER="$SCRATCH/launcher"
mkdir -p "$LAUNCHER"
cp "$SCRIPT_DIR/tandem" "$LAUNCHER/tandem"
cat > "$LAUNCHER/setup_mac.sh" <<'SETUP'
#!/usr/bin/env bash
touch "$(dirname "$0")/setup-ran"
exit 1
SETUP
SWAPPING="$SCRATCH/swapping/Tandem.app"
( sleep 1; mkdir -p "$SWAPPING/Contents/MacOS"; cp "$APP/Contents/MacOS/tandem" "$SWAPPING/Contents/MacOS/tandem" ) &
[[ "$(TANDEM_APP_DIR="$SWAPPING" bash "$LAUNCHER/tandem" waited)" == "waited" ]]
wait
[[ ! -e "$LAUNCHER/setup-ran" ]]

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
