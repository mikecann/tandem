# Review, checks and history

What `tandem check` looks for (including clipped words at cuts), seeing what changed with `diff` and `history`, putting clips back with `restore`, doing Mike's comments, review clips, and working in turns with Mike.

## Check an edit before handing it back

`check` looks for what Mike would otherwise catch in review, so his rounds
go on the edit itself. It renders every frame of the stretch small (384
wide, from proxies where they're ready), and the screen recordings again on
their own beside it, and reports, with the clips on screen there:

- black frames, and gaps with nothing on any video track;
- flickers: one to three frames unlike the frames either side, like a
  stale still or a frame of the wrong shot. Where the flicker is inside one
  clip of a video and the check can tell which picture flashed (the only
  video there, or the screen recording when its own scan flickers too),
  it comes with the `holdFrame` that holds the frame before it over it, as
  Mike fixed a one-frame jump in a screen recording in the Tandem video;
  the last line is a `tandem apply` that makes them all. One at a cut is
  usually a frame of the wrong shot: trim it instead;
- green screen that didn't key, and flat white blocks that come and go
  (a key or matte that failed);
- as notes that don't fail it:
  - pictures zoomed past three times their own pixels (1080p past 150%
    on a 4K frame), which look soft;
  - dead air: 0.8 s or more with nothing said, no sound effect, no music
    swell and a still picture. Speech is the words `pauses` reads, with
    their edges on the voice, so a 0.4 s sentence pause never shows up.
    Every other clip that's heard counts as sound while it plays (sound
    effects, demo sounds), and music only where its `audio.gainDB`
    keyframes rise or a new bed comes in. Mike moving in his camera
    corner, the Dock popping up along the frame's edge and a cursor nudged
    now and then don't count as movement; an animation, a result
    appearing, a slow fade or a cursor that keeps moving do. Section cards
    are never dead air. Cut it (`rippleDeleteRange`, leaving Mike's 0.4 s
    between sentences), or keep it only if the pause earns it: a point
    landing, the end of a paragraph. Until the take has a transcript, the
    check says so and doesn't judge its pauses.
  - page changes with no transition: the screen recording, judged on its
    own (as recorded, not zoomed, without the camera over it), changes a
    large share of its picture at once and then holds, where the viewer
    sees it (not under full-frame B-roll or the camera full frame) and no
    transition covers it. Typing, scrolling, a moving cursor and a demo's
    animations don't count. If it's a new page in an explainer or slides,
    push it: at a cut, a 0.7 s push on the Screen track with the light
    swoosh (`addTransition`); inside a clip, freeze 0.35 s either side of
    the flip (`freezeFrame` clips) and push between the freezes. A button
    that changes most of a page can show up too; leave those.
  - slivers: an enabled clip shorter than a frame at the project's frame
    rate, or a gap that short between two clips on a track, on any track.
    They're usually rounding left by a batch: delete the clip, or trim a
    neighbour to close the gap.
  - low frame rates: a screen recording the viewer sees (not under
    full-frame B-roll or the camera full frame) playing fewer than 12
    frames a second on the timeline, and under half the project's, for a
    second or more while its picture moves. macOS records the screen as it
    changes, so a recording's rate drops (to 4 to 7 fps while Mike was
    away from his desk in the Tandem video). A still page or a blinking
    caret at 4 fps looks the same as at 60, so those don't count. The rate
    is the file's own frame times (read from its sample table, cached per
    file) at the clip's speed, so a slowed-down clip can be low too. Cover
    it: Mike went full screen on his camera over it; B-roll works too, or
    cut it.

Run `tandem check --changed` before handing an edit back: it checks only
what agents changed that's waiting for Mike's review, half a second either
side. It exits 1 when it finds a problem; notes never fail it. `--quick`
skips rendering, so it only finds gaps, soft pictures, slivers and nothing
that needs the screen recordings scanned (page changes, low frame rates).

It renders the timeline in 10 s pieces, several at once, and keeps what it
measured in each in `.tandem/cache/check`. A piece is rendered again only
when something that draws in it changed (a clip, a transition near it,
the project's settings, a file or its proxy or matte becoming ready), so
the next check after a fix renders just the pieces the fix touched.

```
Checked 05:40.000-06:11.000 (930 frames) in 0.9 s: 1 problem:
  05:56.900-05:57.167  White block: a flat white patch over 13% of the frame comes and goes in 8 frames (a key or matte that failed?).  On: clip_w2fkvxg9 m-outro1
```

In Build Your Own Convex, two pauses on a chapter's title page, then the
explainer turning to the chapter's first page with no push:

```
Checked 13:30.000-13:50.000 (600 frames) in 2.1 s: no problems.
Notes (not problems):
  13:34.380-13:35.180  Dead air: 0.80 s with nothing said, no sound effect or music swell, and a still picture (after "is called the committer."). Cut it, or keep it if the pause earns it.  On: clip_nyc6dj73 2026-10-02_110856-camera, clip_5z5qpmkz 2026-10-02_110856-screen
  13:44.650-13:45.467  Dead air: 0.82 s with nothing said, no sound effect or music swell, and a still picture (after "one at a time."). Cut it, or keep it if the pause earns it.  On: clip_p8v54ivp 2026-10-02_110856-camera, clip_cmqvrmad 2026-10-02_110856-screen
  13:45.467-13:45.633  Page change inside a clip, with no transition: 18% of the screen recording changes at once, then holds. If it's a new page, push it: freeze 0.35 s either side and push between the freezes.  On: clip_huxupr6f 2026-10-02_110856-screen
```

### Clipped words at cuts (`--cuts`)

`tandem check --cuts` (MCP and HTTP `cuts: true`) checks only for words
clipped at cuts, and renders nothing, so it's quick. Run it after cutting
the take, with `--changed` or `--from`/`--to` as above. Most of Mike's
"word gets cut off" comments were cuts placed from transcript word times,
which are 30 to 100 ms off the sound (0.2 s for "processed" on the Ian
video), or snapped to the quietest point near a word's end, which lands in
the gaps inside words. So the sound says where the voice is, and the
transcript only whether a word boundary can be there. For every cut edge
on the speech tracks (two pieces of the take meeting, not a through-edit,
or a piece beside a gap) it reads the file's own sound either side of the
edit, in 5 ms frames, over the full band and again above 4 kHz, where a
final "s" or "t" is heard. Levels come from the 3 s either side of each
edge, since a take's loudness drifts: quiet is 9 dB over the noise floor
there (the quietest tenth), or 20 dB over it above 4 kHz, where breath
and mouth noise reach too. A real pause is quiet for 0.08 s or more in
both bands. A shorter quiet gap of 0.025 s or more is a gap between words
when the transcript has a word boundary by it: after one word's end, less
0.05 s, and before the next word's start, plus 0.05 s (Bark's word ends land
within about 30 ms of the sound, and its starts after a short gap about
110 ms late, which still leaves the gap after the earlier word's end). Any
other short gap is inside a word: the closure before the "t" of "extract",
which ran to 0.095 s on the Ian video, or the dip in "time" before its "m".
Without a transcript every short gap counts as inside a word. A take with
no voice in it (a screen recording's system sound) isn't judged.

An edge with the frame on either side of it in a real pause, or in a gap
between words, is fine: the clip ends in silence, or ends right as a word
it doesn't keep starts, even if that word starts 0.04 s on. Only the side
the clip keeps is judged. Any other edge is in sound. Voice at speech
level (within 10 dB of it) past the edge, in what's cut away, before a
pause or a gap between words, clips it whatever the clip's own side sounds
like: that's the rest of the kept word, like the "t" released after the
closure a cut is in, or the "pro" left before a clip that started on the
transcript's time for "processed". Voice past a gap between words is the
next word's, which the cut is meant to take. On the Ian video most of the
cuts a quiet clip's side passed were like that. Otherwise it's judged by its margin: how far the clip's
25 ms beside the edge is under the speech level (the loud end, 92nd
percentile, of the 3 s either side). The cut-offs Mike heard there were
within about 3 dB, and the clean joins 15 dB or more under. Under 9 dB is
a clipped word, a problem that fails the check; 9 to 15 dB is a marginal
join, a note to listen to; 15 or more is clean.

Each clipped edge says which clip's start or end, how much voice is cut
off, the margin, and its fix (`fixKind`):

- `trimToPause`: the trim (with ripple) that moves the edge into a real
  pause or a gap between words within 0.5 s, on a frame. It goes outward
  first, on past the cut-off sound into the cut material, finishing the
  word the edge is in: to the gap before the next cut word (for the end of
  a clip) or after the last one (for the start), even when that gap is
  under 0.08 s. It goes 0.03 s into the gap from the kept word's side (or
  halfway, in a shorter gap); into a real pause, the start of a clip goes
  0.08 s before its word, since a "p" or "t" bursts after a silent
  closure. Failing that, it goes back into a pause in what the clip keeps,
  dropping a fragment. It never brings back a cut word other than the one
  the edge is in, and never drops a kept word, including the one the edge
  is in when more than a sliver of it is kept.
- `putBack`: no such move, and the stretch cut at that join is 2 s or
  less, so the fix puts it back, filler and all, by trimming the end of
  the clip before the join on to where the next one starts in the take.
  On the Ian video that's what sounded right.
- `nothingNearby`: neither. Listen with `tandem clip` and recut it by hand.

When a trim back would drop a kept word, the problem names it (`drops` in
`--json`) and says so.

One clipped word the sound can't hear: a clip that ends right before the
last word of its sentence or clause, with that word cut. "a couple of lies
about [time.]" on the Ian video ended in the 0.055 s gap between "about"
and the "t" of "time", as clean to the ear as the "that [you know]" joins
Mike approved, but he heard the sentence cut off. So when the first word
cut (starting within 0.15 s of the edge, and cut whole) ends with . ? ! ,
; or : and the kept word before the edge doesn't, the edge is clipped,
even in a real pause, and the fix finishes that word: to the gap or pause
after it, or putting the cut back when there's none in reach, never a
trim that stops short of it. "Cut whole" means it's in the stretch cut
at the join, or the next clip on the track doesn't play it (it's another
file, or there's none); two clips of a take meeting at different speeds
may play it, so that doesn't count. "like" and "know" don't count:
cutting a "you know," or "like." filler is what Mike does.

Three more cuts leave a sentence wrong however clean they sound, all found
on the Ian video's final cut after it was signed off:

- The mirror of that: a clip that starts just after the first word of its
  sentence, with that word cut ("start TS. [It's] like the time"). The cut
  word follows one ending in . ? or ! (a comma isn't enough: "when you,
  [if] you were to" was a false start Mike kept cut), most of it is before
  the edge, it ends within 0.15 s of it, and it isn't an opener Mike cuts
  on its own ("So", "And", "Yeah"). The fix goes back before the word
  (`firstWordCut`).
- A clip that opens on the last word of the sentence cut before it: a
  short word (four letters or fewer) ending a sentence or clause, starting
  just after the edge, after a cut word that doesn't end one ("other
  places [do,] but I want to start off"). The fix starts the clip after
  it, dropping the leftover (`fragment`).
- A cut of a filler that took the "the" (or another determiner) before it,
  and nothing else ("And [the like,] challenge there"). The fix keeps both,
  past the filler: Mike's fix did, since "the" runs straight into "like".
  A cut that goes on through the word again ("the, like, the") is a false
  start, cut whole on purpose (`beforeFiller`).

The last line is a `tandem apply` that makes every fix (in `--json`,
`commands`, latest first, and `revision`; each problem's `cut` has
`clipID`, `edge`, `margin`, `fixKind`, `to`, `fix`, and `drops` (the kept
word a trim back would drop), `lastWordCut` (the sentence's last word,
cut right after the clip), `firstWordCut`, `fragment` and `beforeFiller`
when they apply; a marginal join's note has `clipID`, `edge` and
`margin`).

```
Checked 00:00.000-01:00.000 (4 cut edges) in 0.1 s: 1 problem:
  00:30.000  Clipped word at the end of clip_voc1: the voice runs on 0.12 s past the cut; the clip's last 25 ms is at speech level. Trim the end 0.167 s later, into the pause after it.  On: clip_voc1 take1-camera, clip_voc2 take1-camera
Notes (not problems):
  00:42.500  Marginal join at the end of clip_voc2: the clip's last 25 ms is 12.8 dB under the speech (clean is 15 or more, clipped under 9). Listen to it with tandem clip.  On: clip_voc2 take1-camera, clip_voc3 take1-camera
Fix: tandem apply --expect 7 --label "Move clipped cuts into pauses" '[{"trim":{"clipID":"clip_voc1","edge":"end","ripple":true,"to":30.166667}}]'
```

### Hearing each join (`--listen`)

The levels and the transcript's times can't hear everything. On the Ian
video's final cut, after it was signed off, transcribing the rendered voice
and reading the words across every join found five more cut-offs (and two
of the five it flagged were the transcription's slips). `tandem check
--cuts --listen` (MCP and HTTP `listen: true`) does that pass: for each
join in the stretch it renders the voice 3 s either side as it plays (the
speech tracks only, with 0.5 s of silence either side, which helps the
engine), transcribes it with Bark 3.0 Pro (SpeechAnalyzer when Bark isn't
downloaded), and lines the words up with the take's kept words there.

- A join can only cut off the end of the last kept word before it and the
  start of the first one after it, or leave a piece of a cut word there.
  So a `heardCutOff` problem is one of those two words not heard, the word
  before heard missing its end ("extra" for "extract"), the word after
  heard missing its start, or a word heard between them that the take
  doesn't keep ("oh" from the start of "okay").
- Anything else that differs is a `heardDifferently` note: a word further
  from the join, a word missing the end the join can't reach, a word heard
  as something else with nothing of it short (a name: Bark hears
  "Filmora" as "for mora"), a short word or a filler left out or added, a
  near spelling, an inflection ("happen" for "happened"), or a cut word
  heard whole (the transcript's times put it in the cut, but the cut keeps
  all of it). With two joins closer than 1.2 s, a word between them is
  blamed on the nearer one only.
- Words match loosely, and the finding says how: case, punctuation,
  numbers ("15" and "fifteen"), spoken forms ("wanna" and "want to"),
  letters spelled out ("t. s." and "TS").

Where a join is heard, the two checks weigh each other, since each on its
own over-flags: on Mike's published Tandem video they flagged 38 of 257
joins and 4 were real.
- A level flag is dismissed when every kept word across the join is heard
  whole, unless the clip's 25 ms at the cut is under 6 dB below the speech
  (there the cut is inside sound at full level, and the engine fills in
  what's cut: four joins Mike heard clipped on the Ian video were like
  that). A `lastWordCut`, `firstWordCut` or `beforeFiller` flag is
  dismissed when its word is heard in place, so the cut keeps it. A
  `fragment` stands: hearing the leftover only says it's there. Either way
  it becomes a `heardWhole` note that quotes what the check said.
- A listening finding is a note when the take's own transcript explains
  it: the word heard is one the transcript has at the edge, in the cut,
  heard whole (it runs through the edge, or the times are a little out);
  it sounds the same as the take's word ("mic" and "Mike"); the take's
  word is heard right beside it; nothing at all is heard on that side,
  where the take has words (the transcript's, over silence); or the take
  has the word twice there and it's heard once (a retake, or two tracks).
  A piece of a cut word ("extra" for "extract", "pub") is never explained.
- A join with both a level flag and a finding (any that isn't explained
  and isn't a slip, or a kept word at the join not heard right) is one
  `clippedWord` problem that says both, "and heard cut off (...)", with the
  levels' fix.

Where nothing was heard, or without `--listen`, the levels stand as they
are.

It always prints the take's words and the words heard across every join,
`|` at the join, so read them all for anything that doesn't run on (a
leftover heard as a whole word reads fine to the comparison), and listen
to what reads wrong with `tandem clip`. A join takes about a second the
first time. What's heard is kept in `.tandem/cache/listen` by the sound
rendered and the engine's model, so a check after edits only listens again
where the sound changed, and a new model hears everything again. It plays
what export plays: with a track soloed, only the soloed speech tracks.

Where a join wasn't compared, it says why (`skipped`, and "not compared"
in the list): "no transcript" (the take's words there aren't known yet:
it's heard, to read, and a warning names the files), "nothing heard" (the
engine heard nothing where the take has words, twice: its failure, never
cached) or "couldn't listen" (the engine failed there). An engine failing
at one join still hears the rest; Bark failing two joins in a row hands
over to SpeechAnalyzer, which hears the joins Bark missed too. In `--json`, `listened` has `engine`, `heard` and `cached` (how
many joins were heard this time and how many came from the cache),
`secondsPerJoin`, and `joins`: each with `time`, `said`, `heard`,
`clipIDs`, `cached`, `skipped` when it wasn't compared, and `findings`
(`kind`: `notHeard`, `heardAs` or `extra`; `said`, `heard`, `time`, `slip`
and `why`).

```
Checked 00:00.000-01:00.000 (4 cut edges) in 2.3 s: 1 problem:
  00:30.000  Heard cut off at the join: "be" is heard, which the take doesn't keep here (sounds like part of "because", which is cut). Take: "that | Now". Heard: "that | be Now.". Listen with tandem clip and recut it.  On: clip_voc1 take1-camera, clip_voc2 take1-camera
Heard across 3 joins with Bark 3.0 Pro (3 heard, 0.9 s a join, 0 unchanged since the last check):
  00:00.000
    take:  | So
    heard: | So
  00:30.000  cut off
    take:  that | Now
    heard: that | be Now.
  01:00.000
    take:  Now |
    heard: Now. |
```

## What changed, and putting it back

`tandem diff --since <revision>` (MCP `diff`) says what changed on the
timeline since then, clip by clip, grouped by edit with who made it and
where it was. Use it to find what Mike changed since your last round
(the revision you handed back at, or the one `status` gave you then)
instead of diffing `timeline --json` yourself:

```
$ tandem diff --since 95
Since revision 95 (now revision 98): 1 added, 1 removed, 2 changed, 14 moved.
r96  Trim  by user  00:12.000-00:12.500 on V2 Camera, A1 Voice
    changed  clip_cam4  V2 Camera  00:12.000-00:20.000  take1-camera.mov: start trimmed +0.500s, rippled
    changed  clip_voc4  A1 Voice  00:12.000-00:20.000  take1-camera.mov: start trimmed +0.500s, rippled
    moved  14 clips by -0.500s on V3 B-roll, V2 Camera, V1 Screen, A1 Voice (from 00:20.500)
r97  Swap the server shot  by user  00:40.000-00:44.000 on V3 B-roll
    removed  clip_brl3  V3 B-roll  00:40.000-00:44.000  servers.mp4
    added  clip_k2m9x8qa  V3 B-roll  00:40.000-00:43.000  racks.mp4
r98  Quieter music  by user  00:00.000-05:00.000 on A2 Music
    changed  clip_mus1  A2 Music  00:00.000-05:00.000  bed.m4a: gain -31 -> -35 dB
```

Each clip says what changed: added, removed, `moved`, a trimmed `start`
or `end` (and `start trimmed ..., rippled` where a ripple trim took it
off the start), `slipped`, a cut (`cut at ..., the rest is clip_...`),
and settings like `scale`, `position`, `opacity`, `crop`, `layout`,
`gain`, `fade in`, `level`, effects and keyframes. Clips that moved
together by the same amount, riding a ripple, are one line. Edits that
changed no clips (Tandem finding new media) are one line too. Media,
markers, transitions and settings aren't compared. `--json` has each
clip as it was and is (`before`, `after`).

`--since` takes:

- a revision. The edit history is walked back to it, so the changes come
  grouped by edit. Past the start of the history, a backup in
  `.tandem/backups` saved at that revision is used instead; otherwise it
  says where the history starts and what to use.
- a `.tandem` file: a backup, another version, or the snapshot every
  export writes beside itself (`exports/v3.mp4.tandem`). A backup of this
  project that the history reaches comes grouped by edit as well.
- an export (`exports/v3.mp4`), read from the snapshot beside it.

Paths are absolute or relative to the project folder (the CLI makes them
absolute from where you run it).

`tandem history` says where each edit was, so you can tell Mike's trims
apart without diffing anything:

```
$ tandem history
Revision 98.
Undo, newest first:
  Quieter music  (user)  00:00.000-05:00.000 on A2 Music
  ...
Edits, newest first (kept across restarts; tandem diff --since <revision> shows what each did to the clips):
  r98  10:42:01  Quieter music  (user)  00:00.000-05:00.000 on A2 Music  1 changed
  r97  10:41:30  Swap the server shot  (user)  00:40.000-00:44.000 on V3 B-roll  1 added, 1 removed
  r56-r95  09:58:02-10:30:12  Found new media x40  (system)
```

`tandem restore --from <revision, file or export>` (MCP `restore`) puts
clips back as they were there: where they were, their trims, settings and
keyframes. Name them with `--clips clip_a,clip_b`, or take every clip that
was between `--from-time` and `--to-time` (in that timeline's times), on
`--track` if given. A clip that's gone is put back on its track, one
that's changed is changed back, and one that wasn't there comes out. It's
a dry run until `--apply`, and then one undo step, made through the same
edit path as any batch (so it's checked, journaled and highlighted for
Mike). Transitions, media and markers aren't restored. If something now
sits where a clip goes back, the dry run says it wouldn't apply: restore
that clip too, or move it first. To rebuild a round Mike rejected:

```
$ tandem restore --from "exports/v3.mp4" --from-time 2:00 --to-time 3:30 --track B-roll
Restore 4 clips as they were in the export snapshot exports/v3.mp4.tandem (dry run, revision 120):
  put back  clip_b7  V3 B-roll  02:04.000-02:09.500  config.mp4
  ...
Nothing changed yet. Run again with --apply (or apply: true) to restore them. Transitions, media and markers aren't restored.
```

## Do Mike's comments

```bash
tandem comments                              # what he asked, where, with what's said and playing there
tandem apply '{"label": "Cut the umm before \"so\" (your comment at 08:40)", "commands": [
  {"rippleDeleteRange": {"range": {"start": 520.1, "end": 520.7}}},
  {"removeMarker": {"markerID": "mk_k3f9x2mq"}}]}'
tandem comments resolve mk_7hd2p4xa          # one you did in an edit without removing it
```

While he reviews, Mike leaves comments at moments on the timeline (Add
comment, Shift-C, or a double-click on an empty stretch in the app): notes
like "cut the umm here" or "this B-roll is wrong", shown in a Comments
strip under the ruler. They're markers of kind `comment`. When he asks you
to look at them, do each one, label the edit with what you did (he reads
the labels beside your highlighted changes), and remove the comment in the
same batch, so one undo puts both back. Comments move with ripple edits
like any marker, so list them again after one rather than reusing the
times you read first. Leave a comment you couldn't do, or weren't sure
about, and say why when you hand back.

## Hand back: what to look at first

```bash
tandem handback '[
  {"at": "2:45", "to": "3:10", "name": "Angles: ten zooms became two here",
   "note": "The busiest stretch; if it reads OK the rest will"},
  {"at": "1:12", "to": "1:16", "name": "Title 1 of 6: Where do we start?"},
  {"at": "27:12", "to": "27:18", "name": "Wikipedia's OLTP page over the 1970s aside"},
  {"at": "38:24", "name": "Keep the twenty dollar plan line?", "note": "Pro is $25 now", "question": true}
]'
tandem handback                              # next round: what he hasn't watched, with any comment he left beside one
```

A round can touch hundreds of clips (one angle pass on the Nipunn
interview changed 118), and in the app they're all highlighted the same.
Mike doesn't want to read times out of the chat and scrub to them. So
before your final message, hand back the two to five places he should
look at first: a stretch of a sweeping change that stands for the rest,
the new shot, the thing you weren't sure about. A few words each on
what's there (the `name`, at most 40 characters), one short line of
`note` for the trade-off or what to listen for (at most 80), and
`question: true` when you want his answer (he leaves a comment there,
which `tandem handback` and `tandem comments` both show next round).
Mike reads these off a small card while the stretch plays, so the
command refuses anything longer: the first card he saw was a paragraph,
and he had to read it all to see what it wanted. The detail belongs in
your final message.

In the app the review chip reads "3 to look at · 4 agent edits". `]`
steps him through them first, in timeline order, with your line in a
card over the viewer, playing each stretch and pausing at its end; after
the last, `]` carries on through the rest of your highlighted changes as
usual. Escape skips the walkthrough, and Mark reviewed clears everything.
One goes on its own once he's watched its stretch, so next round
`tandem handback` alone lists what he didn't get to.

They live in the review log beside your highlights, not in the project:
they move with the take when he tightens it, they never show in his undo
menu or an export, and what you hand back takes the place of what you
handed back before. `--to` defaults to 5 s after `--at`. Then tell him in
a line that Tandem will walk him through them, and keep the chat for
what needs a decision.

## Export a review clip

```bash
tandem frame 2:14.5 -o /tmp/frame.png        # one frame
tandem clip 2:00 2:30 -o /tmp/review.mp4     # 720p review render
tandem export                                # the full video, loudness matched
```

Plain `export` picks the preset that fits the canvas: YouTube 1080p for a
canvas 1080 pixels or less on its short side (1920x1080, 1080x1920),
YouTube 4K for anything bigger. A preset sets the codec, bitrate and
resolution class and keeps the canvas's shape, so `--preset youtube1080`
of a 4K project is 1920x1080 and of a 9:16 one 1080x1920 (`tandem help
export` lists the presets).

`clip` defaults to `exports/review <start>-<end>.mp4` in the project folder
and `export` to `exports/<name> r<revision>.mp4`. In MCP, `frame` returns
the picture directly, so you can look at the result of an edit.

## Work alongside Mike

- Read before you write: take the revision from `timeline` or `status` and
  pass it as `expectedRevision`. On `staleRevision`, read again.
- Note the revision you hand back at. Next round, `tandem diff --since
  <it>` says what Mike changed in between, edit by edit, and `tandem
  restore` brings back anything he took out that he wants again.
- Try a big batch with `dryRun` first.
- Give retried batches an `idempotencyKey`.
- Undo with `expectedRevision` so you only undo your own edit, and with
  `count` to undo several at once.
- `tandem watch --once` (MCP `watch`) waits until the project changes, for
  example after asking Mike to fix something in the app. `tandem watch`
  prints every change as it happens.
- Mike reviews your edits in the app rather than watching the whole video
  again: every batch that changes the timeline and isn't his is
  highlighted there (the clips it added or changed, a mark where it took
  something out) until he plays through them (each clears once he's
  watched all of it) or marks them reviewed, and he steps from one to
  the next. Label batches with what they do (`"B-roll over the config
  file"`), since that's what he reads when he hovers one.
- `tandem status` lists your edits still waiting for him as `waiting for
  Mike's review` (`reviewPending` in JSON: each edit's label, author, date
  and the clip IDs it added or changed). It's read-only; only Mike clears
  it, from the app.
