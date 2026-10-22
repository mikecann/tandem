# Setup in full

Installing the CLI, what a new project picks up, imports, who holds the project, background work (transcripts, mattes, proxies), and the MCP, HTTP and SDK setup. The short version is in [../AGENTS.md](../AGENTS.md#setup).

## The CLI

`build-app.sh` puts the command inside the app bundle:

```bash
bash setup_mac.sh
bash install.sh
tandem --version
```

While working on Tandem itself, `swift build --package-path .` builds it at
`.build/debug/tandem`. `tandem app` (open the editor) and `tandem url` come
from the launcher script `install.sh` links, not the Swift CLI, so `tandem
help` doesn't list them.

Commands find the project from `--project <file.tandem or folder>`, then
`$TANDEM_PROJECT`, then the single `.tandem` file in the current folder or
the nearest parent that has one. A folder with several versions
(`Video.tandem`, `Video v2.tandem`) needs `--project`.

Set `TANDEM_AUTHOR=claude` (or pass `--author claude`) so your edits are
credited to you. Without it they show up as `cli`.

Output is plain text for reading. Add `--json` to any command for the JSON
result ([json-output.md](json-output.md) has the shapes). Errors go to
standard error with exit code 1 (2 for usage mistakes); with `--json` the
error is printed on standard output as `{"error": {...}}` and the exit code
is still 1. If you pipe `--json` into another program, check the pipeline's
status (`set -o pipefail`) or the output's `error` key, since a pipe reports
the last program's exit code.

## What a new project finds

`tandem new` adds every media file in the folder (as `tandem media
--refresh` does later). Media is `.mov`, `.mp4` and `.m4v` video, `.m4a`,
`.mp3`, `.wav`, `.aif`, `.aiff` and `.caf` sound, and `.png`, `.jpg`,
`.jpeg`, `.heic`, `.gif` and `.webp` pictures; anything else is left out.
The scan skips hidden files and folders, `.tandem`, `exports`,
`node_modules`, `.build`, `.git` and Filmora's `*.wfp.dir` folders, and a
file it can't read is skipped with the reason.

Each file gets a role from its name and folder: record-it's `-camera` and
`-screen` files (and its audio-only `-audio` take, a camera take with no
picture, so it lands on Voice and gets a transcript), then folders like
`music/`, `sfx/`, `broll/`, `graphics/` and `stickers/`. A video nothing
names, like a phone's `IMG_0151.MOV`, becomes the camera take when it's a
recording with a voice and a face: shot by a phone or camera (its metadata
names it) or sitting in `source/`, with speech in its sound and a face in
its frames. A render of an edit has both too, so one anywhere else in the
folder stays `other`. A sound file nothing names, which would be music,
becomes a voice take (a camera take with no picture, like Record It's
`-audio` take: Voice track, transcript straight away) when it's mono or in
`source/` and the same listen hears speech in it, so an interview's mic
WAV isn't music. A stereo file outside `source/` isn't listened to.

Cinema cameras name clips with a camera letter (RED's `A004_C002_0904XF`,
ARRI's `A001C002_210101_R1AB`, Blackmagic's `A001_08011234_C001`). When
camera takes in one folder come from different cameras, the longest is the
take and the other cameras' clips are its angles: `broll`, so a close-up
can't be mistaken for the main take. They aren't lined up with the take;
sync them by sound and place them on a track of their own. Clips from the
same camera stay camera takes.

New webcam takes get the camera picture delay (Tandem's setting, 80 ms on
Mike's Mac) unless Record It already took it out. A take a camera made, with
a timecode track (cinema cameras, and REDline's renders of their clips) or a
make and model in its metadata (phones), records in step and gets none.

Only files new to the project get a role this way. `tandem new` says which
file it took for the camera, why, and how to change it:

```
Added 16 media files from the folder.
13 are Live Photos: the still is the media item, with its motion clip kept on it (livePhotoVideo) rather than added on its own.
Camera take: source/IMG_0151.MOV (med_yccfihfs), an Apple iPhone XS Max video with speech and a face in it.
Not the camera? tandem apply '{"updateMedia": {"mediaID": "med_yccfihfs", "patch": {"role": "other"}}}'
```

A new project takes its frame rate from its camera take (the longest one
with a picture), so a RED take at 23.976 makes a 23.976 project, and says
so (`Frame rate: 23.976 fps, the camera take's.`). A rate over 30 is
divided down to the fastest whole fraction up to 30 (60 to 30, 59.94 to
29.97, 50 to 25), so Mike's 30 or 60 fps webcam keeps 30. With no camera
take, a variable one or one under 23.976, it stays 30. The size stays
3840x2160 unless `--size` or `--portrait` says otherwise: screen recordings
and graphics are made for it, and a 1080p camera scales up.

A Live Photo exported from Photos is a still and a movie of a few seconds
with the same name (`IMG_0130.HEIC`, `IMG_0130.mov`). The still is the
media item and keeps the movie's path in `livePhotoVideo`; the movie isn't
media of its own. `tandem media` shows it as `Live Photo, motion clip
IMG_0130.mov`. Folder refreshes, the app's folder watcher and files dropped
on the app all pair them the same way. A movie a project already had as
media stays as it is. Archiving, relink and segments take the movie along
with its still.

## Imports

```
tandem import filmora <file.wfp> [--out DIR] [--keep-levels]   a Filmora project as a .tandem
tandem import edl [edl.json] --recipe decision-models [--out DIR]
tandem import compare <a.tandem> <b.tandem>      how two cuts of one take differ
```

Imports write `<out>/<name>/<name>.tandem` with a report beside it
(`<name>.import.txt` for people, `.import.json` for agents) listing anything
that couldn't be carried over. Filmora media paths saved on another Mac are
fixed with `--rewrite /Users/old/=/Users/new/`, and moved files are found
with `--search <folder>`. A Filmora import normalises speech (the camera's
sound and the Voice tracks) to the project's speech level with no gain, the
way placing does, instead of copying Filmora's gains; music and sound
effects keep their Filmora volume. `--keep-levels` keeps Filmora's own
levels: its Auto Normalization becomes `normalizeTo: -24` (where Filmora
levels, on Tandem's meter) with the clip's gain on top.

## When the app is open

Only one process owns a project at a time. When the Tandem app has it open,
the app serves the API and every `tandem` command (and MCP tool call) goes
through the app, so your edits appear in front of Mike as you make them.
When the app is closed, each command opens the `.tandem` file itself, makes
the change, saves and lets go, usually in a few milliseconds. You don't
need to care which is happening; `tandem status` tells you.

`tandem serve` opens the project and serves the API headless until you stop
it with Ctrl-C (it saves on the way out). Use it for a long session with the
app closed, or to watch changes live. If Mike opens the project in the app
meanwhile, the app asks `tandem serve` to save and quit, and your next
command goes through the app instead.

## Background work: transcripts, mattes, proxies

Transcripts, cutout mattes, proxies, waveforms and loudness are made in the
background by whatever holds the project: the app, or `tandem serve`. A
command run with the app closed opens the file for a moment and makes
nothing, except `tandem wait` and `tandem transcribe`, which make the work
themselves for as long as they run. Don't start `tandem serve` just to get
a transcript, and don't poll `tandem media` or `tandem status` in a sleep
loop.

`tandem wait` blocks until the work is done, printing progress lines, and
then says what finished:

```
tandem wait                         every background job
tandem wait transcript              the transcripts the project makes
tandem wait transcript --media med_x   one file's
tandem wait matte                   mattes for clips with their cutout on
tandem wait proxy                   proxies for large video on the timeline
tandem wait export                  exports running through the app or tandem serve
```

```
transcript med_2atn285x running 40%
transcript med_2atn285x done
Done after 3.2 s:
  source/take1-camera.mov: ready, 1843 words
```

With the app closed, the wait opens the project the way `tandem serve`
does until it's done: other commands still work meanwhile (they go through
it), and if Mike opens the project in the app, the wait hands it over and
carries on waiting there. `--timeout` defaults to 600 seconds; when it
passes the wait says what's still going, and running it again keeps
waiting. A file nothing makes the thing for (a transcript of a music bed, a
matte for a clip with no cutout) is an error that says how to get it made,
not a wait that can only time out. Exit code 1 when anything failed or the
wait timed out.

Tandem transcribes camera takes and whatever is on a speech track (Voice)
by itself. `tandem transcribe <media id, clip id or path>` makes a
transcript of any other file with sound, with the same on-device engine
(Bark 3.0 Pro, or SpeechAnalyzer for a language other than English, or
in the app while Bark's model downloads): a generated clip you're checking for made-up speech, a
sound effect, a music cue. It marks the file (`transcribe: true` on the
media, one undo step) so the transcript is made wherever the project is
open, and with the app closed it waits for it and prints each file's word
count. An empty transcript (`ready, no speech`) is an answer too. With the
app open it queues it and returns; add `--wait` to wait. Then read it with
`tandem transcript <id>`, or do both at once with `tandem transcript <id>
--make`. Only reach for Whisper if Tandem can't do it (a language neither
engine supports, say). A transcript job whose status says "Made with
SpeechAnalyzer: ..." used the stand-in; Tandem makes it again with Bark
once the model is there.

The first transcript on a Mac needs Bark's model, a 1.23 GB download. The
app fetches it in the background and has SpeechAnalyzer stand in
meanwhile. A `tandem` command making transcripts itself (the app closed)
waits for it instead, since the download would stop when the command
exits: its progress lines say "Downloading Bark 3.0 Pro (1.23 GB, once
only), then transcribing". If the wait times out or you stop it, the next
command carries on the download from where it got to. With no network it
fails fast and SpeechAnalyzer makes the transcript.

## MCP

`tandem mcp` is an MCP server on stdin and stdout. Add it to Claude Code:

```bash
claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp
```

Started from a video's folder it uses that folder's project. To pin one
project, or to use it from anywhere:

```bash
claude mcp add --scope user tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp --project "/Users/m5-mike/dev/convex/convex-videos/decision-models/Decision Models.tandem"
```

Every tool also takes a `project` argument, so one server can work on any
project. Edits are credited to the client's name (`claude`, `codex`) unless
`--author` or `$TANDEM_AUTHOR` says otherwise.

For Codex, in `~/.codex/config.toml`:

```toml
[mcp_servers.tandem]
command = "/Users/m5-mike/Applications/Tandem.app/Contents/MacOS/tandem"
args = ["mcp"]
```

The tools mirror the operations: `status`, `timeline`, `media`,
`transcript`, `transcribe`, `search`, `pauses`, `tighten`, `join`,
`captions`, `short`, `cards`, `apply`, `undo`, `redo`, `history`, `diff`,
`restore`, `clips`, `validate`, `check`, `sync`, `comments`, `frame`, `frames`, `screenshot`, `clip`,
`export`, `archive`, `relink`, `loudness`, `watch`, `wait` and `effects`,
plus the asset library's `assets_search`, `assets_show`, `assets_use`,
`assets_credits`, `assets_generate` and `assets_providers`, and the saved
segments' `segments_list`, `segments_save` and `segments_insert`
([operations-and-troubleshooting.md](operations-and-troubleshooting.md) maps
each to its CLI command and HTTP endpoint). Tool results are readable text;
pass `json: true` for the raw JSON. `frame`, `frames` and `screenshot`
return the picture as an image. The `apply` tool's input schema describes
every edit command. The server speaks both MCP revisions in use: the
`initialize` handshake (2025-11-25 and earlier) and the stateless
2026-07-28 revision.

## HTTP

The app (or `tandem serve`) listens on 127.0.0.1 on a random port. The port
and a bearer token are in the project's lock file,
`<video folder>/.tandem/<name>.lock`:

```bash
LOCK="$HOME/dev/convex/convex-videos/decision-models/.tandem/Decision Models.lock"
PORT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['port'])" "$LOCK")
TOKEN=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['token'])" "$LOCK")
curl -s -H "Authorization: Bearer $TOKEN" -H "X-Tandem-Author: claude" \
  -d '{"commands": [{"blade": {"at": 12.5}}]}' "http://127.0.0.1:$PORT/v1/apply"
curl -s -N -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/v1/watch"
```

- `POST /v1/<operation>` with the same JSON the MCP tool takes. Operations
  without parameters also answer `GET`.
- `GET /v1/watch` streams server-sent events (`edit`, `undo`, `redo`,
  `reload`, `jobs`, `export`). Send `Last-Event-ID` to catch up after a
  reconnect.
- `GET /v1/schema` returns the edit batch JSON schema. `GET /v1/health`
  needs no token. `POST /v1/release` asks `tandem serve` to save and quit
  (the app refuses it).
- Errors are `{"error": {"code": "...", "message": "..."}}` with a matching
  status: 400 bad request, 401 token, 404 not found, 409 conflict (stale
  revision, overlap, locked, nothing to undo), 501 not built yet.

## Code mode (the SDK)

`sdk/` is a thin TypeScript client over the HTTP API, for bulk jobs: one
script reads the project, works out the edit and applies it as one labelled
batch, and only its result prints. It finds the project's lock file, and
starts `tandem serve` for the run when nothing is serving the project.

```bash
~/.bun/bin/bun sdk/run.ts "<name>.tandem" sdk/examples/swoosh-pushes.ts
~/.bun/bin/bun sdk/run.ts "<name>.tandem" -e 'const p = await t.project(); return p.captions().length'
```

`sdk/README.md` has the API. After edit commands change, regenerate its
types from a running server with `bun sdk/gen-types.ts <project.tandem>`.
