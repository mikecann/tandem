# Cutting the take

Recipes for tightening pauses, taking out fillers, cutting a phrase, a false start or a rough cut pause to pause, joining through-edits back up, keeping the camera's picture in sync with its sound, and adding another camera angle or an external mic.

## Tighten pauses

```bash
tandem pauses --min 0.5                      # what's there
tandem cut --fillers --apply                 # first, the ums and uhs between pauses
tandem tighten --filmora --kinds /tmp/kinds.json      # writes every pause, nothing changes
# read each pause's words in /tmp/kinds.json and set "kind"
tandem tighten --filmora --kinds /tmp/kinds.json --apply
tandem check --cuts                          # every join clean
tandem clip 0:00 1:00 -o /tmp/review.mp4     # watch the result
tandem undo                                  # if it's off
```

`--filmora` finds pauses by volume, the way Mike's old Filmora silence
detection did: every stretch where all the take's tracks are under
`--threshold` (-35 dB peak) and quiet above 4 kHz, for at least `--min`
(0.3 s). A soft final "s" is still a word; a breath is pause. Each pause
then keeps a total gap, speech end to speech start, by its kind: `mid`
0.12 s, `clause` 0.2 s, `sentence` 0.4 s, `topic` 0.8 s (twice
`--buffer`) and `keep` left alone. The keep goes after the word before,
and only `--lead` (0.05 s) before the word after, so the clip coming in
starts a frame or two before Mike speaks ([Where a join's pause
goes](#where-a-joins-pause-goes)). The timeline's own start and end are cut
right to the edge (the start up to the lead before the first word); a
silence running into `--from` or `--to` keeps its keep there.
Stretches where no take track plays, and files whose sound can't be read,
are never cut.

The kind is the agent's call. Bark puts a full stop wherever Mike pauses
("call this. functions"), so punctuation can't say. The dry run guesses
from it (a comma or a clause word after is `clause`, a full stop
`sentence`, or `topic` over 1.5 s, and the rest `mid`); `--kinds <file>`
writes every pause with about eight words either side and the guess, with
`kind` empty. Fill in every one, then `--apply` with the same file. It
refuses while any is empty, and if the timeline changed since the file was
written (re-run the dry run into a new file). In MCP, the dry run's
`pauses` has the same list and `kinds` takes `{at, kind}`.

`--min-clip` (off unless given, `--min-clip 2` for Mike's old "no clips under 2 s") puts back the pause beside any clip a cut
would leave shorter than that, if putting it back adds a second or less
and it's a `sentence` or `topic` pause; Filmora had no such setting, it's
Mike's rule. Anything loud enough stays, a stray "um" or a click included:
cut those with `tandem cut` first.

The transcript rules, only when Mike asks for them:

```bash
tandem tighten --mike --protect 2:14.5,5:03 --widen --apply
```

`--mike` is Mike's older rules ("How Mike likes a take cut" in the skill): 0.4 s
after a sentence, 0.12 s after a comma and 0.08 s for a thinking pause
mid-sentence, and only pauses of 0.5 s or more change, so breaths and
natural pauses stay as he said them. What a pause follows comes from the
punctuation on the word before it: `. ? !` (or `...`) end a sentence,
`, ; :` are a comma, anything else is mid-sentence. Set or override each
keep with `--sentence`, `--comma` and `--mid`; a kind with no keep is left
alone, and a comma without one uses `--mid`. `--min` (default 0.5 here) is
the shortest sentence pause that changes and `--mid-min` (default 0.5) the
shortest comma or mid-sentence one. Each cut is as many whole frames as fit,
so what's kept is within a frame of the keep. As with `--filmora`, the keep
goes after the word before (at least 0.03 s) and `--lead` before the word
after, so the 0.12 s comma keep is 0.07 s / 0.05 s.

`--protect` takes timeline times, comma separated (or the option again):
the pauses containing them are left alone, for the beats Mike wants kept (a
point landing, a reaction, something animating on screen). That's the pause
as the transcript has it or as it's heard, so no cut ever takes out a
protected time. The plan lists what it protected.

`--widen` also opens up joins that are too tight: where a cut between two
speech clips leaves less than the keep for what it follows (0.2 s between
sentences after a retake was cut, say), it brings back silence from the take
either side with ripple trims, so the camera and screen stay in sync. It
only takes silence before the take's next transcribed word (less 40 ms) and
nothing where a word runs through the clip's edge, so it never brings back
speech the transcript knows about; an "um" the transcript left out can come
back, so listen to widened joins. It's off unless you ask, and leaves
through-edits and protected joins alone.

Without any of those, every pause of at least `--min` (0.6) is shortened to
`--keep` (0.15), all but the lead of it after the last word, with the cut
edges rounded inwards to frames.

The transcript only finds the pauses. Each one is then listened to, on
every unmuted audio track of the take that plays there (the voice, another
mic, a device's own recording cut with the take; not music, sound effects
or video tracks' sound), each against its own file's floor, the way
`check --cuts` reads the sound:

- The keep is measured from the sound: from the end of the last word's
  sound to the start of the next word's, not the transcript's times (they
  can be 0.3 s off). `--min` is too, both ways: a gap the transcript makes
  0.6 s that's 0.4 s in the sound isn't cut, and one it makes 0.4 s that's
  0.7 s in the sound is.
- Cuts go in real pauses (quiet on every track) and never through sound no
  word accounts for: someone off mic, an app talking, a breath, an "um" the
  transcript left out. That sound stays where it is and each quiet stretch
  either side of it is cut, so what's left is the sound and the keep. The
  sound counts towards the keep, and so does 30 ms of quiet either side of
  it; what's left of the keep goes after the word before, then beside the
  sound, and the word after keeps only the lead. A stretch beside sound that would
  lose less than 0.08 s isn't cut (not worth two more joins), and if
  there's no quiet long enough anywhere, the pause is left alone.
- Both sides of every join are judged as `check --cuts` judges them. A side
  that isn't clean moves a frame at a time further into the quiet until it
  is, and a cut that can't be made clean is left out.
- `--from` and `--to` hold for the cuts too: a pause as it's heard can run
  past them, and its cuts stop at them.

The plan says which pauses it left alone and why (sound in them, with
where and on which track; under the minimum in the sound; a join that
wouldn't be clean), and each pause it cut beside sound says where that
sound is (and lists each of its cuts), so listen to those with
`tandem clip`. Take out fillers first with `tandem cut --fillers` ([Take
out fillers](#take-out-fillers)): Bark writes most "um"s as words, so each
splits its pause in two and tighten won't cut a word. To take out an "um"
the transcript left out and tighten kept, cut it with `tandem cut --range`. Where any track that plays a pause has a file
whose sound can't be read, that pause is tightened from the transcript's
gap as before, with a warning: the other tracks can't say it's quiet. The plan is a batch of
`rippleDeleteRange` commands (and the widening's `trim`s), latest first so
every time is in the current timeline's times; `--json` prints it if you'd
rather adjust it and `apply` it yourself. `--from` and `--to` limit it to
part of the video. In MCP: `tighten {"mike": true, "protect": [134.5],
"widen": true}`, then again with `"apply": true, "expectedRevision": <the
plan's revision>`.


## Where a join's pause goes

Mike, reviewing the Let's Build It video (13 Nov 2026): "often what you do
is you don't start the next clip soon enough. So you end up with like my
gormless face on screen for like a couple of hundred milliseconds... it
should start the next clip like one frame or two frames before the speech
starts... you should add that extra time onto the end of the previous
clip." So at every join between two pieces of the take, the pause the join
keeps sits on the end of the clip going out, and the clip coming in starts
`--lead` (0.05 s) before its first word's sound. `tighten` (every mode) and
`tandem cut` place joins that way. The word's start is read the way
`check --cuts` reads the sound: a breath before it is pause, a soft first
consonant is followed back down its ramp, and if the join there wouldn't be
clean it keeps more before the word until it is. `--lead` changes it, in
timeline seconds (0 cuts right to the word's sound).

An edit cut before this, or by hand, can still open clips on his face
waiting. `tandem check` notes each join where the camera shows him for
more than 0.1 s before he speaks (`faceWaits`), and this rolls them:

```bash
tandem tighten --lead-only                    # every join, its wait and its roll
tandem tighten --lead-only --apply
tandem check --quick                          # B-roll edges that sat on the old cuts
```

Each join's cut moves later on whole frames, on every track of the take
there (linked camera, screen and voice together), so the clip coming in
starts the lead before his first word and the clip going out runs on
through the quiet after its last word. It only grows through quiet (it
stops 0.03 s short of the next sound) and never into what the next clip
plays, so a join with sound right after the cut rolls less, and one with
none rolls nothing and is listed to trim by hand. The timeline's length and
every other clip stay put. Joins under a wipe, a section card or a
transition are left alone: their cut has to stay under the wipe.
## Take out fillers

```bash
tandem cut --fillers                         # the plan, nothing changes
tandem cut --fillers --from 2:00 --to 5:00 --protect 3:10 --apply
tandem tighten --mike --apply                # then the pauses
```

```
Cut 5 stretches pause to pause (dry run, revision 16), removing 4.296s: 45:53.376 -> 45:49.080.
  02:16.553-02:17.888  "um"  ...parts of the platform. | So when I thought,...  keeps 0.475s of pause; join clean (27 and 30 dB under the speech)
  03:16.196-03:16.947  "um"  ...you have a query, | we really care about...  keeps 0.184s of pause; join clean (25 and 26 dB under the speech)
  ...
Left in:
  02:52.915-02:52.965  "uh": no pause between it and "same": they run together, so a cut there would clip a word. ...
  ...
Fillers: 10 found, 5 cut (removing 4.296s), 5 left in (5 in running speech).
Nothing changed yet. Run again with --apply (or apply: true) to make the cut.
```

`--fillers` makes every filler the transcript has a stretch to cut, as if
you'd asked for each one: um, uh, uhm, erm, er, ah, mm and hmm, in any
case, with punctuation and drawn out ("Ummm,"). Not "oh", "eh", "uh-huh"
or "mm-hmm", which mean something, nor "like" or "you know", which are
often meant, nor the acronym "ER" or "err". Only punctuation round the
letters is let go, so "10mm" and "4Ah" aren't fillers, and one written
with a question mark ("Hmm?") is a question, so it stays. Each is planned
as a phrase is
([Cut a phrase](#cut-a-phrase)): one with a pause either side is cut pause
to pause, and one that runs into a word that stays is left in as `fluent`,
because a natural "um" beats a chopped word. Fillers side by side ("um,
uh"), or a filler beside a phrase or range cut in the same call, with no
word that stays between them, are one stretch, so there's one join and no
sliver of pause between two cuts. That's only within one run of the take
(one clip, or clips that carry straight on), never across a join an
earlier cut made or a clip with no transcript yet, whose sound nobody has
read. Fillers on their own are never false starts, so `--false-start`
doesn't cut one in running speech. If a false start's cut brings a filler
joined to it back, the counts say it was left in (`broughtBack`).

`--from` and `--to` hold it to part of the video. `--protect` takes
timeline times, as tighten's does: a filler with one in it, or in the
pauses either side of it (out to its clip's edge for the last one), stays
(an "ah" of realisation, a beat that's meant). A phrase or range you ask
for in the same call is your choice, though, so a protected filler inside
it is cut with it and counted as cut. The result counts the fillers found, cut and left in (and why) and
the seconds they take out, and lists each one at its timeline time, so
listen to the ones left in with `tandem clip`. In MCP and HTTP: `cut
{"fillers": true, "from": 120, "to": 300}` (`remove` can be left out), then
again with `"apply": true, "expectedRevision": <the plan's revision>`.

Cut fillers before tightening. A filler on its own is a filled pause, so
its join keeps what `tighten --mike` would leave there with no filler at
all, going by the whole pause, filler and all, measured in the sound from
the end of the word before to the start of the word after: "query, [um]
we" with 0.3 s either side is a 0.9 s pause, so it keeps a comma's 0.12 s,
and a pause under 0.5 s with the filler in it is kept as it was. (A phrase is
different: there each pause either side is what the speaker left.) Then
tighten shortens the pauses that are left and leaves the filler joins
alone. The other way round, tighten has already cut the pauses round each
filler down to about 0.11 s, which is often too little to place a cut in:
on the Ian video that cut 11 of its 75 fillers instead of 31, and 33 were
left in with the voice running on.

## Cut a phrase

```bash
tandem cut "as I said before"                # the plan, nothing changes
tandem cut "as I said before" --apply
```

```
Cut 1 stretch pause to pause (dry run, revision 57), removing 2.150s: 12:04.300 -> 12:02.150.
  02:14.060-02:16.210  "as I said before"  ...so the model | picks the...  keeps 0.120s of pause; join clean (28 and 26 dB under the speech)
Nothing changed yet. Run again with --apply (or apply: true) to make the cut.
```

Don't cut at the times `tandem search` gives. Transcript times are 30 to
200 ms off the sound, and a cut there chops the word that stays while it's
still sounding (#64). `tandem cut` finds the phrase as `search` does, then
puts the start of the cut in the real pause before its first word and the
end in the real pause after its last, found in the voice's own sound (the
raw mic, read the way `check --cuts` reads it). The transcript only says
roughly where the words are and which ones stay. A real pause is 80 ms or
more of quiet, full band and above 4 kHz alike; a word the transcript has
0.2 s late still lands on the right side of it.

Between sentences, round a false start and at the take's start, the join
keeps 0.8 s, what Filmora left when Mike deleted a retake's clip (its 0.4 s
softening buffer each side), so it matches the pauses `tighten --filmora`
leaves. A cut that's only fillers, or one after a comma or mid-sentence,
keeps the pause Mike's tighter rules would (0.12 s after a comma, 0.08 s
mid-sentence, by the word before the cut). That pause goes on the end of
the clip before the cut, at least 0.03 s after its word, and the clip after
starts `--lead` (0.05 s) before its first word ([Where a join's pause
goes](#where-a-joins-pause-goes)); neither edge goes closer than 0.03 s to
the words cut. Where neither pause was 0.5 s, the join keeps the
longer one as it was. Each edge goes on a frame where one lands in its
pause. The pauses are timeline time, so on a clip at 2x the join keeps
twice as much of the file. Each edge goes in a pause its own clip plays: a
pause in the file past the clip's end isn't heard there. Both sides of
every join are judged as `check --cuts` judges them, and the plan gives
each side's margin under the speech; a side that doesn't judge clean isn't
cut.

A stretch with no pause round it, like a filler or a repeat inside running
speech ("do that [because of] to keep"), is left in, with the reason:
cutting there clips a word however exactly it's placed, and on the Ian
video leaving the filler in is what sounded right. So is one where the
voice runs on more than 0.3 s past where the transcript has its words.
Sound no transcript word claims, inside the stretch or within 0.3 s of it,
is cut with it. When cutting it would also cut a word that stays, it's
left and the stretch's `missed` says how much, so listen there.

A phrase said more than once needs `--at` with (roughly) the time of the
one to cut, and that counts overlapping ones ("very very" is said twice in
"very very very"); with several phrases, the first `--at` goes with the
first phrase. Each voice track's words are matched on their own, so a
phrase both mics of an interview hear is said once. In MCP and HTTP: `cut {"remove": [{"phrase": "as I said before"},
{"phrase": "you know", "at": "3:10"}]}`, then again with `"apply": true,
"expectedRevision": <the plan's revision>`.

Every stretch goes into one `cutRanges`, so the whole take (camera, screen
and voice) loses the same time, B-roll, music and titles follow, and one
undo puts it all back. `--json` prints the plan with its `commands` if
you'd rather adjust them and `apply` them yourself. Listen to the result
with `tandem clip 2:08 2:20`.

## Rough cuts and false starts

For a rough cut, give `tandem cut` every stretch to drop as a timeline
range, from roughly where its first word starts to where its last ends, in
any order; it plans each one as it does a phrase:

```bash
tandem cut --range 0-18.15 --range 25.6-46.24 "as I said before" --apply
```

A stretch over 2 s is a long false start: when there's no pause between
its last word and the restart, it's cut pause to pause anyway, ending in
the last pause inside it, so a word of it can come back ("the way we, we do
it"). The result says which words come back. On the Ian video putting back
a cut of 2 s or less sounded right, so anything longer costs more to keep
than a repeated word. `--false-start` (or `"falseStart": true` on a
stretch) does the same for a shorter one.

For an exact cut at times you've checked by ear, `cutRanges` still cuts
exactly where you say. Its ranges are all in the times before it, in any
order; Tandem cuts them latest first, cuts overlapping or touching ranges
once, and one undo puts them all back. Then check it with
`tandem check --cuts --from 2:10 --to 2:20`, which gives the fix if a word
got clipped (a trim into a pause, or putting a short cut back):

```json
{"label": "Rough cut: drop the false starts", "expectedRevision": 57, "commands": [
  {"cutRanges": {"ranges": [{"start": 0, "end": 18.15}, {"start": 25.6, "end": 46.24}, {"start": 134.2, "end": 136.05}]}}
]}
```

## Join through-edits

Putting cuts back with ripple trims (or cutting the take and changing your
mind) leaves through-edits: cuts where the same file carries straight on,
so nothing changes there, but the timeline still looks cut up. Join them
rather than lifting and trimming clips by hand:

```bash
tandem join                                  # what it would join, and the cuts it leaves and why
tandem join --apply                          # one undo step
tandem join --from 2:00 --to 3:30 --apply    # only cuts in that stretch
tandem apply '{"join": {"clipID": "clip_k3f9x2mq"}}'   # only the cut after that clip
```

Each joined clip keeps the first clip's ID and link group and plays exactly
what the two did; the camera, screen and voice of a take join together,
and hundreds of cuts join in one go. As nothing Mike would see or hear
changes, a join (with `join` or by hand) adds nothing to his review, and a
piece still waiting for it is highlighted in the clip it joined. A cut is
left, and listed with the reason, when joining would change what plays: a
transition or a fade on it, clips with different settings (a gain, a crop,
an effect), animation that wouldn't carry on across it, or a linked clip
cut somewhere else (a split edit). Take away what's in the way first if
that cut should go too. In MCP: `join {}`, then `join {"apply": true,
"expectedRevision": <the plan's revision>}`.

## Keep the camera in sync

```bash
tandem sync                                  # how late each file's picture is
tandem sync 0.08                             # every camera take: picture 80 ms late
tandem sync 0.05 --media med_screen          # one file
tandem sync 0.08 --default                   # also what new camera takes get
tandem sync --check                          # measure it: voice against lips on each file
```

A webcam's picture lags its microphone (Mike's by about 75 ms), so lips
and voice drift apart. A file's `pictureDelay` makes every clip of it show
its picture that much later in the file, in the app, frames, review clips,
`check` and exports. The sound, the cuts and the transcript's word times
stay where they are, so nothing else moves. New webcam takes get Tandem's
default (Settings in the app, or `--default`); a camera's take (a timecode
track, or a phone's make and model) records in step and gets none. Never slip clips by hand as
well, or the delay doubles. `tandem media` shows it as "picture 80 ms
late, shown in sync". In MCP: `sync {"delay": 0.08}`.

The picture moves by whole frames of the file, so `tandem sync` rounds to
the nearest and says so ("57 ms rounds to 42 ms, 1 frame at 23.976 fps").
Each timeline frame shows the last file frame at or before its moment, so a
delay between two frames moves a clip by one or the other depending on where
it starts between the file's frames: that's why 57 ms overshot on the James
interview. A file with no steady frame rate keeps the delay as given, and so
does the default new takes get; `tandem sync` lists those as "between frames".

### Measure it

```
Lip sync, from mouth opening against the voice as it plays (in-sync footage reads the voice about 13 ms ahead; within 30 ms of that counts):
  med_vndbfm9c  source/James Gemini.mov  voice 56 ms ahead of the lips (halves of the 6 readings say 50 and 61): OFF by 43 ms
    Fix: tandem sync 0.0417 --media med_vndbfm9c
  med_cjajwppv  source/Red Dragon.mov  voice 8 ms behind the lips (halves of the 6 readings say -18 and -3): in sync
```

`tandem sync --check` (MCP: `sync {"check": true}`) compares mouth opening
(Vision's face landmarks) with the loudness of the speech tracks as export
plays them. It reads a sample of each camera file and anything recorded with
it, 20 s stretches where the voice is going, and follows every face in them:
in each 8 s window the one whose mouth moves with the voice is the one talking,
so two people in shot are fine. It changes nothing. `--from` and `--to` read
that stretch of the timeline instead (`until` in MCP, as `to` means something
else there), `--media` picks the files. It exits 1 when a file is off. A file that's turned off (a new angle)
is read anyway, as its clips sit in step with the take.

What the numbers can and can't say. All the windows' correlations are added up
before taking the peak, since one window's wanders by tens of ms; the two
"halves" are the same sum over alternate windows, and when they're further apart
than a frame or 30 ms, whichever's longer, it says "unclear" rather than guess. On the James footage a render of the
same stretch read the same to within about 10 ms, and in-sync files still moved
from -8 to 30 ms between samples with the talker and the words. So a file within
30 ms of 13 ms counts as in sync, and a file can honestly sit between two
frames (the second wide read 35 ms with no delay and -8 with a frame): leave
that alone. Trust it for "a frame or more out", not for milliseconds. "Not
measured" says why: no face, nobody talking on that camera, or a face too small
to read. Speed changes and freeze frames aren't read. The voice is read without
clips' audio effects, which would take minutes to render and don't move it.

Record It now takes the lag out as it records (its Settings → Camera
delay) and tags the file `com.mikerosoft.record-it.camera-delay`. Tandem
reads the tag (`pictureDelayCorrected`, "in sync as recorded" in `tandem
media`), gives those takes no delay of its own, and `tandem sync` leaves
them alone.

## Add another angle or an external mic

A second camera or a separate recorder starts at its own moment, so line
it up with the camera take by sound rather than by hand:

```bash
tandem sync "source/Ian close-up.mov" "source/Ian mic.wav"   # measure, set their take, place them
tandem apply '{"showAngle": {"range": {"start": "4:57", "end": "5:18"}, "trackID": "Angle 2"}}'
tandem clip 4:50 5:25 -o /tmp/angle.mp4                       # watch and listen
```

```
Lined up with source/Ian.mov by sound (how much further into each file the same moment is):
  med_uqkd2zsq  source/Ian close-up.mov  +2.856 s, drift 6 ms over 17:56.954, confidence 54. On "Angle 2".
  med_z7q5wmz7  source/Ian mic.wav  +2.856 s, drift 6 ms over 17:56.933, confidence 54. On "Voice".
Applied "Sync 2 files to Ian by sound" by claude as revision 9.
```

The offset is how much further into the file the same moment is (here
the close-up and mic started 2.856 s before the camera), measured at the
middle of where they overlap; the file can cover any part of the take.

Sound can't see lip sync: a far camera mic and a camera's own audio-to-picture
offset leave a lag however well the sounds match. So it goes on to measure the
take's pictures as `tandem sync --check` does and prints the same report. It's a
look, so trouble measuring doesn't undo the edit. `--no-check` (MCP: `"check":
false`) skips it. So do `--dry-run` and `--no-place`, which leave no new clips to
read.
Drift is how far the two clocks part over the overlap. It's good to a
couple of milliseconds, since someone walking between the cameras moves
their sound about 3 ms a metre, and it warns when it's over half a frame.
Unrelated sound scores under 10 for confidence, and under 15 is refused
with nothing changed, so check the file before trying again. A real match
scores in the hundreds or more on a clean mic. The whole-file match is
then checked in stretches of the overlap; when fewer than half of them
agree, the line says "Only N of M stretches ... agreed" and the offset may
be wrong, so listen before going on.

In one undo step each file joins the camera's take (`takeID`,
`takeOffset`, shown by `tandem media`) and goes beside the take's clips,
linked one clip a track, so ripple cuts, trims and moves keep it in step.
The take is cut where the file starts and stops (through-edits; nothing
plays differently).

- An angle goes on its own cut track right above the camera's, "Angle 2",
  with its clips off, so the camera still shows. Its own sound isn't
  placed.
- A sound file goes on Voice, and the camera's own sound there moves to a
  muted "Camera sound" track, so the mic is what plays and what gets
  transcribed. Outside the mic's stretch the camera's sound stays on
  Voice.
- A second mic (a remote podcast's other guest) finds the first on Voice
  and goes on its own "Voice 2" track right under it, with the same
  levelling. Sync both in one call or one after the other.
- Files of one take end a few frames apart. Where a mic stops (or starts)
  under half a second from a clip's edge, the camera's sound in that
  sliver is muted too, so no blip of it plays after the mic. Leave the
  sliver of picture alone: it's a through-edit and may carry the take's
  fade (removing a clip says when a transition goes with it).

`tandem media` shows each file's `takeOffset`, but changing it with
`updateMedia` once the file is placed moves nothing: its clips keep
playing the same part of the file, and the edit warns. Slip them by the
opposite amount, or remove them and `placeSynced` again.

`showAngle` shows an angle over a range: its clips there come on and the
take's other angles go off. `"trackID": "Camera"` shows the camera again.
The range snaps to frames, and the take is cut at its edges on every track
as through-edits, so the sound doesn't change and later cuts keep the
switch where it was in the take. Don't untick clips or unlink by hand.

`--dry-run` measures and checks the edit without changing anything,
`--no-place` only sets the takes (then `placeSynced` places one), and
`--to` names the camera file when there's more than one. A 46 min camera
take and an 18 min file take about 20 s. In MCP: `sync {"files":
["source/Ian mic.wav"]}`.
