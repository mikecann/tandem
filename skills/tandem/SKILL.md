---
name: tandem
description: Edit Mike's videos in Tandem, his Mac video editor, through the `tandem` command. Use when a video folder has a .tandem project, or when asked to cut, trim, tighten, place B-roll, add titles, section cards, transitions, captions, stickers, music or sound effects, look at frames, render a review clip, check an edit, do Mike's comments on the timeline, or export a video in Tandem.
---

# Tandem

Tandem is Mike's video editor, built for working in turns with an agent:
you edit the project through the `tandem` command, Mike reviews in the
app, and the timeline shows him exactly what you changed. The guide's
entry point is `docs/AGENTS.md` in the Tandem repo
(`~/dev/me/tandem/docs/AGENTS.md` on Mike's Mac): how editing works, the
command index, and a table of recipes and topics in `docs/agents/` (B-roll,
titles, cards, shorts, captions, sound, review and more). `tandem help
<command>` gives a command's options, and `tandem help <edit command>`
(like `tandem help addTransition`) an edit command's arguments and example.
Read the parts you need before editing.

## Setup

- Run commands from the video folder, or pass `--project <file.tandem>`
  when it holds more than one project.
- `export TANDEM_AUTHOR=claude` (or `--author claude`) so your edits are
  credited to you in the app.

## The loop

Before you change anything, run `tandem status`. If it shows "waiting for
Mike's review: N", stop there, change nothing, and ask him: "There are
still N unreviewed changes in Tandem. Are you sure you want me to
continue?" Carry on only once he says yes. He reviews a round before
asking for the next, and new edits on top of unreviewed ones mix the two
rounds up.

1. **Read.** `tandem status`, `tandem timeline --summary`, then
   `tandem timeline --from 1:20 --to 1:40` for detail. `tandem transcript`
   and `tandem search "<phrase>"` find what's said where. `tandem clips
   --track B-roll --from 1:20 --to 1:40` (or `--media <file>`, `--ids`)
   gives clip IDs; don't dump `timeline --json` to look them up. Tandem
   transcribes camera takes and the voice by itself; for anything else with
   sound (generated B-roll checked for made-up speech, a sound effect or
   music take), `tandem transcribe <id or path>` makes one on-device and,
   with the app closed, waits and prints the word count ("no speech" is an
   answer). Then `tandem transcript <id>`. Background work (transcripts,
   mattes, proxies) is waited for with `tandem wait transcript` (or
   `matte`, `proxy`, plain `tandem wait` for every job), which makes it
   itself when the app is closed. Never start `tandem serve` just to get a
   transcript, and never poll `tandem media` or `tandem status` in a sleep
   loop. Only if Tandem's transcript can't do it (a language its
   engines don't support), local Whisper runs offline:
   `mlx_whisper --model mlx-community/whisper-large-v3-turbo --language en --word-timestamps True -o "$TMPDIR" <file>`
   (one file per call; on long recordings with silences add
   `--condition-on-previous-text False`, or it loops one phrase through
   the quiet).
2. **Edit in labelled batches.** `tandem apply '{"label": "B-roll over the
   config file", "commands": [...]}'` makes one undo step, which Mike reads
   by its label. Pass `--expect <revision>` from the read you based the
   edit on (`tandem status --revision` prints just the number), not one
   taken right before applying, so you never edit over his changes. Tandem
   finding new media doesn't make it stale. On a stale revision, read
   again. Try big batches with `--dry-run` first. Name tracks by name
   (`"trackID": "Music"`) rather than looking up IDs, and give one
   `updateClip` patch to many clips with `clipIDs`. The `--json` shapes are
   in docs/agents/json-output.md.
   For a job that touches many things at once (every caption, every push),
   write a short script against the SDK in the Tandem repo's
   `sdk/` folder instead of hand-building JSON or throwaway Python:
   `~/.bun/bin/bun ~/dev/me/tandem/sdk/run.ts "<name>.tandem" script.ts`
   (or `-e '<code>'`). `t.project()` finds clips, transitions and captions,
   `t.edit(label, commands)` dry-runs then applies one labelled batch against
   the revision you read, and it prints only what the script returns.
   `sdk/README.md` has the API and `sdk/examples/` the caption fix, swooshes
   on pushes and music swells. Small edits are still quicker with
   `tandem apply`.
3. **Look.** `tandem frame <time> -o frame.png` for a still,
   `tandem frames <t1> <t2> ...` (or `--every 5 --from T --to T`) for
   several on one labelled contact sheet, never `frame` in a loop stitched
   with ffmpeg,
   `tandem clip <start> <end>` for a 720p review MP4. Look at what you
   changed instead of trusting the numbers.
   For sound, measure with Tandem, not ffmpeg on a review clip:
   `tandem loudness --from T --to T` prints the mix's momentary and
   short-term loudness every step (`--tracks Music` for one track,
   `--step 0.2` for finer rows), `tandem clip T T --tracks Music
   --audio-only` renders a stem to listen to, and `tandem assets show
   <id>` gives an asset's prompt, licence, loudness and file instead of
   its `meta.json`. If Mike says a gain change plays late or not at all,
   believe him and run `tandem loudness --from T --to T --gains`: it
   checks the render against the gain lanes and says by how much a change
   lands late.
4. **Check.** `tandem check --changed` before you hand back. It renders
   what you changed and finds black frames, flickers, green screen that
   didn't key, white blocks and double jumps (B-roll a few frames off a
   camera cut). A flicker it can fix (a frame jumping in a screen
   recording) comes with a `holdFrame`, and a double jump with the
   `updateClip` that runs the shot out to the cut, in the `tandem apply` on
   its last line. Fix every problem it reports. If you cut the take, also
   run `tandem check --changed --cuts` and the listen check for words
   clipped at the cuts, and judge its cut findings by ear rather than
   applying them blind (see "How Mike likes a take cut"). Its notes are
   judgement calls, but go through each one:
   - soft zooms;
   - dead air: 0.8 s or more of a still picture with nothing said and no
     sound effect or music swell. Cut it, or keep it only if the pause
     earns it (see "Longer gaps where they earn it");
   - page changes with no transition: the screen recording turns to a new
     page and nothing covers it. Push it if it's a page in an explainer or
     slides (see "Page changes in an explainer or slides"); a demo button
     that redraws the page can show up too;
   - low frame rates: the screen recording moving at a few frames a second
     (macOS recorded it slowly). Cover it with the camera full screen, as
     Mike did in the Tandem video, or B-roll, or cut it.
5. **Hand back.** Open the project in the app for Mike with
   `open "<video folder>/<name>.tandem"` (skip it if `tandem status` says
   the app already has it open), rather than asking him to open it. Then
   `tandem handback` with the two to five places he should look at first:
   a stretch of a sweeping change that stands for the rest (one angle pass
   on the Nipunn interview touched 118 clips), the new shot, the thing you
   weren't sure about, each with a few words on what's there (40
   characters at most) and one short line of `note` for the trade-off or
   what to listen for (80 at most; he reads the card at a glance while the
   stretch plays, so the command refuses longer); `question: true` when
   you want his answer, which he leaves as a comment there. Tandem walks him through
   them before the rest of your highlighted changes, so he doesn't read
   times out of the chat. Then tell him in a few lines what you changed
   and why, and that Tandem will walk him through the things to check,
   keeping the chat for what needs a decision. Your edits stay highlighted
   on his timeline until he plays through them or marks them reviewed;
   that's his to do. Next round, `tandem handback` alone says which he
   didn't get to, with any comment he left beside one.

## Mike's comments

While he reviews, Mike leaves comments at moments on the timeline ("cut
the umm here"). When he asks you to look at them, `tandem comments` lists
each one's ID, time and words, with what's said and playing there. Do
each, label the edit with what you did, and put
`{"removeMarker": {"markerID": "<id>"}}` in the same batch so the comment
goes with the fix (or `tandem comments resolve <id>` after). Comments move
with ripple edits, so list them again after one. Leave any you couldn't
do, and say why when you hand back.

Plan the rounds so his watches count: get the B-roll, sound effects and
music in before his big watch. Then he watches the whole video about twice,
instead of three comment rounds plus separate listens for the sound effects
and the music (Build Your Own Convex retro).

## What Mike changed

Note the revision you hand back at (`tandem status --revision`). Next
round, `tandem diff --since <that revision>` lists what changed since,
clip by clip, grouped by edit with who made it (Mike's edits are by
`user`) and the times and tracks of each. `tandem history` says where
each edit was too, and both last across app restarts. `--since` also
takes an export (`exports/v3.mp4`, read from the `.mp4.tandem` snapshot
beside it) or a backup in `.tandem/backups`. Never diff `timeline --json`
against snapshots in Python.

To bring back clips Mike took out or an earlier round he wants again,
`tandem restore --from <revision or export> --clips <ids>` (or
`--from-time 2:00 --to-time 3:30 --track B-roll`). It's a dry run until
`--apply`, then one labelled undo step. It restores clips only, not
transitions, media or markers.

## How Mike likes a take cut

- **Tighten with `tandem tighten --mike`,** not a script of your own. It
  does the rules below by what each pause follows (0.4 s after a sentence,
  0.12 s after a comma, 0.08 s for a thinking pause mid-sentence, only
  pauses of 0.5 s or more; a join never keeps under 0.03 s after a word or
  0.08 s before one, so mid-sentence comes out at 0.11 s). Keep his
  deliberate beats with
  `--protect <time,...>`, and add `--widen` to open joins a cut left too
  tight back out from the take's own silence (listen to those). Dry run
  first, then `--apply`. It places each cut in the sound of every track
  that plays there, never through sound the transcript doesn't know about
  (someone off mic, an app, a breath, an "um"), cutting the quiet either
  side of it, and lists the pauses it left alone for that, with where the
  sound is: listen to them, and cut a stray "um" with `tandem cut --range`
  if it should go. Bark writes most "um"s as words, so they split pauses
  and stay until they're cut: run `tandem cut --fillers` before tightening.
- **Never place an edge from transcript times,** with or without a margin.
  Mike heard Ian "cut off" 10 times over 4 review rounds on the whiteboard
  interview: "it's quite a common problem that we seem to get wrong,
  correctly placing the cut points" (2026-10-22). Word times are 30 to
  200 ms off the sound, sometimes more: "processed" started 0.2 s early, so
  an edge on it cut off "pro". Don't snap to the quietest point near a
  word's end either: the closure before a final "t" or "k" is a silence
  inside the word, so "extract" became "extrac" and "takes" became "ta".
  A final "s" hardly registers below 4 kHz, so look above it too. And a
  clean-sounding cut in the short gap before a sentence's last word drops
  that word whole: "a couple lies about [time.]" on the Ian cold open.
  A filler taken out of running speech ("do that [because of] to keep")
  leaves no pause at all, so the kept word is chopped mid-sound.
- **Cut with `tandem cut`,** not `cutRanges` built from `search` times.
  `tandem cut "<phrase>"` (or `--range <start>-<end>` for a rough cut,
  `--at` for a phrase said twice) puts both edges of each cut in a real
  pause found in the audio and leaves in a filler with no pause round it,
  which is what sounded right on the Ian video. `--fillers` does that for
  every "um" and "uh" in the transcript (`--from`/`--to`, `--protect`).
  Long false starts are cut
  pause to pause anyway. Dry run first, then `--apply`; it's one undo step.
  Keep `cutRanges` for exact cuts you've checked yourself.
- **Then check every join three ways,** after every batch and across the
  whole timeline, not just the joins you touched. In round 3 Mike still
  found two cut-offs, both at edges placed from transcript times and never
  re-checked. No one check is enough alone.
  - `tandem check --cuts` (with `--changed` or `--from`/`--to`) reads the
    take's own sound either side of every cut. Use it rather than an
    energy script of your own (agents wrote one about 15 times).
  - `tandem check --cuts --listen` renders the voice across each join,
    transcribes it, and flags a kept word at the join that isn't heard or
    is cut short, or a piece of a cut word left in. It replaces the
    hand-rolled Whisper listen, which caught the "pro" cut off "processed"
    that every level check passed.
  - Then read every join's take/heard pair in its output, not just the
    problems, for a sentence that no longer says what he said, and
    `tandem clip` around anything that reads wrong. "a little bit [okay]
    that" passes both the levels and the listen: only reading catches it.
    After Mike signed off the Ian video, reading the joins found six more
    cut-offs ("in the recent | point" for "recent past", a lost "It's", a
    stray "do", "the", "this" and "okay"), and the listen found a seventh
    ("about the re- |" for "requests").
- **When Whisper drops an edge word, the edge is wrong.** Whisper fills in
  a partly cut word, so a word missing entirely is mostly gone. On the Ian
  cold open it dropped "time." from "a couple lies about time."; the agent
  overruled it from the waveform, and Mike: "again its cut off here, Ian
  doesnt say what there are a couple of lies about" (2026-10-22). The cut
  sat in the 55 ms gap just before "time", so all of it went. Move the
  edge until the word comes back.
- **Still confirm `check --cuts` with a listen.** Since 22 Oct 2026 it
  uses the transcript's word times to tell a short gap between words from
  a dip inside one (9 of the Ian video's 290 approved joins flagged, down
  from 25). Its fixes move outward first and never drop a kept word, and
  it flags a dropped first or last word, a fragment of a cut word, and a
  word cut with the filler it runs into ("you have [this, like]"). Its word
  times can still be off (Bark put a 45 ms gap between "problem." and
  "There's" inside "There"), so run `check --cuts --listen`, read every
  join's take/heard pair as above, and `tandem clip` around anything it
  flags or that reads wrong before you act on it.
- **Fixes, in order:** move the edge into a real pause nearby (70 ms or
  more, found in the audio), or into the gap between words just before the
  next cut word, even under 70 ms; put back a removed filler of 2 s or less,
  since a natural "um" beats a chopped word; cut a long false start pause
  to pause, even if a word of the restart comes back; a 50 to 80 ms fade
  only as a last resort.
- **Restored words must finish the thought.** "but it does, you know..."
  put back on its own sounded like Ian being cut off.
- **The raw-mic floor rule is a minimum, not proof.** On the raw mic (not
  the voice-isolated mix, whose near-digital silence breaks it), the kept
  audio must sit within about 9 dB of the room's quiet level (the 8th
  percentile over ±3 s) for 40 ms before each out-point and 40 ms after
  each in-point, and no in-point may open on a 15 to 20 ms blip of the cut
  word's tail. The "time." cut passed it: it sat in the gap before the
  word, and the word went missing whole.
- **Pauses between sentences: 0.4 s.** It's the feel of his old Filmora
  silence detection (0.4 s softening buffer, 0.5 s minimum, 25% volume
  threshold). 0.2 s sounds rushed, as if the sentences are jammed together.
  A cut that removes a retake or a stumble should leave about 0.4 s of real
  silence across the join too, not trim right up to the words.
- **Longer gaps where they earn it:** the end of a paragraph, letting a
  point land, or while something animates on screen (a build finishing, a
  result appearing, a diagram moving). Never cut a pause while a demo
  animation plays, even if he isn't talking. But cut silent holds where
  nothing meaningful happens: clicking around, flicking between pages, the
  Dock popping up, him looking blank before the next section. He flagged
  about 15 of those 1 to 3 s holds as "awkward silence" in Build Your Own
  Convex. Look at the frames: a mean frame difference can't tell an
  animation from a click or a page flick. `tandem check` notes the still,
  silent ones as dead air: Mike only caught one at 3:56 on his final watch,
  and it cost a 13.7 GB re-export. One exception: a celebration line
  ("Congratulations, party time") cuts straight on, even over confetti; he
  doesn't want to sit there silently smiling.
- **No clips under 2 s,** where all it takes is putting back a pause of a
  second or less between sentences. Never bring back a thinking pause or a
  long silence to do it.
- **The ending:** run on about 4 s after the sign-off, with a 3 s fade to
  black that starts about a second after it, and fade the music out with
  it. A 2 s fade at the end of a 5 s run-on "can probably start to fade
  out a bit sooner" (Muse Wonder, 2026-10-13). Run on with the real
  footage: a freeze of his last frame "looks weird" (What I Need video,
  2026-10-09).
- **Mid-sentence pauses:** close his thinking pauses, 0.5 s or longer,
  right up (to about 0.08 s, `--mid 0.08 --mid-min 0.5`, part of `--mike`),
  so a sentence sounds like one thought. Leave
  shorter ones (a breath, a natural pause) as he said them: closing every
  gap of 0.2 s or more made 818 cuts in a 38-minute video, one every 2.8 s,
  and the picture jumped around (Mike, 2026-10-05). The 0.4 s is for
  between sentences. Leave live demo reactions alone.
- **Live demos: keep the playback.** When Mike plays the timeline back to
  show the viewer ("let's have a look", "let's listen"), keep that stretch
  even though he's silent: "When I'm explicitly telling the user I'm
  playing something back, don't cut it out just because I'm silent"
  (Tandem video, 2026-10-16; he flagged eight of them). The screen
  recording's system audio track shows it: a cut stretch with Tandem's
  sound in it was playback. Put that audio on its own track under him.
- **Live demos: cut the mistakes, not the material.** Remove silences,
  retakes, false starts and off-camera chat, but keep every point he makes,
  asides and pontificating included, even if it runs long. He trims for
  length himself: "you cut too much stuff out... If there's any section
  that I think that we should cut out, maybe I'll cut it out myself"
  (2026-10-16).
- **Live demos: when he leaves the desk,** go full screen on his camera
  from when he says he's going ("Cup of tea time") until he's back at the
  screen, and cover the time away with a time card meme, with its sound,
  rather than a sped-up fast-forward with a "100x" badge: "I don't think we
  need to do the 100x here... can you download that 'some time later'
  meme?" (Tandem video, 2026-10-17). SpongeBob's card says "A Few Moments
  Later"; its sting sat well about 2 dB above his voice. Full screen also
  hides the screen recording while he's away, where macOS only captures on
  change and it dropped to 4 to 7 fps ("why does this part... go like a
  really low frame rate?").
- **Editor's notes:** Mike says them out loud in the take ("editor's note:
  cut that bit"). Read the transcript for them before cutting, and remove
  both the note and what it points at.

## How Mike likes the rest of the edit

From his review comments on the Daytona and Build Your Own Convex videos
(October 2026). The reasons matter more than the numbers.

- **Sync first.** His webcam picture lags his USB mic, so lips and voice
  drift apart (it spoiled the first Daytona upload and the ESLint video). A
  clap test on 2026-10-02 measured about 75 ms (±20 ms). Tandem fixes it
  per file: a camera take's `pictureDelay` makes every clip of it show its
  picture that much later, everywhere, while the sound and cuts stay put.
  Record It takes the lag out as it records (from 2026-10-03; Tandem shows
  those takes "in sync as recorded" and leaves them alone), and older camera
  takes get Tandem's default (0.08 s on his Mac). `tandem sync` shows each
  file's delay; `tandem sync 0.08` sets it on a project made before the
  default. Never slip clips by hand as well, or the delay
  doubles: undo old hand slips (Daytona's +0.09 s) before using it. Don't
  chase exact: the webcam only gives about 22.5 real frames a second (it
  repeats 3 of every 12), so sync wobbles by up to 30 ms whatever you pick.
- **Edits can break sync too.** On the Ian video one `placeMedia` with
  `mode: overwrite` trimmed 60 ms off the next voice clip's head and put
  Ian's voice 60 ms early for 20 minutes. Place or insert instead, and check
  voice-to-picture sync across the whole timeline after every batch.
- **Open on his face.** The first thing on screen is Mike talking to camera,
  and B-roll comes in after his first line. Build Your Own Convex opened on
  24 s of kinetic text, a cartoon and a terminal before his face appeared,
  and a viewer with a TV and stage background said he couldn't tell whether
  the whole video would be voiceover. Mike: "next time ill make sure that I
  show my face early and not launch immediately into broll stuff" (X,
  2026-10-11). Through the first 30 seconds, when people decide whether to
  stay, cut back to him between inserts rather than chaining B-roll.
- **B-roll moves at his pace.** Whip transitions, quick cuts of his words
  and a terminal typing "blazing fast" under his calm voice felt mismatched
  on the same open. Typing in built B-roll goes at a speed you could read
  along to, and transitions stay as calm as his delivery. (Demos where speed
  is the point still play in real time, below.)
- **B-roll starts and ends on sentence boundaries:** the take's cuts, or a
  real pause between words. Never 0.2 s off a cut or mid-word. If less than
  about 1.5 s of camera would show between two B-roll shots, join them. A
  quick flash back to the camera looks like a glitch. Use `holdEdges` when a
  shot runs short. The same goes for a camera cut under B-roll: a shot that
  starts just after one, or ends just before one, shows a few frames and
  jumps again, "a double jump... it's kind of a bit disorientating" (Ian
  video). Within about 0.75 s, extend the B-roll to the cut, holding its
  edge frame. Check every edge against the take's cuts after placing, not
  only against word pauses: placing by pauses alone left 11 shots 1 to 17
  frames off a cut on the batching video, and Mike caught the first 5 s in,
  "it cuts and then like a few frames later it shows the b-roll... quite
  distracting" (2026-10-27). `tandem check` (`--quick` too) now flags both
  as problems, double jumps and camera flashes, each with the `updateClip`
  that runs the shot out to the cut, in the `tandem apply` on its last line.
- **Show what he says.** When he names a thing (a dashboard table, a docs
  page, a claim someone made, a price), put the real thing on screen while
  he says it. A highlight (the $200 free credit) appears when he says it,
  not before. When he mentions a person (Jamie Turner, Convex's CEO), put
  their photo above their name's lower third. A colleague who already has a
  cartoon from an earlier video can pop in as it instead: on the component
  tree Short he asked for Nicolas from the ESLint video "in the corner...
  pop in from the side or something, And make him say hello like he did in
  the other one" (2026-10-26). Reuse the archived green-screen clips and
  voice, keyed to HEVC with alpha (`avconvert --preset
  PresetHEVCHighestQualityWithAlpha`; Tandem couldn't read ffmpeg's
  hevc_videotoolbox file), and land the hello in a pause in his speech. The
  build is in `component-tree-switcher/notes.md`.
- **Show what he says in a live demo too.** In his last review of the
  Tandem video, 9 comments were B-roll asks for things he named, live or on
  camera: Filmora when he first names it, then Filmora itself in use (the
  features, cutting pauses by hand), Voice Type, the YouTube comment and the
  X poll he mentions, his What I Need video, ArtCraft's own app pages, and
  the real mash-up videos: "show actually video of this, not just
  screenshots". A news article is the fallback, not the first pick. Web
  pages go in a browser window with the address showing: "make it look like
  this is actually inside a web browser... so people don't think this is
  actually Windows XP". When he says "I'll put some B-roll on after this",
  put it there. His own past demos count: the Voice Type clip came from his
  February X post.
- **One thing at a time.** A card with the wrong and the right example side
  by side was "a bit too much to read at the same time as listen to what
  I'm saying": put each up on its own as he says it (What I Need video,
  2026-10-09). Text he points at must be readable on a phone; if a real
  page's line is too small ("Mad Scientist @ convex.dev" in his X bio),
  mock that bit up bigger rather than shrinking the page.
- **Section cards: about 3.2 s.** 4 to 4.8 s felt a touch long, 2 s far too
  short. "A touch shorter" means a modest change, not the number he floats.
  To lengthen or shorten a card, open or close time only in the take's gap
  under it (`insertTime` or `rippleDeleteRange`). The cards wipe over the
  edges of speech. Then stretch the music bed that spans the card, because
  clips that span an inserted point don't grow. Titles and subtitles have
  to make sense on their own: he swapped "Adding it" for "Setup", and
  "VIBES FIRST, THEN DATA" "doesn't really make any sense".
- **Music around cards.** The track plays through the whole card and never
  cuts out under it. A new track starts right after a card ends, at chapter
  breaks only. Swell about +14 dB in the card's speech-free middle with
  `audio.gainDB` keyframes (they set the gain outright, times are
  clip-relative), and back down before he speaks. The whimsical underscore
  is for the intro only. Give the outro its own track.
- **Music beds: one per chapter** (he loved them on Build Your Own Convex).
  Generate a test batch of three first (the cold open, a middle chapter and
  the outro) and get his OK before making the rest. Each bed starts on the
  push or cut into its chapter and fades out over 2 s at the next. Ask the
  generator for the chapter's length plus about 10%: ElevenLabs once came
  back 27 s short, fixed with a beat-matched 10-bar repeat and a 1 s
  dissolve. Level every bed to -45 LUFS, about 25 LU under his voice. Swell
  +6 dB only in pauses of 1.6 s or more with no demo sound effects, and
  +8 dB after the sign-off. Check a swell landed with
  `tandem loudness --from T --to T --tracks Music`. A chill lounge kit sat under demo sound effects
  without fighting them: Rhodes, soft pads, round bass and brushed drums at
  about 85 BPM, with no hi-hats, bells, glockenspiel or marimba.
- **Show options in the chat.** When he's picking between looks, beds or
  layouts, send the stills or preview MP4s as files in the conversation,
  not paths: "How do I view those? Can you just show me them in here?"
  (Ian video).
- **Re-check the music after his own edit pass.** He locks the music track
  so his cuts can't slice it, but a locked track never moves, so his ripple
  cuts leave it behind: on the Tandem video the music ran 2.5 minutes past
  the picture and card 4's swell played 2.5 minutes after the card ("why
  does the music suddenly get loud at the end here?"). After any edits that
  change timing (his or yours, with music locked), check that each card's
  swell sits under its card and the outro ends with the picture. Fix by
  unlocking, laying the beds again or moving them, and locking it again
  (mikecann/tandem#33).
- **Linked sounds:** a card's whooshes are linked to it, so trim either with
  `"includeLinked": false` or you drag the other along.
- **On-screen text moves in and out,** in his words. A question or callout
  slides in and slides off (position keyframes), rather than popping in and
  vanishing. He liked the typewriter reveal with a typing sound. Use his
  exact words, a word or phrase at a time as he says them: "WHAT, NOT HOW"
  over "what to do next, not how to do it" "doesn't align with what I
  actually say". A cliché he's sending up gets a gag: "one weird trick"
  went up word by word with WEIRD wobbling to a wobble sound, and "game
  changer" flashed and shook to the meme DJ air horn (What I Need video,
  2026-10-09). A stadium air horn there was "really annoying": he meant the
  tongue-in-cheek hype horn. ElevenLabs only made that one when the prompt
  named it ("reggae dancehall sound system DJ airhorn sample, the famous
  MLG meme air horn") and spelled out its "ba-da-BAAAAH" rhythm and reverb
  tail; check takes with an audio model before placing one.
- **Typing gets a keyboard sound.** A message typed in an app mock-up gets
  keyboard typing from the first character to the send ("I've done that in
  the past on Filmora projects and it worked quite well"), about 13 LU
  under his voice, near the typewriter callouts' level.
- **Demos where speed is the point** play in real time, with no cuts, so
  viewers can see how fast it really is.
- **Demo sound effects land on the picture.** Snap each sound to the first
  frame its element visibly changes, within 80 ms either way. Steps replayed
  from a script's `setTimeout` drift about 6% against the recording, so time
  them from the frames, not the script. Drop duplicates under 34 ms apart
  (the same frame). A reusable tool for this is being packaged at
  `~/dev/convex/convex-videos/tools/explainer-sfx/`: use it once it's there
  rather than writing your own.
- **Page changes in an explainer or slides** push: a 0.7 s push in its
  default direction on the Screen track only, with the light swoosh
  (`"sound": {"gainDB": -23.3, "offset": -0.39}`), so he stays put in his
  corner ("don't slide me, just slide the screen"). Pushes, not slides:
  "pushes are better than slides" (BYOC v2). It breaks the sections up
  visually. Check the page flip isn't within half the push's length of the
  cut, or a borrowed frame shows the wrong page. For a flip inside a clip,
  freeze 0.35 s either side of it (`freezeFrame` clips) and push between
  them. Find every page change from the screen recording itself, not from
  your cue list: one built from cues missed 10 on Build Your Own Convex,
  and Mike pushed them by hand. `tandem check` lists the ones with no
  transition as page change notes.
- **Picture-in-picture only when he's driving the screen.** When Mike clicks
  and moves the mouse on a recording, he sits in the corner (pipRight) over
  it. When he's reading a script to camera, B-roll goes full screen on the
  B-roll track above him and the edit cuts back to him every so often: no
  corner ("What I need from you" video, 2026-10-09: "this is not a picture
  in picture video"). Give long runs of B-roll a 2 s+ cut-back to him on a
  reaction or bridging line, and tell the B-roll builder which layout it's
  for before it renders, since a corner-safe layout looks off-centre full
  screen. Cut back for an aside he acts out, too: "Bruce being one of the
  Mac minis in my house here" wanted his face ("it's the important things
  to focus on my face when I'm saying something like that").
- **Break up long talking-head stretches.** A 10 s opening line in the cold
  open and a 14 s run mid-video both got "break up this big long talking
  head section". Reach for a real screen that carries the example on first.
  A cartoon (`mike-cartoon-broll`) only when it adds a joke or reaction the
  words don't, like the paper avalanche on "so frustrated... so much text".
  Viewers pushed back on generic AI people and on cartoons that just fill a
  gap (October 2026); that skill has the details.
- **Screen recordings fill the frame,** for people watching on a phone:
  one static `zoomToRegion` per page, fitted to the content with a small
  margin, at most 1.5x, and no zoom changes within a page.
- **Split overlays before a ripple edit under them.** B-roll and graphics
  are follow tracks: a ripple cut under one shortens it at its tail, so
  the graphic runs late and loses its ending ("you seem to have cut off the
  end of the motion graphic", Ian video). Blade the overlay at both ends of
  the cut range first. To add time under one, blade it at the join and
  insert a freeze-frame clip (`freezeFrame: true, holdEdges: true`) for
  the added time: extending the left piece replays frames, so the graphic
  jumps back.
- **Sweep for leftovers after any batch of cuts or a rebuild.** Restoring
  cut stretches left 88 clips of 1 to 10 ms (one flickered) and some
  microsecond overlaps that made every later `apply` fail with "Clips X and
  Y overlap". List clips shorter than a frame and adjacent clips that
  overlap at all, and close them up (remove the sliver, pull the next
  clip's start back to it; mikecann/tandem#48 and #49). Fill tiny picture
  gaps, and drop fades on joins that became continuous: they dip mid-word.
- **Before uploading,** watch the start of the export, where sync problems
  show first. The limiter takes about 8 dB off his voice's peaks to reach
  -14 LUFS, and he hears that as artificial, so he asked for -16 after
  Daytona: `updateSettings {"patch": {"loudnessTarget": -16}}`. Set it when
  the edit starts, not at the end: Let's Build It sat at -14 until the
  last round, where the limiter squashed 18 s of it (up to 10 dB off his
  loudest words), and -16 left 4 s. Every export preset masters to the
  project's target and says what it used.

### A hot-takes cold open

The best moments cut together before the first line, to draw people in.
Plain bites butted together "isn't very exciting": "The whole point of the
montage open is supposed to have like text on the screen and you know it
kind of cuts quickly with sound effects and music and all that kind of
stuff" (Ian video, 2026-10-21). The full build is in
`convex-videos/ian-whiteboard-sept-2026/cold-open.md`.

- **Build it last,** once the rest of the video is right: "leave that
  montage until the end... focus on just getting the video right first".
- **About 30 s, six to eight bites,** alternating speakers and angles.
  The model is the editor-made open of the earlier Ian video, "What is the
  Convex WorkPool?" (youtube.com/watch?v=DQZCQ-Y1ZBM): "picked out the
  really spicy, interesting parts... quick cuts and added text over the
  top". The Ian open ran 36 s with seven bites, and he kept them all.
- **Pick the spicy bites, each a finished thought.** Place and
  listen-check every bite edge as in "How Mike likes a take cut": the last
  cut-off Mike heard on the Ian video was the end of a bite.
- **Room between bites:** 0.3 to 0.5 s of real room tone at every join.
  Butting bites about 0.1 s apart made the lines run together. Widen each
  bite into its own pauses, and where a take has none, run the picture on
  silently for 0.2 to 0.3 s.
- **A reaction beat after each punchline:** 0.5 to 0.8 s of the listener
  reacting silently (taken from while they listen), so the text can be
  read before the next bite.
- **A push with a swoosh between bites,** 0.5 s, so they read as separate
  moments: "you have like a sound effect or a swipe... to indicate that
  it's a different topic... Otherwise, you're kind of almost faking what
  the video is about" (2026-10-22). Not a coloured swipe graphic: "just do
  like a push and the kind of swipe sound". Where the shots either side
  sit on different video tracks (close-up over wide), change one angle so
  the push stays on one track.
- **Kinetic text of each punchline, in their exact words,** in Convex
  colours with the highlighter look: white bold text with a soft shadow,
  the punchline on a rough yellow felt-tip swipe (red for the "wrong"
  lines). No solid boxes behind it: he disliked dark boxes and the VS Code
  palette ("use the convex colours"). Show him a few looks as stills over
  real frames. The text has no exit fade: a matching push on Graphics
  carries it off with the picture. `motion-graphics` has the build.
- **Dramatic music:** "dramatic is best for an opening montage like this
  to make it sound exciting". Generate three or four beds and show each as
  a preview MP4 with the montage, fitted so its big moments land on cuts
  (a start offset, or whole bars repeated, with the loop length found by
  self-similarity) and its final hit on the cut into the first line. His
  pick, a dark electronic cue, sat about 8 LU under the voices, far above a
  chapter bed, with a riser into an impact on the last cut.

### A second voice: the Let's Build It announcement (with his son Josh)

A personal video for X and YouTube (October 2026): no Convex branding,
transitions or swipes. Export `youtube1080` for X and `youtube4k` for
YouTube.

- **Lift the quieter voice, not Mike.** Each of Josh's lines gets one gain
  that brings it up to Mike's level (up to +24 dB), ramping in over about
  0.35 s before and out over 0.5 s after, and stopping short of anything
  that isn't Josh (a breath, Mike's next word). Mike stays at one steady
  level: levelling his words up and down was "quite distracting". Where he
  turns from the mic to talk to Josh, lift that whole stretch by one amount
  (+6 dB), and give a phrase that trails off a further 10 dB its own extra
  lift. Keep dips on his loud words small: he took a -9 dB dip on a shouted
  "Cool!" back to about -3.
- **Check each word, not just the line.** A child's word can fade at its
  end inside a lift: the "-tion" of Josh's "question" sat 10 dB under its
  start, so Mike only heard the "Q". Pitch alone mistakes who's talking (a
  120 Hz "Yeah?" was Mike, and Josh's "Dad?" came a second before the line
  it belonged to), so check the picture and where Mike put his comment.
- **Their lines pop up as text, word by word as they say them.** One text
  clip per step holding the words so far, with the left edge fixed so the
  line grows to the right: measure each prefix's width with `tandem frame`
  in a scratch project and set each clip's x. The first step lasts the
  0.25 s pop and later ones at least 0.12 s, so merge words said faster.
  The `words` field only highlights the spoken word, so it can't do this.
  No full word captions on an announcement video: "I don't think people do
  them in announcement videos".
- **iPad recordings show whole,** over a blurred, darkened copy of
  themselves on the track below (scale 1.3, blur 60, exposure -1). Filling
  16:9 crops the app's edges, and he called that cut off.
- **Keep his mic in the corner cutout.** The cutout can drop the desk mic,
  so the screen shows through it. An include repair mask over the mic
  (`video.cutout.repairMasks`, a rounded rectangle in fractions of the
  source frame) fixes every corner clip of the take; check frames across
  them for holes. Slide the corner off when he turns back to stare at the
  camera mid-demo: "a bit weird".
- **A website he names shows as its live homepage,** scrolling slowly in a
  plain browser window (traffic lights, an address bar with the domain)
  over a blurred copy of the page. Playwright captures one frame per scroll
  position and then composes the window at 4K; the recipe is in
  `~/dev/convex/convex-videos/lets-build-it-announcement/.work/screen-build/`.
- **Music goes in before his big watch, on a personal video too.** Let's
  Build It went to export with none, and he noticed afterwards: "we
  haven't got any music in the background". Three ElevenLabs beds by
  section (playful for the intro and demo, warm and curious in the middle,
  heartfelt for the sign-off), all ukulele, acoustic guitar, soft piano,
  brushed drums and warm bass at 95 to 100 BPM, with no bells, glockenspiel
  or marimba under the game's sounds, at -45 LUFS. He passed them first
  time: "musics good".

### Shorts cut from a conference talk: James's Abstract keynote

Two 9:16 shorts from a filmmaker's 1080p multi-camera edit of James Cowling's
talk (October 2026), for the team to see in Slack first. The project,
scripts and the speaker tracker are in
`~/dev/convex/convex-videos/abstract-clips/` (`.work/`).

- **Full-bleed, not framed.** Mike compared a framed layout (hook title
  above a square window of the talk over a blurred copy, captions below)
  with a 9:16 crop on the speaker, and picked full-bleed: "the full bleed is
  probably better". Use `tandem new --portrait` and crop each camera angle
  separately (blade at the filmmaker's cuts). Where the speaker walks, follow
  him with `video.transform.position` keyframes every 0.5 s from a smoothed
  track. Track the upper body only: on the front shot the light wood floor
  pulled a whole-frame track off him. A 1080p wide shot cropped to 9:16 goes
  soft past about 1.35x; the raw camera files would crop better.
- **A film clip or slide inside the talk stays whole,** in a square window
  over a blurred copy. Cropping it to 9:16 split the two actors.
- **The hook title only over the opening shot,** sliding off at the cut to
  the close-up: on full-bleed close-ups it covered the speaker's face. The
  speaker's name ("James Cowling, Convex CTO, at Abstract") stays up longer,
  until the first jump cut (about 7 s), moved up above his head on the
  close-up: Mike asked for it longer. Captions at `--y 0.70`.
- **A pro-filmed edit has no webcam lag.** `tandem new` leaves the 80 ms
  picture delay off takes a camera made (a timecode track, or a make and
  model); if a take still has it, clear it with `tandem sync 0 --media <id>`.
- **A second camera or a separate mic: `tandem sync <files>`,** not a
  script of your own. It lines them up with the camera take by sound, puts
  them in its take and places them in one undo step: the angle on "Angle
  2", off, and the mic on Voice with the camera's own sound muted. Show the
  angle where it helps with `showAngle`; never untick its clips, unlink or
  slip anything by hand.
- **Cutting a speaker's "right?"s:** only where there's a gap after it.
  Where it runs straight into the next word ("economy, right? And..."),
  leave it. The transcript's word times ran about 0.2 s early on this
  footage, so find the edges on a spectrogram, and don't trust the
  transcript view after the cut: it hid "You're" and "That's" that were
  still in the audio. Copy fixed captions across rather than running
  `tandem captions` again, which drops those words.
- **B-roll never freezes.** Holding a 6 s cartoon's last frame for 2.85 s to
  cover a line read as a freeze frame to Mike. Pick a span the clip fits,
  or slow it a touch (0.93x was invisible).

### Shorts cut from his own long video: Muse Wonder (October 2026)

Three 40 to 50 s Shorts of the spiciest moments, to push the long video
while its topic was news. The project is `muse-wonder/Muse Wonder
Shorts.tandem`; `muse-wonder/upload/shorts/` has the exports, the crop spec
and the upload batch.

- **Make them with `tandem short --copy --apply`.** It writes "<Name>
  Short.tandem" beside the long video, laid out and made 1080x1920, so the
  app shows it portrait: "YouTube shorts are always portrait" (Convex 1.47,
  2026-10-16, when a Short made with plain `tandem short` opened landscape).
  The long video's project never changes. Cut the Short down in the copy.
  For a project already laid out with plain `tandem short`, `--copy` keeps
  its placements, and the `adoptFormat` command does the same conversion in
  place.
- **A whole release video as a Short (Convex 1.47):** cut the copy to under
  3:00 by dropping whole sections, not by trimming every item. Re-render each
  screen shot for the phone window (`broll/short/`, 2160x1680, about 36 px
  type, terminal lines wrapped at 47 columns), because a crop of a full-width
  terminal or docs page can't be read. Where the take has a gap (a voice dub),
  fill the camera behind it with a blurred, darkened copy of the shot so the
  top of the frame isn't black.
- **An old Short shown inside a new one goes in the window, small** (Convex
  1.48, 2026-10-26). Full frame, its burned-in captions sat right under the
  new ones: "you have the transcription on the screen showing both of them
  at the same time, which is confusing". Put it in the top window as a card
  (scale 0.42 at y 0.21875 over a blurred copy cropped to the window), with
  the camera in the bottom half, so it reads as the old video playing.
- **A question he asks the viewer types out on screen as he says it**, in
  his exact words with the typing sound, below his face, sliding off as he
  moves on (1.48: "pop up the question on the screen here as I say it").
  In the Short, turn the captions off under it so the words aren't shown
  twice.
- **Check the music is audible before exporting.** Beds added with
  `tandem assets use` and then `normalizeTo: -45` came back with `gain -31 dB`
  as well (1.48), so the first export had no music. `tandem loudness --tracks
  Music` over a stretch should read about -45 LUFS.
- **Pick moments that stand on their own:** a strong claim with its number,
  a rant, a "this broke" moment. Start about 0.1 s before the first word and
  end in the pause after a finished thought, checked with `tandem pauses`.
- **Every Short stands alone.** Mike turned down a 43 s tip from the Tandem
  video: "it's missing a lot of context around what tandem is. Also, it
  kind of refers back to the video, but people have not watched... you've
  got to really think about them as standalone things... or you've got to
  insert the extra context" (2026-10-20). Read every line as a stranger:
  cut or fix anything that points at the long video ("as you're seeing
  here", "the process I go through", "like I said", "so yeah, that's X",
  "can you get hold of it") or assumes they know the product, and put the
  missing context in the hook title or an on-screen line. A "what is X"
  Short is often the obvious first one to make.
- **Keep the caveats.** Cutting "S tier or Haiku tier" straight after
  "Haiku costs like 40 times less" left out "it's kind of an unfair test"
  and "we weren't running the full model". Mike asked for them back so the
  clip stays fair to what it's knocking.
- **It's watched on a phone held in a hand.** The first cut put each 16:9
  shot whole in the top half and his chest below: "it's quite difficult to
  see the very small text... think about the viewer holding the mobile
  phone". What worked: his face full-frame on top (scripted takes are
  full-frame camera in portrait), word captions just under his chin
  (`tandem captions --y 0.505`), and each shot in a window below, cropped to
  only what he's talking about at that moment. Use
  `~/dev/convex/convex-videos/tools/shorts/portrait_crops.py`: give it each
  clip's region of interest and it writes the portrait crops. Code is
  re-rendered for the Short (a 1000 px window at 36 px, soft-wrapped,
  cropped to the window), and a table keeps only the columns he names, cut
  side by side. Look at every shot at about 540 px wide before showing him.
- **Re-render web B-roll for the window, don't crop it.** Cropping the 16:9
  page captures into the window cut lines off mid-sentence: "the B-roll is
  clipped, it gets cut off" (Tandem Shorts, 2026-10-20). Re-capture each
  page at 2160x1680 in a narrow browser window (380 to 640 CSS px wide, so
  body text lands at about 37 px on the phone), keeping the same pens at the
  same times, and place it full width at y 0.74, scale 1. The renderer is
  `tandem/.work/screen-build/short5.mjs`; `portrait_crops.py` is only for
  footage that can't be re-captured.
- **Platform UI owns the bottom, so B-roll goes on top (Tandem Shorts,
  2026-10-20).** Mike: "on platforms like TikTok or YouTube Shorts, they
  have all the UI down the bottom... the thing that you should be focusing
  on at any time [should be] at the top." This replaces the face-on-top,
  window-below layout above. With no B-roll he's full-frame; while a shot
  shows, it sits in a 2160x1680 window flush with the top (position y
  0.21875, scale 1) and the camera under it drops to the bottom half (scale
  2.4, y 0.80, blade the camera at each B-roll edge). Captions at y 0.47,
  between the window and his cap; hook titles and on-screen tips at y 0.62,
  never in the bottom quarter, where the title, channel and buttons sit.
- **Centre his face, not the frame.** He sits left of centre in the 16:9
  shot (nose about 39.5% across in the studio camera, 41% in Record It
  takes), and the 9:16 full-frame crop shows only a third of the width, so
  `tandem short` left his face at the left edge ("why is my face not centre
  on these shorts?"). Set each full-frame camera clip's position x to
  0.5 + (0.5 - faceX) x scale: 0.832 and 0.784 at scale 3.16.
- **Lay one music bed under each Short.** The long video's music track is
  locked, so it doesn't follow the cuts that stitch a Short together, and a
  section card's +14 dB swell landed mid-Short: "The music gets turned up
  loud in the middle of it for some reason" (What is Tandem, 2026-10-20).
  Unlock, remove the beds under the Short, place one bed for its length at
  -45 LUFS with a 0.8 s fade in and 2 s fade out and no keyframes, lock it
  again.
- **Fix the captions' words.** They come from the transcript, so they carry
  its mishearings: "comics" for Convex, "messages" for Meta's, "evils" for
  evals, "roots" for routes, "sinking" for thinking, "news models" for Muse
  models, "M dashes". Patch each caption's `text` and `words` before export.
- **A hook title over the first 2 to 4 s,** in his words ("S tier or Haiku
  tier?"), scaled to about 0.72 so it fits across, sitting over his chest or
  under the window, never over his face.
- **Export to `exports/`.** `tandem media --refresh` registers every file in
  the folder as media, and Tandem won't overwrite a file that's project
  media.
- **Schedule them apart:** one public straight away, then one a day at the
  long video's slot, each linking the full video in its description. Upload
  with yt-channel-manager's Shorts batch (plan, preflight, his approval,
  run). Pointing each Short's "Related video" at the long video is a Studio
  step for Mike.

### A model shoot-out with a live demo: Muse Wonder (October 2026)

Scripted intro, test and grading, with a YOLO walkthrough of three
agent-built apps in the middle (camera in the corner over his screen).
His first review round, 16 comments, became these:

- **Name it, show it.** When he names the contenders, a logo tile for each
  appears as he says it ("one with Opus, one with Wonder..."). The same for
  a model he brings in later ("can you put the logo... to show what Sol
  is?"). Logos come from `tandem assets search "<name>" --online --kind logo`.
- **"People are saying" needs more than one person.** Show two or three
  different people's posts, not the same one again: "Don't just keep
  relying on Theo so much. Not on the same tweet." Capture X posts with X's
  own embed, logged out, like the other shots.
- **Small text gets zoomed.** A leaderboard row he talks about is zoomed
  into as its highlight appears (`zoomToRegion` with `at`), not left as a
  full-page still.
- **Stills move.** A 13 s still of a prompt "rather than just being so
  static... scroll this a little bit": a gentle scale (1.1) and slow pan
  down over the shot.
- **Don't show the answer before he gets to it.** Two panes side by side
  gave away Opus's `.take(200)` while he was still on Muse's `.collect()`:
  show only what he's talking about, then cut to the full picture.
- **Show what he means.** "What I'd have preferred is a 200 plus or
  pagination": a mock-up on the real app's page, labelled as a mock-up.
- **A clip that doesn't fill 16:9** (a 1.44:1 game capture) gets a backdrop
  behind it: "you can see the sides of the video behind". Black was his
  ask; iPad recordings keep the blurred copy.
- **The real thing, labelled.** While he describes how the real product
  should work, show the real product briefly with a small "The real Let's
  Build It" label.
- **A divider before the conclusion.** A section card ("The verdict")
  before "so should I be using it day to day?", not just the music change.
- **A slip he notices gets a light on-screen nod** rather than a re-record:
  he said "Wonderful" for Muse Wonder and asked for a "(Wonder Full?)"
  callout.
- **A "Mike from the future" pickup** goes where its topic is on screen, as
  full-screen camera (no corner) with a "Mike from the future" title in the
  lower third, B-roll of each thing as he names it, and the demo's music
  bed paused under it (a calmer bed plays, then the demo bed resumes where
  it left off). Shots of the apps came from the running apps with made-up
  test accounts, so no real email is on screen.
- **Blur password-manager popups.** 1Password's "Save login?" showed other
  people's saved logins in his screen recording. Find them by scanning the
  recording's frames for the popup's region (mean brightness catches the
  fade in and out; a dark-pixel count missed about 0.1 s each side) and put
  a cropped, blurred copy of the screen on B-roll over each stretch.

### A quick personal live demo for X: the pool model (October 2026)

A 3-minute one-take demo of his 3D pool model in the browser
(`convex-videos/pool-project/`), cut, B-rolled and exported in one sitting.
What he changed, in the order he asked:

- **Corner for the whole thing.** Opening on his face full screen and going
  to the corner for the demo wasn't what he wanted: "make it picture in
  picture for the entire thing". When the screen is the subject from the
  first line, he's in the corner throughout.
- **Bottom-right, but out of the way of the UI he clicks.** He tried
  bottom-left (mirrored, since Tandem has no flip: a `hflip` copy with
  `-copyts`, then `tandem sync 0 --media` on it) and went back to the right:
  "when I click stuff on the right hand sidebar can you just hide me for a
  second or move me out of the way". Find the clicks from the recording
  (frame differences in the sidebar's region), not the transcript; skip
  plain mouse travel. Slide him off to the right over 0.45 s
  (`video.transform.position` keyframes on every camera clip in the
  stretch, easeIn out, easeOut back) and merge stretches less than about 2 s
  apart so he doesn't pop in and out.
- **No corner over B-roll.** Him in the corner over full-screen B-roll "just
  looks weird". Slide him off for B-roll the same way, and move the Camera
  track above B-roll (`moveTrack`) so the slide shows.
- **Phone footage goes in a phone, not full screen.** "Put the footage in a
  mobile phone, have it sliding in from the side... not complete takeover
  the screen". A landscape phone frame PNG (transparent screen, dynamic
  island, soft shadow) on Graphics over the clip on B-roll, the clip scaled
  and cropped to the screen hole, both sliding in from the right with the
  same position keyframes and out to the left, over the screen recording.
- **Show each source as he lists it.** "Phone video... satellite... drone
  photos... surveying... 2D drawing" got a shot each, from his project
  archive (`~/dev/me/the-pool`). Crop plans and surveys to the drawing:
  their title blocks carry his address and the designer's phone and email.

### A phone app demo as a portrait Short: Walkies (October 2026)

A webcam take of Mike talking through his iPhone app, plus the phone's own
screen recording, made into a sub-3:00 YouTube Short
(`convex-videos/walkies/`). He asked for portrait himself ("should we do
this as a portrait video?... under the 3 mins").

- **Sync by eye when the phone has no voice.** An iOS screen recording
  carries only app sounds, so `tandem sync` scored 14 and refused. The
  file names (Record It's camera start and iOS's
  `ScreenRecording_<date> <time>`) gave the offset to the second, and a
  named moment confirmed it (the Woodhenge pin zoomed in as he said
  "Woodhenge"). Put the phone file in the camera's take with
  `updateMedia` (`takeID`, `takeOffset` = seconds into the take it
  started), then `placeMedia` both. With an explicit `sourceStart`,
  placeMedia gave both files the same media time and ignored the phone's
  offset (mikecann/tandem#63): check the screen clip's source range after.
- **Layout he passed:** the phone recording full height with a blurred,
  darkened copy behind it filling the sides; Mike in a rounded face-cam
  box (cutout off, cropped to his face, white border, shadow) bottom-left
  above YouTube's title area. The cutout corner looked like a floating
  torso in portrait. Slide the box off over pages it would cover (the shop
  list) and back after. Where the phone just sits on a still map while he
  talks, go full-frame on his face.
- **Cut talk before features.** To get under 3:00 I cut the shell shop,
  and Mike stopped the upload: "you didn't actually show the shop... cut
  down a little bit of the talk at the end of the chef stuff... so we can
  get some of the other features that the app has got in there". In a
  demo Short, what the app can do on screen beats him talking over a
  still screen.
- **Hide notification banners** (Gmail and X pop-ups mid-recording) with
  a `freezeFrame` copy of a clean frame, cropped to the top strip, on
  B-roll, where the picture under the banner is still. `tandem check`
  hung on a 9 s one (mikecann/tandem#62); check that stretch with
  `tandem frames` instead.
- **Run `tandem check` with the app holding the project.** Headless it
  hung or lost the connection; through the app it took seconds.

### A two-person whiteboard interview: Ian Macartney on time in Convex (October 2026)

Mike interviews Ian, a Convex engineer, at a whiteboard (37:45, about 10
review rounds, `convex-videos/ian-whiteboard-sept-2026/`): a wide camera of
both, a close-up of Ian, and a mic on Ian that picks up both voices. Its
cut-offs are in "How Mike likes a take cut", its cold open above.

- **Name the angles,** and change angle on a cut: C, Ian's close-up (the
  close-up track on over the wide); W, the wide; W2, a slightly tighter
  wide (`zoomToRegion` {x 0.065, y 0.04, w 0.87, h 0.87}); P, Ian's
  punch-in from the wide ({0, 0, 0.714, 0.714}); M, Mike's single from the
  wide ({0.375, 0.17, 0.625, 0.625}). Change angle at each jump cut that
  isn't under B-roll.
- **No slow zooms.** "Is it you that's moving the camera around here?
  Because it's kind of disorientating a little bit", and "I don't think
  it's appropriate necessarily for this video" (2026-10-21). All 77
  animated close-up pushes came out. Steady framings only.
- **Show whoever's talking:** "While I'm talking you should show me on
  screen, or at least zoom out to the wide angle." On one shared mic
  neither level nor pitch tells them apart, so label the turns from the
  transcript and check the uncertain ones against frames. M for Mike's
  short turns; for long ones alternate W and W2, because he often points
  at the board, or Ian is writing on it.
- **Hide the camera operator's moves** (reframes, focus pulls) with the
  other angle.
- **Fill a mic dropout from a camera's mic.** Ian's mic dropped out for
  11.6 s. The wide camera's sound covered it, EQ'd with ffmpeg's
  `firequalizer` to the mic's long-term spectrum and raised 36 dB. Check
  the gap's loudness after: it first went in at -60 LUFS.
- **People mentioned get a photo and a lower third,** found from their
  company's pages (Emma from the Convex About page). A nickname earns a
  gag: Ian as "the GOAT" got a cartoon goat in a circle above his lower
  third, with a bleat.
- **Handwritten section titles,** writing on like a marker on the
  whiteboard over the camera dimmed behind, as sentence-case questions
  ("Is time a lie in Convex?") with no "08 / 10" counter. Mike picked them
  from four looks. `motion-graphics` has the build and the timing.
- **Graphics never cover Ian drawing or pointing at the board,** and draw
  things the way he drew them (also in `motion-graphics`).
- **A review copy for the guest:** `tandem export --preset youtube1080`
  (5.7 GB for 37 minutes, about 10 minutes), put in the Convex Dropbox
  with rclone on Bruce, since the laptop has no Dropbox app. scp it to
  `bruce:/Volumes/CannMedia/ConvexFootage/exports/`, `rclone copyto` it
  into `dropbox:/Convex Workspace/Video/Sept-office-interviews/3. Exports/`
  under a name that says it's an edit (the raw interview exports live
  there too), check the size with `rclone lsf --format sp`, make the link
  with `rclone link "<path>"`, and delete the staging copy on Bruce.

## Rules

- Insert at a cut's exact time, read from the clips (`start + duration`),
  not added up from file lengths. Tandem puts an insert within half a frame
  of a cut on the cut, but further in it splits the clip: a take placed as
  long as its camera file (282.045 s), not its screen file (282.1 s), so an
  insert at the sum left a 55 ms sliver of the next clip (the Tandem
  video). Read the warnings: placing a take says which file set its
  length, and an insert that leaves a piece under a quarter second says
  where the clip really starts.
- Build ffmpeg input lists explicitly. In zsh an unquoted `$LIST` isn't
  split, so `-i $f` swallowed the whole list and ffmpeg took the other
  names as outputs and overwrote five B-roll stills with `-y`.
- Tandem's media times are the file's own timestamps, but `ffmpeg -ss`
  counts from the file's start. Add the stream's `start_time` (ffprobe)
  when you analyse a source with ffmpeg: Record It's camera files start at
  0.1 s and its screen files at 0.33 s, enough to clip a word.
- Change the project only through `tandem` (apply, undo, and tools run
  with `--apply`). Never edit `.tandem` files or anything in a `.tandem/`
  folder by hand or with scripts.
- Never run `open tandem://...` or `tandem url`, and never install, quit
  or restart the Tandem app, or launch it for anything except opening the
  project at hand-back. While it restarts, commands wait for it (up to 90 s).
- Mike may be editing at the same time: keep batches small, label them, and
  always pass `--expect`.
- Undo only your own edits: `tandem undo --expect <revision>`, and
  `--count N` to undo several in one go (each undo is a new revision).
- Use what Tandem does natively instead of workarounds:
  - `holdEdges` on a clip to hold its first or last frame, never a still
    exported from it (stills go stale and flicker);
  - `addTransition` for transitions (push, slide, cut slide and wipe bring
    their swoosh);
  - `tandem cards` for section cards;
  - `zoomToRegion` for zooms, keeping 1080p shots at or under 150% on a 4K
    frame;
  - `placeMedia` with `anchor` (or `tandem assets use --anchor`) for
    stickers;
  - `tandem segments` for Mike's saved intro, outro and like-and-subscribe
    pieces;
  - `tandem join` (a dry run, then `--apply`) to make clips that play the
    file straight through one clip again, after putting a cut back, never a
    lift and trim by hand.
- New files you make (B-roll, sound effects, stills) go in the video
  folder, then `tandem media --refresh` adds them. Temporary files
  (ProRes masters before converting to HEVC with alpha, test renders) go
  in `$TMPDIR` or the scratchpad, never the video folder: Tandem adds
  anything that appears there, and deleting 10 converted intermediates on
  the Ian video gave Mike a "10 media files are missing" dialog. If one
  gets registered anyway, `removeMedia` it before deleting the file.
- Find music, sound effects, stickers and icons with `tandem assets search`
  and add them with `tandem assets use <id> --at <time>`. Mike's shared
  library is `~/Movies/Tandem Library`.
- To export, `tandem export` writes the finished video (4K for a 4K frame)
  into `exports/`.
