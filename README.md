# <img src="icons/tandem.png" width="32" alt=""> tandem

A video editor that me and my AI agents can both work on

macOS

<!-- media: hero -->
<!-- ![tandem](docs/hero.png) -->
<!-- media: hero -->

## What it is

This is the video editor I'm building for my Convex videos to replace Filmora. It's built so my agents can edit the same project as me, through a CLI and an MCP server, while I work in the app.

A project is just a `.tandem` JSON file in the video's folder. Tandem finds the media there, pairs up my Record It camera and screen takes, and does transcripts, waveforms and the cutout in the background.

![Tandem editing the decision-models video](docs/header.jpg)

## Get it

Paste this into your AI coding agent (Claude Code, Codex, Cursor...):

> Fork https://github.com/mikecann/tandem to my GitHub account and clone my fork
> (if I don't use GitHub, or want to keep my copy private, just clone it instead),
> then make it my own. It's one of Mike Cann's personal tools, so read the README
> first, change anything specific to his setup to suit mine, then help me get it
> running.

Heads up, I'm not taking issues or pull requests on this one, so only I can open
them. It's built around my setup and I don't want to be the one deciding what goes
in, or accidentally breaking your version when I change something. Fork it and have
your agent make it your own instead.

### Or set it up by hand

You'll need macOS 15 or newer and Xcode 26 or newer with Swift 6. Some analysis
features, such as SpeechAnalyzer transcription (the stand-in when Bark can't),
need macOS 26. SwiftPM fetches the Lottie and FluidAudio dependencies during the
first build. The first transcript downloads the Bark 3.0 Pro model (1.23 GB): in
the background in the app, while a `tandem` command waits for it and shows its
progress. Install ffmpeg if you want to
import formats macOS can't decode, such as WebM (`brew install ffmpeg`).

```bash
git clone https://github.com/mikecann/tandem.git
cd tandem
bash setup_mac.sh
bash install.sh
tandem app
```

`setup_mac.sh` builds and signs the release app at `~/Applications/Tandem.app`.
`install.sh` links this clone's launcher into `~/.local/bin`; you can pass a
custom bin directory. Add that directory to your PATH if it isn't there yet.
Keep the clone in place, and rerun `install.sh` if you move it.

`install.sh` also links [the Tandem skill](skills/tandem/SKILL.md) into
`~/.claude/skills` and `~/.agents/skills`, so Claude Code and Codex know how
to edit with Tandem whenever they're in a folder with a `.tandem` project:
the loop of editing, checking and handing back for review, and the rules.
Set `TANDEM_SKILL_DIRS` to other folders, or to nothing to skip it. Agents
that use MCP instead (`tandem mcp`) get the same guidance from the server.

Tandem doesn't read `.env` files or need API keys to edit local media.
Optional asset providers use macOS Keychain. `tandem assets providers` tells
you what's missing, and [the asset guide](docs/ASSETS.md) covers setup.

## Using it

`tandem app [project.tandem]` opens the editor. Every other command goes to
the agent CLI (`tandem help`). For a new video folder:

```bash
cd /path/to/video
tandem new Video.tandem
tandem app Video.tandem
tandem status
tandem timeline --summary
```

For agents, add the MCP server once:

```bash
claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp
```

Old Filmora projects import with `tandem import filmora "Video v3.wfp"`.
Agent EDLs import with `tandem import edl edit.json --recipe decision-models`.
That recipe has paths and settings for my Decision Models video, so change
it for your footage or add your own. The [agent guide](docs/AGENTS.md) is
the entry point for agents; its topic files in `docs/agents/` have the
recipes, import options and troubleshooting.

Stickers, graphics, sounds, music, looks, fonts and saved segments that
every video reuses live in `~/Movies/Tandem Library`, which Tandem makes
the first time it opens. Projects use those files where they are; `tandem
archive` (File > Archive project...) copies the ones a project uses into it
before it moves to another Mac.

## Working on Tandem

```bash
swift test
bash restart.sh
```

`restart.sh` builds a debug app and opens it. Set `TANDEM_APP_DIR` to build
somewhere other than `~/Applications/Tandem.app`.

Run `bash tests/install-tests.sh` to check the launcher installation without
touching your app. The default Swift tests use synthetic media and fixtures.
Real footage, live provider calls and paid generation use opt-in flags
documented in the guides. `TANDEM_SPEECH_TESTS=1` enables the speech-service
test, which may install a language model and needs macOS 26.

| Doc | What's in it |
| --- | --- |
| `docs/ARCHITECTURE.md` | The contract between the modules: model, ripple modes, transforms, folders |
| `docs/PLAN.md` | The V1 task list and what's done |
| `docs/AGENTS.md` | The entry point for agents: setup, how editing works, and an index of every command, recipe and topic |
| `docs/agents/` | The agent guide's topic files: edit command semantics, JSON output, recipes, operations and troubleshooting |
| `docs/MEDIA.md` | Scanning, take pairing and the background analysis jobs |
| `docs/RENDER.md` | The compositor, transitions, titles, audio mix and export |
| `docs/ASSETS.md` | The asset library: sources, licences, normalising and credits |

## Layout

| Folder | What's there |
| --- | --- |
| `Sources/TandemCore` | Model, time, commands, editing, undo, journal |
| `Sources/TandemMedia` | Folder scanning, probing, analysis jobs |
| `Sources/TandemRender` | Composition, compositor, audio mix, export |
| `Sources/TandemAPI` | Project session, service, local server, MCP |
| `Sources/TandemAssets` | Asset library: catalogue, sources, normalising, credits |
| `Sources/TandemImport` | Filmora and EDL importers |
| `Sources/TandemApp` | The app |
| `Sources/TandemCLI` | The `tandem` command |
| `tests/` | XCTest targets, one per library |

## More tools

You can find my other tools at [mikerosoft.app](https://mikerosoft.app).

MIT licensed. See [LICENSE](LICENSE). Bundled fonts and other third-party
assets retain their own licences, which ship alongside them.

Models Tandem downloads on first use keep their own licences too, and stay
beside them in `~/Library/Application Support/Tandem/Models/`:

- Transcripts use Underdog Bark 3.0 Pro, CC-BY 4.0, run with
  [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0). Its
  notice:

  > Underdog Bark 3.0 Pro (ConwayResearch/Underdog-Bark-3.0-Pro), part of the Bark 3.0 family
  >
  > This model derives from:
  >
  > nvidia/parakeet-tdt-0.6b-v3, (c) NVIDIA Corporation, CC-BY-4.0
  > https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
  >
  > moondream/parakeet-ultra, (c) Moondream, CC-BY-4.0
  > https://huggingface.co/moondream/parakeet-ultra
  >
  > License: https://creativecommons.org/licenses/by/4.0/
  >
  > Changes: post-trained and compressed by Conway Research. The FastConformer encoder architecture, TDT decoder,
  > tokenizer and feature-extractor configuration derive from the models above and remain under CC-BY-4.0.

- The cutout uses Robust Video Matting (Lin et al. 2021,
  https://github.com/PeterL1n/RobustVideoMatting), GPL-3.0.
