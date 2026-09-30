# Working on tandem

Tandem is a native macOS video editor with a CLI and MCP server. Work from
this repo root. It requires macOS 15 or newer and Xcode 26 or newer with Swift 6.

## Changes and checks

- Use test-first development for non-trivial behaviour changes. Write or
  update the relevant test first, then implement the change until it passes.
- When behaviour, UI copy, layout, persistence or startup contracts change,
  update affected tests and rerun them after the implementation.
- Before committing, run `swift test` and `bash tests/install-tests.sh`.
  Syntax-check launch and build scripts with `bash -n`.
- For an app change, run `bash restart.sh` after the tests and verify the
  actual interaction in the staged app. Set `TANDEM_APP_DIR` to stage an
  isolated app instead of replacing `~/Applications/Tandem.app`.
- Keep private footage, API keys, generated apps, caches and build outputs
  out of git. Tests requiring footage, permission grants, live APIs or paid
  generation are opt-in through their existing `TANDEM_*` environment guards.
- Preserve the bundle IDs and stable ad-hoc signing requirement in
  `build-app.sh`, so rebuilds retain macOS privacy permissions.
- `setup_mac.sh` builds the release app. `install.sh` links the `tandem`
  launcher into `~/.local/bin`, or an explicit directory. Rerun it after
  moving the clone. Existing source edits do not require reinstalling the link.
- Optional provider keys belong in macOS Keychain, as described in
  `docs/ASSETS.md`. The app does not load `.env` files.

## Architecture

- All clients use the same core edit commands, validation, undo and journal.
  Do not make CLI or MCP edits bypass the coordinator.
- Keep module boundaries in `Package.swift` and `docs/ARCHITECTURE.md`.
  Core model and time logic stay independent of UI and media frameworks.
- `docs/AGENTS.md` documents the CLI, MCP and HTTP API. Keep it current when
  command behaviour changes.
- The asset library records licences and credits. Preserve that metadata
  through imports, project use and archives.

## Writing and UI

- Write plainly and personally in first person where appropriate. No em dashes.
- Add comments when they explain reasoning or unusual behaviour.
- Avoid eyebrows and kickers in new UI designs.
- Start PR descriptions with `## Why`, explaining what prompted the change
  and why it is worth making.
