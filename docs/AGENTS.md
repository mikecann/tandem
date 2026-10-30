# Tandem for agents

Tandem is Mike's video editor. Anything he can do in the app, an agent can
do through the `tandem` command, the local HTTP API or MCP. All three speak
the same operations and the same edit commands, and every edit lands in the
app's undo menu and activity feed under the agent's name.

This page is the entry point: setup, how editing works, how to read a
project, and an index of every command, recipe and topic. It's meant to be
read whole. For the rest, read only what you need:

- `tandem help <command>` (like `tandem help tighten`) gives a command's
  options and what they do.
- `tandem help <edit command>` (like `tandem help addTransition`) gives an
  edit command's summary, every argument with its type and whether it's
  required (a model like `Transition` opened up one level), and a working
  example, all from the schema.
- `tandem schema` prints the whole edit batch JSON schema, and `tandem
  effects` the effects with their parameters, the transitions with their
  default lengths, the layouts and the animatable parameters.
- The topic files in [docs/agents/](agents/) have what help can't say:
  semantics, gotchas and recipes ([index below](#recipes-and-topics)).

`docs/ARCHITECTURE.md` is the contract behind all of it.

## Setup

```bash
bash setup_mac.sh
bash install.sh
tandem --version
```

While working on Tandem itself, `swift build --package-path .` builds it at
`.build/debug/tandem`.

- Commands find the project from `--project <file.tandem or folder>`, then
  `$TANDEM_PROJECT`, then the single `.tandem` file in the current folder or
  the nearest parent that has one. A folder with several versions
  (`Video.tandem`, `Video v2.tandem`) needs `--project`.
- Set `TANDEM_AUTHOR=claude` (or pass `--author claude`) so your edits are
  credited to you. Without it they show up as `cli`.
- Output is plain text for reading; `--json` on any command gives the JSON
  result ([JSON output](#json-output)). Errors exit 1 (2 for usage
  mistakes); with `--json` the error is `{"error": {...}}` on standard
  output. When you pipe `--json`, use `set -o pipefail` or check the
  `error` key.
- When the Tandem app has the project open, every command goes through the
  app, so your edits appear in front of Mike as you make them. When it's
  closed, each command opens the file, edits, saves and lets go. `tandem
  status` says which. `tandem serve` holds the project headless for a long
  session, and hands it over if Mike opens it in the app.
- Transcripts, mattes and proxies are made in the background by whatever
  holds the project. `tandem wait transcript` (or `matte`, `proxy`, or plain
  `tandem wait`) waits for them, and makes them itself with the app closed.
  `tandem transcribe <id>` makes a transcript of any other file with sound.
  Never start `tandem serve` just to get a transcript, and never poll
  `tandem media` or `tandem status` in a sleep loop.
- MCP: `claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp`.
  The tools mirror the CLI commands and take the same arguments, plus
  `project` and `json: true`; the `apply` tool's input schema describes
  every edit command.
- HTTP: the app (or `tandem serve`) listens on 127.0.0.1; the port and a
  bearer token are in `<video folder>/.tandem/<name>.lock`. `POST
  /v1/<operation>` takes the same JSON as the MCP tool.
- For bulk jobs, `sdk/` is a TypeScript client over the HTTP API
  (`sdk/README.md`).

[agents/setup.md](agents/setup.md) has all of this in full: what `tandem
new` picks up and how it finds the camera take, Live Photos, Filmora and
EDL imports, waiting on background work, MCP for Claude Code and Codex, the
HTTP endpoints and errors, and the SDK.

## How editing works

**One way to change a project.** Every change is an edit command in a
batch. A batch is applied to a copy of the project, validated, and committed
only if every command worked, so a failing command leaves nothing half done
and the error says which command failed and why. Each committed batch is one
undo step with a label and an author. [agents/edit-commands.md](agents/edit-commands.md#batches-and-patches)
has the batch format; patches (`updateClip`, `updateTrack`...) are JSON
merge patches, where `null` removes a field.

**Revisions.** Each commit bumps the project's revision. Read it from
`status` or `timeline`, and send it back as `expectedRevision` (`tandem
apply --expect N`): if Mike (or another agent) changed the timeline in the
meantime the batch is refused with a `staleRevision` error instead of
editing something you haven't seen. Re-read and try again. `tandem status
--revision` prints just the number. Take it when you read what you're
basing the edit on: read right before applying, it protects nothing. Tandem
finding new files in the project folder ("Found new media", by system)
bumps the revision too, but a batch whose revision is behind only by those
still goes ahead, unless it adds, changes or removes media itself (the scan
may have just added the same file). Any other change in between (an edit,
an undo) makes it stale.

**Dry runs.** `"dryRun": true` (or `tandem apply --dry-run`) checks a batch
on a copy and reports what it would do: warnings, clips added, removed and
changed, and the new length. IDs it reports are made up fresh by the real
run.

**Retries.** Give a batch an `idempotencyKey` (`--key`) and a retry with the
same key returns the first result instead of applying it twice. An
`interrupted` error means the app went away (quit or crashed) after it got
the call but before it answered, so an edit may have been applied: check
`tandem history` before sending it again.

**Restarts.** You can keep working while Tandem restarts (a new build going
in). When it quits, calls it's already running finish and answer first.
Commands sent while it's closing or opening the project again wait for it,
up to 90 seconds, and say so on stderr after a couple of seconds. While it's
closed they edit the file directly. `tandem watch`, with or without
`--once`, carries on through the restart. A new build is swapped in whole,
so `tandem` never runs a half-installed copy.

**Undo.** `undo` reverts the last batch, whoever made it, so pass
`expectedRevision` to undo only if nothing happened since your edit. That
check is strict, new media included, because the last batch would then be
Tandem's media scan rather than your edit. Each undo makes a new revision,
so to back out several edits use `tandem undo --count N` (MCP and HTTP
`count`) rather than undoing twice; it stops early if the history runs out,
and the result lists each step's `labels` and `authors`. With the app
closed, undo history for CLI and MCP edits is kept in
`.tandem/<name>.undo.json`, so `tandem undo` works across commands. It's
dropped as soon as the project is edited somewhere that doesn't keep it
(the app has its own undo).

**History.** Separately from undo, every change (an edit, an undo, a redo,
Tandem finding new media) is appended to `.tandem/<name>.history.jsonl` by
whoever has the project open: the app, `tandem serve` or a CLI command. It
lasts across restarts, says who made each change and where on the timeline
it was, and keeps enough to take the clips back to any revision since.
`tandem history` lists it, and `tandem diff` and `tandem restore` use it
(see [agents/review-and-history.md](agents/review-and-history.md#what-changed-and-putting-it-back)).
It starts when this version of Tandem first opens a project; edits made
before that, or by an older Tandem, aren't in it.

**IDs** are short strings with a prefix: `clip_`, `trk_`, `med_`, `tr_`,
`fx_`, `mk_`, `lnk_`. They never change. When a clip is split the left part
keeps its ID and the right part gets a new one. A batch returns the IDs it
created, in order, so you can refer to them next. To refer to something
inside the same batch, give it your own ID (`"id": "clip_title1"`).

**Times** are seconds on the timeline (`12.5`). The CLI and the API
parameters also take `mm:ss.mmm` (`01:23.500`). Inside edit commands use
numbers; strings like `"1:02.5"` are accepted but numbers are clearer.
`sourceStart` and `slip` deltas are in media time (seconds into the file).
Keyframe times are seconds from the clip's start.

**Several cuts in one batch.** Each command sees the timeline as the
commands before it left it, so a ripple delete moves everything after it
earlier. To cut words (stumbles, retakes, a rough cut), use `tandem cut`,
which puts both edges of every cut in a real pause
([cutting](agents/cutting.md#cut-a-phrase)). For exact ranges you've
checked, put them all in one `cutRanges` command: its ranges are all in the
times before it, in any order, and Tandem cuts them latest first.

**Overlaps.** Clips on one track can't overlap. An overlap under a
millisecond counts as touching, so rounding in a batch doesn't fail it: the
later clip's start moves to where the earlier one ends (its picture and
sound stay where they were on the timeline, it just loses that sliver), and
nothing overlapping is stored. That works for placing, inserting, moving,
trimming and sliding. A clip inside another, however short, is still an
overlap.

**Validation.** Commands are checked against the schema before they run,
so a misspelt field is an error (`unknown field "rippel" (did you mean
"ripple"?)`) rather than silently ignored. The error names what's missing
and what's allowed, and `tandem help <command>` shows the right shape.

### Tracks

A new project has Mike's usual tracks. Video tracks are listed bottom to
top in the JSON (`videoTracks[0]` is V1 and draws first); the timeline view
shows them top to bottom like the app.

| Track | Kind | Ripple mode | Holds |
| --- | --- | --- | --- |
| Text (V5) | video | follow | titles and captions |
| Graphics (V4) | video | follow | motion graphics, stickers |
| B-roll (V3) | video | follow | stock footage, screenshots |
| Camera (V2) | video | cut | the camera take, usually a PiP with the cutout |
| Screen (V1) | video | cut | the screen recording |
| Voice (A1) | audio | cut | the camera's sound, linked to the picture |
| Music (A2) | audio | follow | the music bed |
| SFX (A3) | audio | follow | sound effects |

Video clips are silent. Sound always lives on audio tracks, linked to its
picture.

Wherever a command takes a track (`trackID`, `trackIDs`, `videoTrackID`,
`audioTrackID`, `toTrackID`), you can give the track's ID or its name, like
`"Music"` or `["Camera", "Voice"]`. An ID is tried first, then a name
ignoring case. If two tracks share the name the edit fails, naming both IDs,
so use one of those.

### Ripple modes in plain words

- **cut** tracks hold the take (screen, camera, voice). A ripple edit that
  removes time from one of them removes the same time from all of them, so
  the picture and the sound stay in sync.
- **follow** tracks (B-roll, graphics, text, music, SFX) aren't cut. Their
  clips slide along with the take. A music bed or B-roll shot that spans the
  removed time keeps playing from where it started and simply ends that much
  sooner. A clip that sat entirely inside the removed time is removed, with a
  warning. When time is opened up instead (`insertTime`), a follow clip
  spanning that point stays put and plays on across it.
- **off** tracks stay where they are whatever happens elsewhere.
- A ripple edit made on a follow or off track only moves that track, so
  closing a gap in the B-roll never touches the take.
- Time opened right on a cut (`insertTime` or an insert there, or a ripple
  edit that makes a clip ending there longer) parts its two clips, so a
  transition between them goes, with a warning.
- Markers move with ripples of the take.
- Locked tracks never move. That can put a take out of sync, so you get a
  warning (and `tighten` refuses until the track is unlocked).

### Linked clips

Clips placed together from one take (camera picture, camera sound, screen)
share a link group. Moves, trims, cuts, slips and speed changes apply to the
whole group unless you pass `"includeLinked": false`. Joining a through-edit
joins the linked clips across the same cut too. The timeline view shows
the groups as `linked #1`, `linked #2`.

### Transitions

A transition joins two touching clips on one track, centred on the cut, or
sits at one clip's head or tail. It can carry a sound effect, an ordinary
clip on SFX that stays on the cut whatever happens to the transition and
goes when it goes. [agents/edit-commands.md](agents/edit-commands.md#transitions)
has how edges hold, overlays push off, audio crossfades and the sound
follows.

## Reading the project

- `tandem status`: revision, who has it open, background jobs, missing
  fonts and your edits still waiting for Mike's review. Run it first.
- `tandem timeline --summary`: one line per track with its clip count, span
  and gaps, plus the markers. Then `tandem timeline --from 1:00 --to 2:00`
  for a part in full (`--words` adds what each voice clip says).
- `tandem clips --track B-roll --from 1:20 --to 1:40` (or `--media <file>`,
  `--ids`) for clip IDs. Don't dump `timeline --json` to look them up.
- `tandem transcript [<clip or media id>]`, `tandem search "<phrase>"` and
  `tandem pauses --min 0.6` for what's said where. Word times are trimmed to
  the voice, and a word a cut runs through shows once, on the side where
  most of it plays.
- `tandem frame <time>`, `tandem frames --every 5 --from 1:00 --to 2:00`
  (one contact sheet) and `tandem clip <start> <end>` (a 720p review MP4)
  to look and listen; `tandem loudness --from T --to T` to measure the mix.
- `tandem check --changed` before handing back: black frames, flickers
  (with a `holdFrame` fix where it can), failed keys, gaps, slivers and
  double jumps (B-roll a few frames off a camera cut, with the fix), the
  same shot on two tracks at once (one person on screen twice),
  with notes on dead air, page changes and low frame rate screen
  recordings; `--cuts` finds clipped words at cuts, and `--listen` hears
  each join and prints what's heard there.
- `tandem handback` before your final message: the two to five places
  Mike should look at first, which the app walks him through before the
  rest of your highlighted changes.
- `tandem diff --since <revision>` for what Mike changed since your last
  round, and `tandem comments` for the notes he left on the timeline.

Source times (`sourceStart`, transcript file times) are the file's own
timestamps; `ffmpeg -ss` counts from the file's start, so add the stream's
`start_time` when you analyse a source with ffmpeg.
[agents/reading.md](agents/reading.md) has the timeline view line by line
and the rest in full.

### JSON output

A `--json` result is an object with the project's `revision` in it. Fields
can be missing (`video`, `audio`, `name`, `linkGroup` on a clip), so read
them with a default. `timeline --json` has `videoTracks` (bottom to top)
and `audioTracks`, not one `tracks`. [agents/json-output.md](agents/json-output.md)
has the shapes of every result you'll read.

## Commands

One line each; `tandem help <command>` has the options and what they do.

| Command | What it's for |
| --- | --- |
| `tandem new <path.tandem>` | a project with Mike's tracks and the folder's media (`--portrait` for a short) |
| `tandem rename [<project>] <new name>` | rename a project as the app's project list does (closed projects only) |
| `tandem status` | revision, owner, jobs, review state (`--revision` for just the number) |
| `tandem media` | files, clip counts, analysis state (`--refresh` scans the folder) |
| `tandem timeline` | the edit as text (`--summary`, `--from`/`--to`, `--words`, `--json`) |
| `tandem clips` | clip IDs by track, time and media |
| `tandem transcript` | word timings for a clip, a file or the timeline (`--make`) |
| `tandem transcribe <id or path>` | a transcript of any file with sound |
| `tandem wait [transcript\|matte\|proxy\|jobs\|export]` | wait for background work |
| `tandem search "<phrase>"` | where a phrase is said |
| `tandem pauses` | silences between words, and what the sound has in them |
| `tandem tighten` | shorten pauses (`--mike` for Mike's rules; dry run without `--apply`) |
| `tandem cut "<phrase>"` | cut words with both edges in real pauses (`--range`, `--at`, `--fillers` for every um and uh; dry run without `--apply`) |
| `tandem join` | join through-edits (dry run without `--apply`) |
| `tandem captions` | word-by-word captions (dry run without `--apply`) |
| `tandem short` | lay out a 9:16 short (`--copy` for its own project) |
| `tandem cards` | a section card at every section marker |
| `tandem apply <batch>` | apply edit commands (`--dry-run`, `--expect`, `--label`, `--key`) |
| `tandem undo`, `tandem redo` | undo or redo (`--count`, `--expect`) |
| `tandem history` | the undo stack and the edit history |
| `tandem diff --since <ref>` | what changed since a revision, backup or export |
| `tandem restore --from <ref>` | put clips back as they were (dry run without `--apply`) |
| `tandem validate` | check the project for problems |
| `tandem check` | what Mike would catch in review (`--changed`, `--quick`, `--cuts`, `--listen`) |
| `tandem sync [<seconds> \| <file>...]` | how late each camera's picture is, or set it; or line another angle or mic up with the camera by sound |
| `tandem comments` | Mike's timeline comments (`resolve <id>`) |
| `tandem handback` | hand a round back: the two to five places Mike should look at first (alone, what he hasn't watched) |
| `tandem frame <time>` | one frame as a PNG |
| `tandem frames <time>...` | a labelled contact sheet |
| `tandem screenshot` | the app window (app open only) |
| `tandem clip <start> <end>` | a review MP4, some tracks, or the sound alone |
| `tandem export` | the video, loudness matched (`--preset`) |
| `tandem loudness` | file levels, or the mix over time (`--gains`) |
| `tandem separate <file> "<prompt>"...` | SAM Audio stems on a rented GPU, for `audio.separation` (costs money) |
| `tandem effects` | effects, transitions, layouts, animatable parameters |
| `tandem schema` | the edit batch JSON schema |
| `tandem watch` | print changes as they happen (`--once` waits for one) |
| `tandem archive` | make the project standalone, or copy it with `--to` |
| `tandem relink` | find missing media |
| `tandem import filmora\|edl\|compare` | a Filmora project or EDL as a `.tandem`, or compare two cuts |
| `tandem assets ...` | the asset library: search, use, show, credits, generate |
| `tandem segments list\|save\|insert` | reusable bits of timeline in the shared library |
| `tandem serve` | hold the project and serve the API headless |
| `tandem mcp` | the MCP server on stdin and stdout |
| `tandem app`, `tandem url` | open the editor; drive it by link (from the launcher, for work on Tandem itself) |

Edit commands are listed one per line, by group, in
[agents/edit-commands.md](agents/edit-commands.md#every-command), and
[agents/operations-and-troubleshooting.md](agents/operations-and-troubleshooting.md#operations)
maps every command to its HTTP endpoint and MCP tool.

## Recipes and topics

| File | What's in it |
| --- | --- |
| [agents/setup.md](agents/setup.md) | installing, what `tandem new` finds, imports, app vs `serve`, background work, MCP, HTTP, SDK |
| [agents/reading.md](agents/reading.md) | the timeline view, transcripts and words at cuts, search, pauses, clips, frames and contact sheets, render warnings |
| [agents/json-output.md](agents/json-output.md) | `--json` shapes for timeline, media, transcript, wait, status, history, diff, clips, restore, apply |
| [agents/edit-commands.md](agents/edit-commands.md) | batches, an index of every edit command, and what help doesn't say: levels, stickers, keyframe values, gain keyframes, crop units, `insertTime`, transitions and sounds, templates, section cards, joins |
| [agents/cutting.md](agents/cutting.md) | Tighten pauses; Take out fillers; Cut a phrase; Rough cuts and false starts; Join through-edits; Keep the camera in sync; Add another angle or an external mic |
| [agents/broll-and-titles.md](agents/broll-and-titles.md) | Put B-roll over a sentence; Add a title (presets, animations, style); Add a section card |
| [agents/layout-and-colour.md](agents/layout-and-colour.md) | Set the PiP layout; Zoom into the screen recording; Grade the camera take |
| [agents/sound.md](agents/sound.md) | Level the voice; Tame the peaks on a quiet mic; Clean up a roomy mic; Check the sound; Put a swoosh on every push |
| [agents/shorts.md](agents/shorts.md) | Make a short; Caption a short |
| [agents/assets.md](agents/assets.md) | the asset library and shared library; Credits for the description; Reuse an intro, an outro or a call to action (segments) |
| [agents/review-and-history.md](agents/review-and-history.md) | `tandem check` and `--cuts` in full; What changed, and putting it back (diff, history, restore); Do Mike's comments; Hand back: what to look at first; Export a review clip; Work alongside Mike |
| [agents/operations-and-troubleshooting.md](agents/operations-and-troubleshooting.md) | every operation's CLI, HTTP and MCP form; Archive a finished video; Relink missing media; Troubleshooting errors |

Each recipe shows the CLI; the MCP tools take the same arguments.
