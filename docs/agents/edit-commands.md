# Edit commands: what help doesn't say

The batch format, a one-line index of every edit command, and the semantics and gotchas that `tandem help <command>` and the schema don't carry: levels, sticker placement, keyframe values, how gain keyframes combine with clip gain, transitions and their sounds, section cards, templates and joins.

For a command's arguments, their types, defaults and an example that
works, run `tandem help <command>` (like `tandem help addTransition`).
`tandem schema` prints the whole JSON schema, and `tandem effects` lists the
effects with their parameters, the transitions with their default lengths,
the layouts and the animatable parameters.

## Batches and patches

A batch looks like this; `commands` is required and the rest is optional:

```json
{"label": "Tighten the intro", "author": "claude", "expectedRevision": 41, "idempotencyKey": "intro-tighten-1",
 "commands": [
   {"rippleDeleteRange": {"range": {"start": 12.4, "duration": 0.8}}},
   {"blade": {"at": 30}}
 ]}
```

`tandem apply` also takes a bare list of commands, or a single command, and
the JSON can be quoted as the argument itself: `tandem apply '{"blade":
{"at": 12.5}}'`. Patches (`updateClip`, `updateTrack`...) are JSON merge
patches: send only the fields to change, nested objects merge, and `null`
removes a field. A range is always an object under its own key (`"range":
{"start": 12.4, "end": 13.2}`), never `start` and `end` on the command.

## Every command

| Group | Command | What it does |
| --- | --- | --- |
| Project | `updateProject` | name or metadata |
| | `updateSettings` | canvas, frame rate, loudness target, speech level, alternate formats ([below](#updatesettings)) |
| Tracks | `addTrack` | a video or audio track |
| | `removeTrack` | a track and everything on it |
| | `moveTrack` | a track's position among its kind |
| | `updateTrack` | name, mute, solo, lock, hidden, targeted, ripple mode |
| Media | `addMedia` | a file into the project, not the timeline (`tandem media --refresh` usually does it) |
| | `updateMedia` | a file's role, colour look, picture delay, or another file in its place ([below](#updatemedia)) |
| | `removeMedia` | a file nothing uses |
| Placing | `placeMedia` | files on their role's tracks, the way a drag in does ([below](#placemedia)) |
| | `insertClip` | one clip: a title, solid, graphic, adjustment layer or part of a file ([below](#insertclip)) |
| | `insertTemplate` | a template or saved segment as linked clips ([below](#inserttemplate)) |
| | `addSectionCards` | a numbered card at every section marker ([below](#addsectioncards)) |
| | `fitSectionCards` | cards as long as their words need ([below](#fitsectioncards)) |
| | `placeSynced` | a file synced by sound (another angle, an external mic) beside the take ([recipe](cutting.md#add-another-angle-or-an-external-mic)) |
| Removing | `removeClips` | lift, or ripple delete with `ripple` ([below](#removeclips)) |
| | `rippleDeleteRange` | cut a stretch of time from the take |
| | `cutRanges` | cut many stretches, all in the times you read |
| | `closeGap` | close the gap on a track at a time |
| | `insertTime` | open up empty time ([below](#inserttime)) |
| Cutting | `blade` | cut clips at a time ([below](#blade)) |
| | `join` | join one through-edit ([below](#join)) |
| | `joinThroughEdits` | join every through-edit in a range |
| | `trim` | move a clip edge, optionally rippling |
| | `roll` | move the cut between two clips |
| | `slip` | change which part of the file a clip plays |
| | `slide` | move a clip between its neighbours |
| | `holdFrame` | hold the frame before a flash over it, picture only (`check` gives these for flickers) |
| | `setSpeed` | change speed, keeping the media |
| Clips | `moveClips` | move in time or to another track |
| | `updateClip` | any clip setting ([below](#updateclip)) |
| | `link`, `unlink` | link group membership |
| | `showAngle` | which angle of a synced take shows over a range ([recipe](cutting.md#add-another-angle-or-an-external-mic)) |
| | `applyLayout` | full, PiP, split or fill ([below](#applylayout-zoomtoregion-addmotion)) |
| | `zoomToRegion` | zoom into a rectangle of the source |
| | `addMotion` | Ken Burns zoom or pan for stills |
| | `setFormatLayout` | placement in an alternate format like the 9:16 short |
| | `adoptFormat` | make an alternate format the canvas |
| Transitions | `addTransition` | a transition, optionally with a sound ([below](#transitions)) |
| | `updateTransition` | type, direction, length, sound |
| | `removeTransition` | a transition and its sound |
| Effects | `addEffect` | an effect on a clip's video or audio |
| | `updateEffect` | an effect's params or `enabled` |
| | `removeEffect` | an effect and its animations |
| | `moveEffect` | an effect's place in the list (effects apply in order) |
| | `setKeyframes` | animate one parameter ([below](#keyframes)) |
| Sound | `normalizeSpeech` | every speech clip to the speech level ([below](#normalizespeech)) |
| Markers | `addMarker` | a marker, section, chapter, to-do or comment ([below](#markers)) |
| | `updateMarker`, `removeMarker` | change or remove one |

Wherever a command takes a track, a name works as well as an ID
(see [Tracks](../AGENTS.md#tracks)).

## updateSettings

The speech level (`speechLoudness`) goes from -40 to -10 LUFS. Changing it
moves every clip normalised to the old level to the new one; clips with a
level of their own keep it. Every export preset masters to
`loudnessTarget` with true peaks under `truePeakCeiling`.
`alternateFormats` is where extra outputs like the 9:16 short (`portrait`)
live; `tandem short` adds it.

## updateMedia

A new `path` is another file in the item's place: every clip stays where
it is and plays the new file. Without a `fingerprint` in the same patch,
Tandem drops the old one, so loudness, transcript, waveform, isolated voice
and separated stems are made again from the new file, and the next folder
scan re-probes it. It also adds the old path to `replaces`, which keeps
scans from adding that file back as new media. Media a scan already added
for the new path goes in the same step, unless a clip plays it.
`tandem media replace <id> <file>` does this with a length check; use it
for a processed copy ([recipe](sound.md#swap-in-a-processed-copy-of-a-file)).

## placeMedia

Each file goes to the track for its role (camera to Camera, screen to
Screen, B-roll to B-roll, music to Music), a camera file's sound goes to
Voice as a linked clip, and the files of one take are placed in sync and
linked. A sound effect placed where SFX is taken goes on SFX 2 (or the next
free SFX track, made when there's none) instead of failing, unless you name
the track with `audioTrackID`. B-roll is silent unless you pass
`"includeAudio": true`.

A take is placed as long as its shortest file runs (from `sourceStart`),
with a warning saying which file that was when they differ, so work the
next edit out from where the clips end, not from the longer file's length.
`speed` places it faster or slower in one go, sound and all, the way
`setSpeed` would; with `duration` too, `duration` is the length on the
timeline, so 9.6 s of B-roll at 1.5x fills a 6.4 s gap:

```json
{"placeMedia": {"mediaIDs": ["med_broll"], "at": 312.4, "duration": 6.4, "speed": 1.5}}
```

Sound gets Mike's levels: speech (a camera's sound, files with no clearer
role such as a rendered intro, and anything placed on a take track like
Voice) is normalised to the project's speech level with no gain, music gets
-31 dB with a 2 s fade out, and sound effects -15 dB.

Stickers don't fill the frame. They sit at the bottom centre, at most 40%
of the frame's width and 30% of its height (never more than twice their own
pixels), 5% of the height in from the edge. `anchor` puts one somewhere
else, or anchors any other picture (a logo, an image) the same way;
`lowerThird` is bottom left, inside the title-safe area. `pop` adds scale
keyframes that pop it in over the first quarter second and out over the
last.

```json
{"placeMedia": {"mediaIDs": ["med_comment"], "at": 371.2, "anchor": "bottomRight", "pop": true}}
```

## insertClip

`content` is one of `{"media": {"mediaID": ...}}`, `{"text": {...}}`,
`{"graphic": {"template": ..., "props": {...}}}`, `{"solid": {"color":
{...}}}` or `{"adjustment": {}}`. `{"graphic": {"template":
"sectionCard"}}` is Mike's section card, drawn by Tandem
([Add a section card](broll-and-titles.md#add-a-section-card) has its
props); other graphic templates aren't rendered yet. Titles are in
[Add a title](broll-and-titles.md#add-a-title).

## insertTemplate

Templates come from packs as JSON. Media a template uses is matched by path
(`mediaPath`); a clip that carries its media item under `media` adds it when
the project has nothing at that path yet, and reuses what's there
otherwise. Saved segments carry theirs, which is how `tandem segments
insert` works, and so does the Section card tile for its whooshes; without
one, the file must already be in the project. `{{field}}` placeholders are
filled in text clips and in a graphic's text props. `transitions` joins its
clips by their place in `clips` (`{"from": 0, "to": 1, "type":
"dissolve"}`, or only `to` for a fade in at a clip's head).

A clip that carries its file:

```json
{"insertTemplate": {"template": {"id": "segment:Sting", "name": "Sting", "duration": 1.2, "clips": [{"track": "SFX", "trackKind": "audio", "clip": {"duration": 1.2, "audio": {"gainDB": -15}}, "mediaPath": "/Users/m5-mike/Movies/Tandem Library/Segments/Sting/sting.wav", "media": {"path": "sting.wav", "kind": "audio", "role": "sfx", "duration": 1.2, "hasAudio": true}}]}, "at": 42, "mode": "overwrite"}}
```

## addSectionCards

A section marker at the very start (0:00) is the cold open, which gets no
card. Each card starts just early enough to hide the whole frame from its
marker on, so the cut between sections is never seen. A section card
already over a marker is renumbered (and gets `kicker` if you pass one) but
keeps its own words, colours, length and sounds, so run it again after
adding a section.

With `mode: insert` the card is a pause and its wipes show the last shot of
one section and the first of the next. `soundIn` and `soundOut` go on SFX
(or SFX 2... where SFX is taken), linked to their card. `tandem cards`
fills them in with the section card whooshes from the asset library,
levelled for the project's speech.

With `insert` the take is cut for each card's room at its marker, unless
`cuts` says where instead, by marker ID: within 0.3 s of the marker (less
for a card under 1.76 s), so the card still covers it. Put a cut in the
pause before the section's first word, never on the word: room made right
on a word's start leaves its first sound before the card and the rest after
it. The card hides the frame from its cut on, and the marker moves with
what it was on. `tandem cards --insert` works the cuts out from the voice.

```json
{"addSectionCards": {"markerIDs": ["mk_daytona"], "mode": "insert", "cuts": {"mk_daytona": "15:03.233"}}}
```

## fitSectionCards

Use it after changing a card's words, clearing its kicker, or on cards made
before the lengths grew (they used to be 3.2 s). A longer card covers a
little more of the section it opens, since nothing ripples.

## removeClips

With `ripple` on the take (a cut track), every track ripples, as a ripple
delete does.

## insertTime

Cut tracks are split at `at` and everything from there moves later. On
follow tracks only clips starting at or after `at` move: a clip spanning it
(a music bed, a B-roll shot) stays where it is, isn't cut, and keeps playing
across the new time, ending where it did. Off tracks and locked tracks
don't move (a locked one warns). Time opened right on a cut parts its two
clips, so a transition between them goes, with a warning. `trackIDs` names
the tracks to split and open up instead of the cut tracks; when none of
them is a cut track, nothing else moves.

Markers after `at` move. A marker right at `at` stays there, at the start
of the new time, because what goes in usually belongs to the section that
starts there; a ripple delete leaves a marker at the start of what it
removes for the same reason. Inserting with `placeMedia`, `insertClip` or
`insertTemplate` (`"mode": "insert"`) works the same way. Edits that grow a
clip at its end (a ripple trim, `setSpeed` slower with `ripple`) still take
a marker at that end along with the clip after it, and a section card's
room (`addSectionCards` with `insert`) moves its marker on with the section.

An `at` within half a frame of a clip's start or end on a track it splits
goes on that cut, so a time read to the millisecond doesn't leave a sliver.
Further inside a clip it splits where you said, and a piece under a quarter
second either side of the insert gets a warning with the clip's own start
or end to use instead.

## blade

With `clipIDs`, a clip already cut earlier in the batch is followed to the
piece of it at `at` (a cut keeps the left piece's ID and gives the right
one a new one), so blading one clip at several times works in any order.
A clip with nothing at `at` fails, saying where it is; one ending or
starting exactly at `at` is already cut there, which only warns.

## join

It only joins when one clip plays exactly what the two did. Effects that
differ only by ID count as the same settings. Keyframes keep their timeline
times. The clips linked across the same cut each have to meet the cut and
join, or nothing does. One clip's animation only joins when it sits still,
at the other clip's value, all through the other clip. A locked track
fails it too. `tandem join` lists what it would join and why it leaves the
rest ([Join through-edits](cutting.md#join-through-edits)).

## updateClip

The patch can change any clip field: `video.transform` (position, scale,
rotation), `video.crop`, `video.opacity`, `video.cutout`, `audio.gainDB`,
`audio.fadeIn`, `audio.fadeOut`, `audio.normalizeTo`,
`audio.voiceIsolation` (0 original to 1 fully isolated),
`audio.separation` (SAM Audio stems at their own levels, made by
`tandem separate`; [sound.md](sound.md#separate-a-sound-with-sam-audio)), a title's
`content.text`, a graphic's `content.graphic.props`, `enabled`, `name`,
`tags`... `tandem schema` has every field of `VideoProperties` and
`AudioProperties`.

`audio.normalizeTo` levels the clip from its file's measured loudness (the
target minus the measurement, at most 30 dB either way) and `audio.gainDB`
is added after it: normalised to -20 LUFS with `gainDB` 2, a clip plays at
about -18. `null` stops normalising. A gain of -96 dB or lower is silence.

`video.crop` values are fractions (0 to 1) of the source hidden at each
edge, so `{"left": 0.25}` hides the left quarter of the picture.
`video.transform.position` is in canvas units, (0, 0) top left to (1, 1)
bottom right, and `scale` 1 fits the canvas (Mike's PiP is 0.5).

`holdEdges` lets a clip run past the ends of its file: its first frame
holds before the file starts (a negative `sourceStart`) and its last frame
after it ends, with no sound there. Use it when a shot is a little short
for its line, or to hold a shot under a section card, instead of placing a
still of its last frame. A still goes stale when the shot is regenerated;
the clip's own frame can't. Set it, then trim the edge out, in one batch:

```json
{"label": "Hold the rail shot to the end of the line", "commands": [
  {"updateClip": {"clipID": "clip_k3f9x2mq", "patch": {"holdEdges": true}}},
  {"trim": {"clipID": "clip_k3f9x2mq", "edge": "end", "to": 81.9}}
]}
```

`tandem timeline` shows how long it holds. To turn it off, trim the clip
back inside its file first.

## applyLayout, zoomToRegion, addMotion

- `pipRight` is Mike's usual PiP: 50% with the cutout and Filmora's drop
  shadow, bottom right. `split` puts the camera on the right half and
  everything else on the left.
- `zoomToRegion`'s `rect` is a part of the source, 0 to 1 from its top
  left.
- `addMotion` pans travel across whatever part of the photo overflows the
  frame.
- `setFormatLayout` fills its slot edge to edge with the sides cropped; a
  short usually shows the camera with its background (`cutout: false`).
  `adoptFormat` takes the format out of `alternateFormats` once it's the
  canvas, and scales scale-only keyframes because keyframes are absolute.

## Transitions

A transition joins two touching clips on one track, or sits at one clip's
head or tail. `direction` is for push, slide and wipe. A transition between
two clips is centred on the cut, so each clip plays half its length past
the cut. Where a clip has no frames there (its file used to the last frame,
or from the first) that edge frame holds for the rest, as in Premiere and
Filmora, and the edit's warnings say how long; trim the clip for real
motion instead. On its own at an overlay's tail (`fromClipID` only), a push
or slide moves the overlay off screen and the tracks below show where it
was, as in Filmora (a B-roll pushed out upwards, leaving Mike playing
below); at a head (`toClipID` only) it comes in. On audio tracks every
transition is a crossfade, and sound past a file's ends is silence. Default
lengths are Mike's usual ones from Filmora (`tandem effects` lists them:
push and slide 0.7 s, cut slide 0.57 s, wipe 0.6 s, dissolve and zoom
0.5 s, the fades 1.1 s).

A transition can carry a sound effect: an ordinary clip on SFX (the first
free SFX track), so Mike sees it and can nudge, trim or turn it down, tied
to the transition by its `soundClipID`. `addTransition` returns the
transition's ID, then the sound clip's. The sound keeps its distance from
the transition's middle (the cut, for one between two clips, where a push
or wipe moves fastest), so a swoosh stays on the cut whatever the length:
rolling the cut, rippling the take or moving both clips takes it along,
whole, and a fade at a clip's head carries it as it grows. It goes when the
transition goes, whether that's a `removeTransition`, a clip it joins
deleted, the clips moved apart, or an undo. Deleting the sound clip leaves
the transition silent. In the app, push, slide, cut slide and wipe come
with a light swoosh unless Mike picks otherwise (Tandem > Settings);
[Put a swoosh on every push](sound.md#put-a-swoosh-on-every-push) has the
gains and offsets.

`updateTransition`'s `sound` changes only what you send, so a new length or
type keeps the sound where it is against the middle. The sound clip is an
ordinary clip too: `updateClip` and `moveClips` on its ID work, and it
stays tied. `soundClipID` ties a clip that's already on an audio track
instead, like a whoosh someone placed by hand beside the transition; its
old sound, if it had one, stays as a plain clip.

```json
{"updateTransition": {"transitionID": "tr_x", "patch": {"sound": null}}}
```

```json
{"updateTransition": {"transitionID": "tr_x", "patch": {"soundClipID": "clip_whoosh"}}}
```

## Keyframes

`setKeyframes` replaces one parameter's keyframes. Keyframe times are
seconds from the clip's start, and move with the clip. A value is encoded
as the parameter is:

- a number for scale, rotation (degrees clockwise), opacity (0 to 1), each
  crop edge (a fraction, as above), `audio.gainDB` and numeric effect
  parameters;
- `{"x": 0.5, "y": 0.5}` for `video.transform.position`, in canvas units;
- `{"r": 1, "g": 0.8, "b": 0, "a": 1}` for a colour parameter, 0 to 1 per
  channel (`a` defaults to 1);
- a boolean or a string, which hold the first value until the next
  keyframe rather than blend.

A segment eases with the `interpolation` of the keyframe it starts from
(`easeInOut` unless set; `hold` jumps at the next keyframe). Before the
first keyframe the parameter holds the first value, and after the last it
holds the last. A colour wheel's hue blends the short way round (350 to 10
passes through 0). Effect parameters are `video.effects.<effectID>.<param>`
or `audio.effects.<effectID>.<param>`; give the effect an `id` in
`addEffect` to animate it in the same batch.

`audio.gainDB` keyframes take the place of the clip's `audio.gainDB` while
they exist: the clip's own gain is ignored, not added. The `normalizeTo`
levelling still applies underneath, and fades and crossfades multiply on
top. The gain moves in dB between keyframes, sampled about every 50 ms, so
a linear ramp from -31 to -20 dB sounds even. To duck music under a line,
key the bed's gain at its usual level either side and lower in between.

## normalizeSpeech

Speech is a camera's sound, a file with no clearer role, or anything on a
take track like Voice (an audio track whose ripple mode is `cut`, muted or
not). Fades, voice isolation, effects and gain keyframes stay; locked
tracks are left alone with a warning.

It keeps the speech at the speech level even when that lifts a quiet
mic's bumps and shouts over full scale: a clip that plays (it and its
track unmuted) whose file's true peak, plus its levelling, would go over
the project's `truePeakCeiling` gets a compressor (3:1 from 6 dB over the
speech level) and a limiter at the ceiling, at the end of its audio
effects, and the warning names it. A clip with a limiter already, on or
off, is left as it is, so removing or turning one off sticks until you
add it back. Tandem fills in `measured` (each file's loudness and peak)
from its analysis, and the journal keeps it, so leave it out.

## Markers

In the app each kind shows in a strip under the ruler: Markers (markers,
sections, chapters), To-dos and Comments. A `todo` is a note for Mike, like
a shot to record or find; put what's needed in its `note`, which he sees
when he hovers over it. A `comment` is a note Mike left for the next round
(`tandem comments`, and [Do Mike's comments](review-and-history.md#do-mikes-comments)).
A `duration` makes a marker a range. A section marker's name and note are
its card's title and subtitle.
