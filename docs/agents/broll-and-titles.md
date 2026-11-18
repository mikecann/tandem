# B-roll, titles and section cards

Recipes for the proof list (what shows each claim Mike makes), putting B-roll over a sentence, adding and restyling titles (presets, animations, style overrides), and Mike's section cards, by marker or by hand.

## Show what he says: the proof list

Mike's one comment on every video is "show what I'm saying": when he names
a product, a person, a price or a number, or makes a claim, the real thing
is on screen as he says it. Reading the transcript for these misses the
lines he ad-libbed, so Tandem lists them. After the take is placed and cut,
and before building B-roll:

```bash
tandem claims
```

It lists every line that names something or makes a claim, with an ID,
its times, the words that made it one and what's on screen over it now,
and writes them to `<name>.claims.json` beside the project:

```
{"id": "c751f13", "at": "00:08.337", "to": "00:12.897",
 "said": "The CLI can now be logged into more than one Comics account at the same time.",
 "because": ["CLI", "Comics", "more than"], "onScreen": "camera only",
 "shot": "", "link": "", "skip": ""}
```

Fill in every claim in that file: `shot` is what will show it (a file or
clip you placed, or a description of what you'll make), `link` the real
page (the docs, the PR, the pricing page, the post), and `skip` why
nothing needs showing ("he's pointing at the screen recording", "his face
for the opening line"). Change nothing else; it's the only Tandem file you
edit by hand, and never anything in `.tandem/`. Run `tandem claims` again:
it reads your answers back, matches them to the lines by their words (so
they survive later cuts, and a cut line's answer waits under `gone`), and
says how many are left. Then write the list for Mike and pin it for him in
Threadbear before building the B-roll:

```bash
tandem claims --markdown claims.md
```

It's each line's time, what he says, and what will show it with its link.
`tandem check` notes a `bareClaim` for every line still said with the
camera full screen and nothing over most of it, unless it has a `skip`.

What counts: a name that isn't a sentence's first word (Bark capitalises
products, companies and people; a word it mostly writes in lower case
isn't one), a number, money, a percentage or a version ("one dot five
zero" too), and phrases that point at something real ("the docs", "this
PR", "pricing", "he says here", "npx", "it's finally here", "non-beta").
A name said again within a minute, and the project name's words after
their first mention, don't count again. On Mike's finished edits it lists
one sentence in five or six.

## Put B-roll over a sentence

Find when the sentence is said, and the B-roll file's media ID:

```bash
tandem search "our servers handle the load"
tandem media
```

Place the shot on the B-roll track for exactly that sentence. `sourceStart`
picks where in the B-roll file to start. B-roll is silent unless you pass
`"includeAudio": true`.

```json
{"label": "B-roll over the servers line", "commands": [
  {"placeMedia": {"mediaIDs": ["med_servers"], "at": 134.32, "duration": 4.5, "sourceStart": 2}}
]}
```

If the B-roll track already has something there, add `"mode": "overwrite"`
or name another track with `"videoTrackID"`. A shot a little short for its
line can hold its last frame (`holdEdges`, in
[edit-commands.md](edit-commands.md#updateclip)).

## Add a title

Insert a text clip on the Text track (by name, or by the ID on the `V5 Text
trk_...` line of `tandem timeline`):

```json
{"label": "Title for tip 1", "commands": [
  {"insertClip": {"trackID": "Text", "clip": {"content": {"text": {"text": "TIP 1", "preset": "callout", "animationIn": "popIn", "animationOut": "fadeOut"}}, "start": 95, "duration": 3}}}
]}
```

Change the words later with
`{"updateClip": {"clipID": "clip_...", "patch": {"content": {"text": {"text": "TIP 2"}}}}}`.

`animationIn` and `animationOut` take `fade`, `pop`, `slideUp` or
`typewriter`, and `animationOut` plays them backwards. `fadeIn`, `fadeOut`,
`popIn` and `popOut` work too. `none` switches off the preset's. Leave them
out for the preset's, and set `animationDuration` (seconds) for how long
each takes. Any other name is turned away, since it would draw nothing.

The presets are `label` (a plain label like VS), `callout` (a punchy boxed
callout like 14 TIPS), `sectionHeader` (a small accent line over a big
title), `version` (a release video's version number) and `caption` (word
by word captions); the schema's `preset` field lists them too.

The preset gives the look. A clip's `style` holds only what it changes
(`font`, `size`, `weight`, `color`, `strokeColor`, `strokeWidth`,
`backgroundColor`, `alignment`, `uppercase`, `shadow`, `lineSpacing`), and
each field that's there wins over the preset, even `false` or `0`. So a URL
on a label stays lower case, and a callout can lose its shadow and outline:

```json
{"label": "Plain end card", "commands": [
  {"updateClip": {"clipID": "clip_url", "patch": {"content": {"text": {"style": {"uppercase": false, "strokeWidth": 0, "shadow": false}}}}}}
]}
```

`null` for a field in a patch takes it back to the preset's. A
`backgroundColor` with `"a": 0` switches off a preset's box, and
`"animationIn": "none"` (or `animationOut`) its animation. `tandem timeline`
lists what each title sets itself (`style uppercase=false shadow=false`).
The app's Text inspector shows the values the title is drawn with, marks the
ones the clip sets itself in amber, and has a button beside each that goes
back to the preset's. Sizes and outline widths are points at 1080p, and a
font can be a family, PostScript name or full name; a font this Mac lacks
is installed with `tandem assets use fontsource:<name>` ([assets.md](assets.md)).

## Add a section card

Mike's section card is one clip, the built-in `sectionCard` graphic, about
three seconds between the cold open, the intro and each section. Convex's
yellow, red and purple bands sweep across to wipe it in; the dark card holds
a number chip, the title (Anton, upper case) with a yellow text cursor
blinking after its last letter, a letter-spaced subtitle and progress bars
(a bar for each section up to six, then one bar in proportion with a count
like `3 / 14`); and the bands sweep across again to wipe it out, showing the
next shot. It's as long as its words need to be read, from 4 s for a short
title and subtitle to 7 s: a longer card holds longer and the wipes stay the
same.

The usual way is a card at every section marker. Mark where each section
starts (`addMarker` with `"kind": "section"`, or a marker's Kind menu in the
app): the marker's name is the card's title and its note, if it has one,
the subtitle. Then:

```bash
tandem cards                              # the plan: numbers, titles, where each card goes
tandem cards --apply                      # just the number in the chip, as Mike likes
tandem frame 0:33 -o /tmp/card.png        # look at one
```

The cards go on Graphics, each starting 0.43 s before its marker so the
card hides the whole frame from the marker on, and each as long as its
words need: 1.4 s for the wipes and 0.8 s to take it in, then the title,
subtitle and kicker read at 15 characters a second (a little slower than
Netflix's 17 for subtitles: Mike found cards at 17 a bit quick), rounded up
to a tenth of a second, at least 4 s and at most 7. `--duration` makes them
all one length. Mike prefers no kicker (`SECTION 1 OF 9` beside the number):
only pass `--kicker` when he asks. The section keeps playing under it
(Mike's voice too). With `--insert` each marker gets room instead: the take
moves on by the card's hold, so the card is a pause and its wipes show the
last shot of one section and the first of the next. A marker at 0:00 marks
the cold open and gets no card. Run `tandem cards` again after adding or
moving a section: cards already at a marker are renumbered and keep their
words. `--kicker Tip` suits a list video. It's one undo step, and in the app
it's Timeline > Add section cards at section markers (Option-M).

`--insert` cuts the take in the pause before each section's first word,
not on it. A marker on the word (where its transcript starts it) or just
before it moves the cut back into the pause, keeping 0.2 s of silence
before the word (half the pause, when the pause is under 0.4 s), on a
frame; one in the second half of a word moves it into the pause after
that word. Word edges come from the voice, as for `pauses`. When that would
leave a sliver of a clip beside the room (a tightened pause, with its cut
in the middle), the cut already in that pause is used. The cut moves at
most 0.3 s, so the card still covers its marker and running `tandem cards`
again finds it. The plan shows `take cut at` for each card whose cut moved,
and warns about each marker that sat on a word, one in the middle of a long
word (no pause near enough, so it's cut there: move the marker) and speech
with no transcript yet (cut right at the marker). A section marked in the
pause before its first word needs no move.

A soft whoosh goes with each sweep: two airy swishes made for the card with
ElevenLabs, kept in the asset library (docs/ASSETS.md). `tandem cards
--apply` copies them into the project's `assets/sfx/` and puts them on SFX,
linked to their card: one as the card starts, one as the out sweep starts,
0.88 s before the end. Their gains (-5.4 and -8.3 dB) put their loudest
moment 15 LU under speech at -20 LUFS, where Mike's own swipes sit; in a
project whose speech plays elsewhere they move with it (an imported edit at
-28.7 gets -14.1 and -17). A Mac whose library doesn't have them makes
silent cards and says so; `--no-sounds` leaves them out. By hand, that's
`addSectionCards` with `soundIn` and `soundOut`:

```json
{"addSectionCards": {"soundIn": {"mediaID": "med_swishin", "gainDB": -5.4, "offset": 0}, "soundOut": {"mediaID": "med_swishout", "gainDB": -8.3}}}
```

One card by hand, anywhere:

```json
{"label": "Section card: Results", "commands": [
  {"insertClip": {"trackID": "trk_graphics", "clip": {"content": {"graphic": {"template": "sectionCard", "props": {"number": "02", "title": "Results", "subtitle": "Finally!", "total": 3}}}, "start": 95, "duration": 4}}}
]}
```

Props: `title`, `subtitle`, `number` (what the chip says; a number is
written `02`), `total` (how many sections, for the progress bars; 0 hides
them), `kicker` (`Section` or `Tip`, shown as `SECTION 2 OF 3` beside the
chip; off by default, and Mike prefers it off), `cursor` (`false` turns off
the cursor after the title; it's on by default), and the colours `accent`
(the first band, the chip, the subtitle, the lit bars and the cursor),
`band2`, `band3` and `background`, as `{"r", "g", "b"}` or a hex string
like `"#F3B01C"`. A missing word leaves that part out; colours default to
Convex's. Change them later with a patch, for example
`{"updateClip": {"clipID": "clip_...", "patch": {"content": {"graphic": {"props": {"subtitle": "Let's keep it fair"}}}}}}`
(`null` removes one). `tandem frame` shows the result. A card added by hand
is as long as you make it. After changing its words, `fitSectionCards` (the
Video tab's Fit to text) sets the length they need, trimming the card's end
and moving its whoosh out with the wipe out; by hand that's a `trim` of its
end and a `moveClips` of the whoosh by the same amount.
