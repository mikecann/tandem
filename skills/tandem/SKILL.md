---
name: tandem
description: Edit Mike's videos in Tandem, his Mac video editor, through the `tandem` command. Use when a video folder has a .tandem project, or when asked to cut, trim, tighten, place B-roll, add titles, section cards, transitions, captions, stickers, music or sound effects, look at frames, render a review clip, check an edit, do Mike's comments on the timeline, or export a video in Tandem.
---

# Tandem

Tandem is Mike's video editor, built for working in turns with an agent:
you edit the project through the `tandem` command, Mike reviews in the
app, and the timeline shows him exactly what you changed. The full guide,
with an example of every command and recipes for B-roll, titles, cards,
shorts, captions and more, is `docs/AGENTS.md` in the Tandem repo
(`~/dev/me/tandem/docs/AGENTS.md` on Mike's Mac). `tandem help <command>`
gives a command's options. Read the parts you need before editing.

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
   and `tandem search "<phrase>"` find what's said where.
2. **Edit in labelled batches.** `tandem apply '{"label": "B-roll over the
   config file", "commands": [...]}'` makes one undo step, which Mike reads
   by its label. Pass `--expect <revision>` from your last read so you never
   edit over his changes. On a stale revision, read again. Try big batches
   with `--dry-run` first.
3. **Look.** `tandem frame <time> -o frame.png` for a still,
   `tandem clip <start> <end>` for a 720p review MP4. Look at what you
   changed instead of trusting the numbers.
4. **Check.** `tandem check --changed` before you hand back. It renders
   what you changed and finds black frames, flickers, green screen that
   didn't key and white blocks. Fix every problem it reports. Its notes
   are judgement calls, but go through each one:
   - soft zooms;
   - dead air: 0.8 s or more of a still picture with nothing said and no
     sound effect or music swell. Cut it, or keep it only if the pause
     earns it (see "Longer gaps where they earn it");
   - page changes with no transition: the screen recording turns to a new
     page and nothing covers it. Push it if it's a page in an explainer or
     slides (see "Page changes in an explainer or slides"); a demo button
     that redraws the page can show up too.
5. **Hand back.** Open the project in the app for Mike with
   `open "<video folder>/<name>.tandem"` (skip it if `tandem status` says
   the app already has it open), rather than asking him to open it. Then
   tell him in a few lines what you changed and why. Your edits stay
   highlighted on his timeline until he plays through them or marks them
   reviewed; that's his to do.

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

## How Mike likes a take cut

- **Pauses between sentences: 0.4 s.** Tighten with
  `tandem tighten --min 0.5 --keep 0.4`. It's the feel of his old Filmora
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
- **The ending:** run on about 5 s after the sign-off, fade to black, and
  fade the music out with it.
- **Mid-sentence pauses:** close his thinking pauses, 0.5 s or longer,
  right up (to about 0.08 s), so a sentence sounds like one thought. Leave
  shorter ones (a breath, a natural pause) as he said them: closing every
  gap of 0.2 s or more made 818 cuts in a 38-minute video, one every 2.8 s,
  and the picture jumped around (Mike, 2026-10-05). The 0.4 s is for
  between sentences. Leave live demo reactions alone.
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
- **B-roll starts and ends on sentence boundaries:** the take's cuts, or a
  real pause between words. Never 0.2 s off a cut or mid-word. If less than
  about 1.5 s of camera would show between two B-roll shots, join them. A
  quick flash back to the camera looks like a glitch. Use `holdEdges` when a
  shot runs short.
- **Show what he says.** When he names a thing (a dashboard table, a docs
  page, a claim someone made, a price), put the real thing on screen while
  he says it. A highlight (the $200 free credit) appears when he says it,
  not before.
- **Section cards: about 3.2 s.** 4 to 4.8 s felt a touch long, 2 s far too
  short. "A touch shorter" means a modest change, not the number he floats.
  To lengthen or shorten a card, open or close time only in the take's gap
  under it (`insertTime` or `rippleDeleteRange`). The cards wipe over the
  edges of speech. Then stretch the music bed that spans the card, because
  clips that span an inserted point don't grow.
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
  +8 dB after the sign-off. A chill lounge kit sat under demo sound effects
  without fighting them: Rhodes, soft pads, round bass and brushed drums at
  about 85 BPM, with no hi-hats, bells, glockenspiel or marimba.
- **Linked sounds:** a card's whooshes are linked to it, so trim either with
  `"includeLinked": false` or you drag the other along.
- **On-screen text moves in and out.** A question or callout slides in and
  slides off (position keyframes), rather than popping in and vanishing. He
  liked the typewriter reveal with a typing sound.
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
  screen.
- **Screen recordings fill the frame,** for people watching on a phone:
  one static `zoomToRegion` per page, fitted to the content with a small
  margin, at most 1.5x, and no zoom changes within a page.
- **Check cuts against the voice, not the transcript alone.** Word times
  can be off by up to 0.5 s ("since when?" ended half a second after the
  transcript said, and a drawn-out "Aaall... right" started 0.9 s early).
  Most of his "word gets cut off" comments were this. `tandem pauses` has
  the voice's real edges; listen with `tandem clip` when unsure.
- **Before uploading,** watch the start of the export, where sync problems
  show first. The limiter takes about 8 dB off his voice's peaks to reach
  -14 LUFS, and he hears that as artificial, so he asked for -16 after
  Daytona: `updateSettings {"patch": {"loudnessTarget": -16}}`. Set it when
  the edit starts, not at the end: Let's Build It sat at -14 until the
  last round, where the limiter squashed 18 s of it (up to 10 dB off his
  loudest words), and -16 left 4 s. Every export preset masters to the
  project's target and says what it used.

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

## Rules

- Tandem's media times are the file's own timestamps, but `ffmpeg -ss`
  counts from the file's start. Add the stream's `start_time` (ffprobe)
  when you analyse a source with ffmpeg: Record It's camera files start at
  0.1 s and its screen files at 0.33 s, enough to clip a word.
- Change the project only through `tandem` (apply, undo, and tools run
  with `--apply`). Never edit `.tandem` files or anything in a `.tandem/`
  folder by hand or with scripts.
- Never run `open tandem://...`, and never install, quit or restart the
  Tandem app, or launch it for anything except opening the project at
  hand-back. While it restarts, commands wait for it (up to 90 s).
- Mike may be editing at the same time: keep batches small, label them, and
  always pass `--expect`.
- Undo only your own edits: `tandem undo --expect <revision>`.
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
  folder, then `tandem media --refresh` adds them.
- Find music, sound effects, stickers and icons with `tandem assets search`
  and add them with `tandem assets use <id> --at <time>`. Mike's shared
  library is `~/Movies/Tandem Library`.
- To export, `tandem export` writes the finished video (4K for a 4K frame)
  into `exports/`.
