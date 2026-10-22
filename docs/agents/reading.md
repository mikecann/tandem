# Reading the project in full

The timeline view line by line, how transcripts, search and pauses treat words at cuts, finding clip IDs, rendering frames, contact sheets and review clips, and the warnings renders give. The short version is in [../AGENTS.md](../AGENTS.md#reading-the-project); `check` is in [review-and-history.md](review-and-history.md).

## Source times and ffmpeg

Times in a clip's source range (`sourceStart`, the `[in-out]` of the
timeline view, transcript word times) are the file's own timestamps, as
AVFoundation reads them. `ffmpeg -ss` counts from the file's start
instead, so when you analyse a source with ffmpeg, add the stream's
`start_time` (`ffprobe -show_entries stream=start_time`). Record It's
camera files start at 0.1 s and its screen files at 0.33 s: left out,
that's enough to clip a word.

## The timeline view

`tandem timeline` (MCP `timeline`) is the view to start from:

```
Decision Models: 01:00.000 long, 3840x2160 at 30 fps, revision 7
Tracks top to bottom as the app shows them. cut tracks hold the take and ripple edits cut them together; follow tracks move with them; off tracks stay put.
Clips: ID, start-end on the timeline, length, content [source in-out of the file], then settings that aren't the defaults.

Markers
  00:30.000  section  "Section 2"  mk_s2

V5 Text  trk_text  follow
  clip_txt1  00:02.000-00:05.000     3.000s  text "DECISION MODELS" callout  in popIn

V3 B-roll  trk_broll  follow
  clip_brl1  00:20.000-00:25.000     5.000s  servers.mp4 [00:01.000-00:06.000]

V2 Camera  trk_camera  cut
  clip_cam1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow
    ~ dissolve 0.500s into clip_cam2  tr_dissolve
  clip_cam2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  layout pipRight  scale 0.5 at 0.87,0.77  cutout  fx dropShadow

A1 Voice  trk_voice  cut
  clip_voc1  00:00.000-00:30.000    30.000s  take1-camera.mov [00:00.000-00:30.000]  linked #1  level -20 LUFS
  clip_voc2  00:30.000-01:00.000    30.000s  take1-camera.mov [00:32.000-01:02.000]  linked #2  level -20 LUFS

A2 Music  trk_music  follow
  clip_mus1  00:00.000-01:00.000  01:00.000  bed.m4a [00:00.000-01:00.000]  gain -31 dB  fade out 2.000s

Media
  med_camera  source/take1-camera.mov  camera  01:10.000  3840x2160 30fps  take take1 +0.500s
  ...
```

Each track line has the track's ID for commands that need one. Transitions
(`~`) sit between the clips they join, ending `sound clip_...` when one
plays a sound (that's its clip on SFX, whose own line says `sound of
tr_...`), and gaps in the take are listed as `gap`. When most of a track's
clips share settings (a PiP camera track's `layout pipRight, scale 0.5 at
0.87,0.77, cutout, fx dropShadow`), the track line says them once as
`(most clips: ...)`, each clip lists only what's different, and `not: ...`
marks a clip that lacks one of them. A clip that runs past its file
(`holdEdges`) shows how long it holds (`holds its last frame 00:00.600`),
and a title lists the style it sets itself (`style uppercase=false
shadow=false`).

A real edit runs to hundreds of clips, so start with `--summary` (one line
per track with its clip count, span and gaps, plus the markers), then read a
part in full with `--from 1:00 --to 2:00`. `--words` prints what each voice
clip says under it, and `--json` gives the project JSON (tracks keep only the
clips in the range).

## Transcripts, search and pauses

- `transcript <clip ID>` gives word timings in timeline time;
  `transcript <media ID>` gives the whole file in file time; with no ID you
  get everything said on the timeline.
- Word times are trimmed to the voice. Bark 3.0 Pro's words stop within
  about 0.1 s of it already; SpeechAnalyzer (the stand-in) times its words
  end to end, so each pause hides inside a word. Tandem pulls every word in to
  where the take's waveform is over its noise floor (about what ffmpeg's
  silencedetect hears at -32 dB on a phone take) when it reads the
  transcript, including transcripts made before it did.
- A word a cut runs through shows once, on the side where most of it
  plays, and a word with less than half of it left doesn't show: it was
  cut. Captions, `pauses`, `tighten`, `search`, `transcript` and `timeline
  --words` all follow this, and so does the app's transcript lane, so
  cutting a pause never doubles a word and cutting out a stumble takes its
  words with it.
- `search "phrase"` gives timeline ranges and the clips that play them. It
  ignores case and punctuation, marks hits a cut runs through as partial
  (one hit for each side, covering the phrase's words there), and also
  lists matches in material that was cut out.
- `pauses --min 0.6` lists the gaps between words in timeline time. Only
  gaps fully covered by transcribed speech count, so a hole in the take or a
  clip still waiting for its transcript is never reported as a pause. Each
  gap is listened to on every unmuted track of the take: `sound` has the
  gap as it's heard (from the end of the last word's sound to the start of
  the next's), its real pauses, and any sound in it no word accounts for
  (`heard`, with the tracks it's on): a breath, an "um" the transcript left
  out, someone off mic. `tighten` cuts beside that sound, never through it.
  Bark writes most "um"s and "uh"s as words (SpeechAnalyzer leaves them
  out), so those split the pause and stay until they're cut like any word.
- `media` shows each file's analysis state. Transcripts, loudness, proxies
  and cutout mattes are made in the background; tools that need a
  transcript say which files don't have one yet. `tandem wait` waits for
  them, and `tandem transcribe` makes a transcript of a file Tandem
  wouldn't transcribe by itself (see [setup.md](setup.md#background-work-transcripts-mattes-proxies)).

## Finding clips

`clips` lists clips with their ID, track, start, end and what they play,
filtered by `--track` (an ID, a name like `Camera`, or a label like `V2`),
`--from`/`--to` (clips overlapping that stretch) and `--media` (a media ID,
path or file name). `--ids` prints just the IDs, one a line. Use it to find
clip IDs instead of reading the whole timeline JSON:

```
$ tandem clips --track B-roll --from 0:15 --to 0:30
1 clip (revision 7):
  clip_brl1  V3 B-roll  00:20.000-00:25.000  servers.mp4 [00:01.000-00:06.000]
```

## Looking and listening

- `frame <time>` renders one frame (MCP returns the image, 1280 px wide by
  default). `clip <start> <end>` renders a 720p review MP4 you can watch.
  `--tracks Music,SFX` plays only those audio tracks (names or IDs), at
  the timeline's own level rather than mastered, so a stem sounds as it
  sits in the mix; the names go in the file name. `--audio-only` writes
  the sound alone as a `.m4a`, and `-o stem.wav` as 24-bit PCM. MCP's
  `clip` takes `tracks` and `audioOnly`.
- `frames <time>...` renders several frames the same way onto one contact
  sheet PNG, in time order, each labelled with its time in a strip
  underneath (so captions stay visible). `--every 5` takes one every 5 s
  through the timeline, or from `--from` to `--to` (`--to` is shown; the
  timeline's own end isn't); give times as well if you like. Each tile is
  480 px wide (`--width`, 64 to 1920), and a sheet holds at most 48. The
  default file is `frames-<first>-<last>.png`, with dots for the colons.
  Use it instead of looping `frame` and stitching the PNGs with ffmpeg.
  MCP's `frames` tool takes `times`, `every`, `from`, `to`, `width`,
  `format` and `output`, and returns the sheet as an image.
- `loudness --from 1:00 --to 1:30` renders the mix the way export does
  and prints its loudness every step instead of the per-file report. See
  [Check the sound](sound.md#check-the-sound).
- `frame`, `frames`, `clip` and `export` list what the render shows
  differently from the project, like `Warning: No cutout matte for
  ...-camera.mov yet, showing the full frame.` while the matte is still
  being made; only lines about what plays in the part rendered are shown.
- Titles in a font this Mac doesn't have are drawn in SF Pro, and never
  quietly: `frame`, `clip`, `export`, `captions`, `status` and `validate`
  all say so with the fix, like `Tilt Warp, the caption preset's font, isn't
  installed, so 42 text clips are drawn in SF Pro instead. Install it with:
  tandem assets use fontsource:tilt-warp`.
