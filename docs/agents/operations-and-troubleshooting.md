# Operations, archiving and troubleshooting

Every operation with its CLI command, HTTP endpoint and MCP tool, archiving a finished video, relinking missing media, and what common errors mean.

## Operations

| Operation | CLI | HTTP | MCP tool |
| --- | --- | --- | --- |
| status | `tandem status [--revision]` | `POST /v1/status` | `status` |
| media | `tandem media [--refresh]` | `POST /v1/media {"refresh": true}` | `media` |
| timeline | `tandem timeline [--summary] [--from] [--to] [--words] [--json]` | `POST /v1/timeline {"summary", "from", "to", "words", "format"}` | `timeline` |
| transcript | `tandem transcript [<id>] [--make]` | `POST /v1/transcript {"id"}` | `transcript` |
| transcribe | `tandem transcribe <id or path>... [--wait \| --no-wait]` | `POST /v1/transcribe {"media": [...], "wait", "timeout"}` | `transcribe` |
| wait | `tandem wait [transcript\|matte\|proxy\|jobs\|export] [--media <id>]... [--timeout]` | `POST /v1/wait {"what", "media": [...], "timeout"}` | `wait` |
| search | `tandem search "<phrase>"` | `POST /v1/search {"phrase"}` | `search` |
| pauses | `tandem pauses [--min]` | `POST /v1/pauses {"min"}` | `pauses` |
| tighten | `tandem tighten [--mike] [--sentence] [--comma] [--mid] [--mid-min] [--min] [--keep] [--protect] [--widen] [--apply]` | `POST /v1/tighten {"mike", "sentence", "comma", "mid", "midMin", "min", "keep", "protect", "widen", "apply"}` | `tighten` |
| join | `tandem join [--from] [--to] [--apply]` | `POST /v1/join {"from", "to", "apply"}` | `join` |
| captions | `tandem captions [--from] [--to] [--max-words] [--y] [--apply]` | `POST /v1/captions {"from", "to", "words", "y", "apply"}` | `captions` |
| short | `tandem short [--apply]` | `POST /v1/short {"apply"}` | `short` |
| cards | `tandem cards [--kicker] [--duration] [--insert] [--no-sounds] [--marker]... [--apply]` | `POST /v1/cards {"markers", "kicker", "duration", "insert", "sounds", "apply"}` | `cards` |
| apply | `tandem apply <file, - or '<json>'>` | `POST /v1/apply <batch>` | `apply` |
| undo, redo | `tandem undo [--count N]`, `tandem redo [--count N]` | `POST /v1/undo`, `/v1/redo` `{"count", "expectedRevision"}` | `undo`, `redo` |
| history | `tandem history` | `POST /v1/history` | `history` |
| diff | `tandem diff --since <revision, file or export>` | `POST /v1/diff {"since"}` | `diff` |
| restore | `tandem restore --from <ref> (--clips <ids> \| --from-time --to-time [--track]) [--apply]` | `POST /v1/restore {"from", "clips", "fromTime", "toTime", "track", "apply"}` | `restore` |
| sync | `tandem sync [<seconds>] [--media] [--default]`, `tandem sync --check [--from] [--to] [--media]`, or `tandem sync <file>... [--to] [--no-place] [--no-check] [--dry-run]` | `POST /v1/sync {"delay", "media", "makeDefault"}`, `{"check": true, "from", "until", "media"}` or `{"files", "to", "place", "check", "dryRun"}` | `sync` |
| clips | `tandem clips [--track] [--from] [--to] [--media] [--ids]` | `POST /v1/clips {"track", "from", "to", "media", "ids"}` | `clips` |
| validate | `tandem validate` | `POST /v1/validate` | `validate` |
| check | `tandem check [--changed] [--quick \| --cuts]` | `POST /v1/check {"from", "to", "changed", "quick", "cuts"}` | `check` |
| frame | `tandem frame <time> -o out.png` | `POST /v1/frame {"time", "output"}` | `frame` (image) |
| frames | `tandem frames <time>... [--every] [--from] [--to] -o sheet.png` | `POST /v1/frames {"times", "every", "from", "to", "width", "output"}` | `frames` (image) |
| screenshot | | `POST /v1/screenshot` | `screenshot` (app only) |
| clip | `tandem clip <start> <end> -o out.mp4 [--tracks] [--audio-only]` | `POST /v1/clip {"start", "end", "tracks", "audioOnly"}` | `clip` |
| export | `tandem export [--preset] -o out.mp4` | `POST /v1/export {"preset", "output"}` | `export` |
| archive | `tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]` | `POST /v1/archive {"to", "withCache", "dryRun"}` | `archive` |
| relink | `tandem relink [--search <folder>]... [--dry-run]` | `POST /v1/relink {"search": [...], "dryRun"}` | `relink` |
| loudness | `tandem loudness [--from] [--to] [--step] [--tracks] [--gains]` | `POST /v1/loudness {"mediaID", "from", "to", "step", "tracks", "gains"}` | `loudness` |
| watch | `tandem watch [--once]` | `GET /v1/watch` (events), `POST /v1/watch` (wait) | `watch` |
| effects | `tandem effects` | `POST /v1/effects` | `effects` |

Output paths given to the API are absolute or relative to the project
folder; the CLI makes them absolute from where you run it.

`tandem separate` is CLI only too: it runs on a rented GPU through
render-box for 10 to 20 minutes and writes the project's cache, not the
project, so it works while the app has the project open. Clips use its
stems through `audio.separation`, an ordinary edit.

Renaming a project (`tandem rename [<project>] <new name>`) is CLI only:
it moves the project file and everything beside it, so it refuses while
the app, `tandem serve` or another command has the project, and the API
and MCP only exist while something does.

The asset library isn't a project operation, so it has no HTTP endpoint;
the CLI and MCP open the library themselves, and only `use`, `credits` and
the segment `save` and `insert` reach the project (through the app's API
when it's open).

| Asset operation | CLI | MCP tool |
| --- | --- | --- |
| providers | `tandem assets providers` | `assets_providers` |
| search | `tandem assets search "<text>" [--kind] [--provider] [--online]` | `assets_search` |
| fetch | `tandem assets fetch <id>` | |
| show | `tandem assets show <id>` | `assets_show` |
| use | `tandem assets use <id> [--at] [--duration]` | `assets_use` |
| credits | `tandem assets credits [--optional]` | `assets_credits` |
| generate | `tandem assets generate sfx or music "<prompt>"` | `assets_generate` |
| install-starter | `tandem assets install-starter` | |
| list segments | `tandem segments list` | `segments_list` |
| save a segment | `tandem segments save "<name>" --clips <ids>` or `--from --to` | `segments_save` |
| insert a segment | `tandem segments insert "<name>" --at <time>` | `segments_insert` |

`tandem comments` and `tandem import` are CLI commands too (MCP
`comments`); `tandem help <command>` has every option.

## Archive a finished video

When a video's done it moves to Bruce, Mike's other Mac, which keeps the
archive. A project there has to open with nothing missing, but projects use
files from outside their folder: stickers, sounds, looks and segments from
the shared library, an import's absolute paths, a sound from another
video's folder, a LUT, a font installed only on this Mac. Look first:

```bash
tandem archive --dry-run
```

```
Dry run, nothing changed. Making Decision Models.tandem standalone would bring in 19 files from outside its folder (2.89 GB).
From outside the folder:
  media/music/score.wav  192.2 MB  from ~/dev/convex/convex-videos/decision-models/music/score.wav
  media/main vid/2026-09-24_105434-camera.mov  1.16 GB  from ~/dev/convex/...
  ...
Missing, so left as they are (1):
  /Users/m5-mike/Desktop/old-take.mov  (med_x, 2 clips)
```

Then either make the project's own folder standalone (the files are copied
in and the project points at them, as one undo step credited to you):

```bash
tandem archive
```

or write a standalone copy of the whole folder somewhere else, leaving the
original as it is:

```bash
tandem archive --to "/Volumes/CannMedia/Archive" --dry-run   # the folder by top-level folder, with sizes
tandem archive --to "/Volumes/CannMedia/Archive"
```

The copy is `/Volumes/CannMedia/Archive/<project folder name>/`, with every
path relative, so it opens anywhere. Proxies, mattes, thumbnails and
isolated voice are left out (Tandem makes them again; `--with-cache` keeps
them), as are `node_modules` folders; transcripts and the converted copies
of stickers macOS can't decode always go. Files outside
the folder land in `media/<the folder they were in>/`, shared library files
in `media/Tandem Library/<where they were in it>` (a segment's in
`media/Tandem Library/Segments/<name>/`), a Live Photo's movie beside its
still, LUTs in `assets/lut/` and fonts in `assets/font/` (the shared
library's `Fonts/` is looked in too). Other `.tandem` files in the folder
(versions) get the same treatment.

Every copy is an APFS clone when it can be (instant, no extra space) and is
checked against the original by SHA-256 when it isn't. A different file with
the same name is never replaced; the copy goes beside it as `name 2`.
`archive.json` in the archived folder says where each file came from, with
its checksum and date. Missing files are listed and left as they are.

A run that stops part way (Ctrl-C, a share that went away) changed nothing in
the project; run the same command again and it carries on, using what it
already copied. An archive to the same place later brings that archive up to
date. With the app closed the project stays locked while it copies, so a big
archive to a network share is best run when Mike isn't about to open it; with
the app open, the archive runs in the app.

## Relink missing media

A project opened on another Mac, or a folder tidied by hand, can lose track
of files. `tandem media` marks them `MISSING FILE` and `tandem validate`
fails. The app offers to search a folder when it opens such a project; from
the command line:

```bash
tandem relink --dry-run                        # what it would find in the project folder
tandem relink --search "/Volumes/CannMedia/decision-models"
```

It looks in the project folder and each `--search` folder (subfolders too)
for a file with the same name, and takes it only when its content matches
what the project knew (its fingerprint). A file with no fingerprint is taken
when it's the only one with that name. Then it looks in this Mac's shared
library for whatever's still missing, so a project that used stickers and
sounds from the library on another Mac finds them here; there, only a file
whose content matches is taken. A Live Photo's movie comes back with its
still when it's beside it. It's one undo step.


## Troubleshooting

- **"is open in the Tandem app, but the app isn't serving its API"**: the
  app has had the project open for 90 seconds without answering. Restart or
  update the app.
- **"busy in another tandem command"**: another command has the project
  open right now. Commands wait up to 15 seconds for it before giving up.
- **"isn't built yet, so this doesn't work in this version of Tandem"**:
  rendering or media analysis isn't in this build.
- **"has no 9:16 frame for the short"**: `--preset short` (or `--format
  portrait`) on a project that isn't 9:16 and has no portrait format yet.
  `tandem short --apply` lays one out; the landscape video exports with
  plain `tandem export`.
- **No pauses or search results**: check `tandem media`; transcripts are
  made in the background after files are added. `tandem wait transcript`
  waits for them (and makes them, with the app closed).
- **"has no transcript yet, and nothing is making one"** or **"Tandem only
  makes them for camera takes..."**: run the `tandem transcribe <id>` it
  gives.
- **"Nothing makes a transcript of ..."** from `tandem wait`: the file isn't
  a camera take or on a speech track. `tandem transcribe <id>` asks for one.
- **"... isn't installed, so N text clips are drawn in SF Pro instead"**:
  run the `tandem assets use fontsource:...` it gives. The font goes into
  the project's `assets/font/`, and the app (if it has the project open)
  uses it straight away. For a font Fontsource doesn't have, search with
  `tandem assets search "<name>" --kind font --online`, or pick another
  font for those titles.
- **"This project was saved by a newer Tandem (schema 2)"**: an older
  build opened a project a newer one saved. Update Tandem. Schema 2 is the
  one where a title's own style always wins over its preset.
- **"... is QuickTime Animation, which macOS can't decode"**: stock stickers
  often come as QuickTime Animation or PNG video. Tandem converts them to
  HEVC with ffmpeg (frames and exports wait for it; `tandem media` shows
  `converted`). If the warning says ffmpeg is missing, Mike installs it with
  `brew install ffmpeg`.
- **"Revision N is older than the edit history"**: the history starts
  when this version of Tandem first opened the project (or where it was
  last edited by something that kept none), and there's no backup saved
  at that revision. Diff against a backup file in `.tandem/backups` or an
  export (`--since "exports/<name>.mp4"`) instead.
- **"AVFoundation stopped handing over frames while reading ..."**: `tandem
  check` gave up on a stretch after a minute with no frame, rather than
  waiting forever. `tandem frames` still shows the stretch, and `tandem check
  --quick` checks what doesn't need frames. Worth reporting with the times it
  names, since it reads around the stall it knows about (held frames).
- **"Nothing to undo" after editing with the app closed**: headless undo
  history only lasts while nobody else edits the project. `tandem history`
  shows what can be undone.
- **"ElevenLabs refused: ... missing the permission sound_generation"**: the
  key can make music but not sound effects. Mike turns the permission on
  for the key in ElevenLabs; `tandem assets providers` says when it's fixed.
- **"No asset ... in the library"**: search for it first (with `--online`
  for provider assets), then use the ID the search gives.
- **"There's no folder at /Volumes/... to archive into"**: the share isn't
  mounted. Mike connects to it in Finder first.
- **"archive.json ... isn't a Tandem archive manifest"**: a file of that name
  that Tandem didn't write is in the way; it's never written over. Rename it.
- **"The copy of ... didn't match the original"**: a copy failed its
  checksum and was thrown away, and nothing in the project changed. Run it
  again; if it keeps failing, the destination disk is suspect.
- **"There's already a segment called ..."**: pick another name, or pass
  `--replace` (`replace: true`) to save over it; files only the old one had
  stay, and the rest of it goes to the Trash.
- **"Several segments are called ..."**: two segment folders give the same
  name; use the folder's name (`tandem segments list --json` has each
  `id`).
- **"... is missing ... from .../Segments/..., so it wasn't inserted"**: a
  file was deleted from the segment's folder. Put it back, or save the
  segment again from a project that has it.
- **"There's no shared library at ... yet"**: the app makes
  `~/Movies/Tandem Library` the first time it opens after installing, and
  `tandem segments save` makes it too.
