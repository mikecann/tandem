# Sound

Recipes for levelling the voice, holding a quiet mic's peaks, cleaning up a roomy mic (and swapping in a copy cleaned up elsewhere), measuring the mix instead of guessing (loudness over time, checking gain lanes), and putting a swoosh on every push. Gain keyframes and clip gain are in [edit-commands.md](edit-commands.md#keyframes).

## Level the voice

Speech is levelled per take to the project's speech level, -20 LUFS, and
export brings the whole mix to the project's `loudnessTarget` (-14 LUFS
unless set) with true peaks under its `truePeakCeiling` (-1 dBTP), and says
what it mastered to. So the speech level sets how the voice sits against
the music and sound effects (and how loud the app plays), not how loud the
video is. Placing media levels new speech by itself; a project imported
with its own gains, or made before the speech level existed, gets there
with one command:

```bash
tandem loudness                              # each file's loudness, each track's levels
tandem apply - <<< '{"normalizeSpeech": {}}'
tandem loudness                              # "Speech is levelled to -20.0 LUFS" and no stragglers
```

To move the voice for the whole video, change the level (clips normalised
to the old level follow it), then check a review clip:

```json
{"label": "Voice a little louder", "commands": [
  {"updateSettings": {"patch": {"speechLoudness": -18}}}
]}
```

A single clip can still differ: `{"updateClip": {"clipID": "clip_voc7",
"patch": {"audio": {"gainDB": 2}}}}` plays it 2 dB over the rest.

## Tame the peaks on a quiet mic

A separate mic recorded quietly gets lifted a long way to reach the speech
level, and its bumps, claps and shouts come up with it: Ian's whiteboard
mic is lifted 23.5 dB, which puts a knock at 0:14.8 at +23.5 dBFS.
Export's limiter would squash all of that, which sounds artificial.
`tandem loudness` says when it's coming:

```bash
tandem loudness
# 1 speech clip peaks over the -1.0 dBTP ceiling once levelled (up to +23.5 dBTP) ...
tandem apply - <<< '{"normalizeSpeech": {}}'
# Warning: ... it has a compressor and a limiter holding its peaks under -1 dBFS (clip_mic1) ...
```

The speech stays at the speech level. The compressor rides the passages
where the speaker gets louder and the limiter catches what's left, both in
the clip's audio effects, where `tandem timeline` shows them as
`fx compressor,limiter`. Their levels are dBFS as the clip plays (after
levelling), the numbers `tandem loudness --tracks Voice` shows. To set
them by hand, or on a clip of music, add them yourself; `tandem effects
compressor` and `tandem effects limiter` list the parameters:

```json
{"label": "Hold the voice's peaks", "commands": [
  {"addEffect": {"clipID": "clip_mic1", "effect": {"type": "compressor", "params": {"threshold": -14, "ratio": 3}}}},
  {"addEffect": {"clipID": "clip_mic1", "effect": {"type": "limiter", "params": {"ceiling": -1}}}}
]}
```

They render ahead of time over the whole file (a few seconds for a long
take), and then every cut of that take shares the render. Check them with
`tandem loudness --from 4:50 --to 5:20 --tracks Voice --step 0.4`: no
peaks over the ceiling, and the normal speech where it was.

## Clean up a roomy mic

For a mic that hears the room (echo, hum, air conditioning), isolate the
voice and add Voice clean-up, a high-pass for rumble and boom and a gentle
expander that turns the room down between words. The app's Audio tab does
both with Clean up voice; as a batch:

```json
{"label": "Clean up the voice", "commands": [
  {"updateClip": {"clipID": "clip_mic1", "patch": {"audio": {"voiceIsolation": 1}}}},
  {"addEffect": {"clipID": "clip_mic1", "effect": {"type": "voiceCleanup", "params": {"expanderThreshold": -35}}, "index": 0}}
]}
```

Isolation is Apple's voice isolation (`AUSoundIsolation`), run over the
file in the background. It's made for noise and takes some of the echo
with it, but it isn't a de-reverb, and macOS doesn't ship one. Put the expander's
threshold a few dB over the quiet between sentences as the clip plays:
`tandem loudness --tracks Voice --step 0.1` over a pause shows it. Ian's
mic sits around -38 there, so -35; the default, -40, suits a quieter
room. Keep the clean-up first in the effects, so the compressor and
limiter work on the cleaned voice.

### Swap in a processed copy of a file

When the clean-up happens outside Tandem (a de-reverb, DeepFilterNet, a
SAM pass baked to a file), point the media item at the processed copy
rather than placing it again, so every cut stays where it is:

```sh
tandem media replace med_voice1 audio/take1-clean.wav
```

The copy has to be within a frame of the original's length and keep its
sound (and picture, for a video), or Tandem refuses, since clips cut
against the old file would play the wrong words. Export it at the same
sample rate and with no added padding. Tandem then measures the new file's
loudness and transcribes it again, so speech levelling follows the new
level, and the old file stays in the folder without coming back as new
media. Turn off any isolation or expander the clips had for the old file,
and check the joins: a cleaner voice is often softer on word edges, so a
cut that was tight can start clipping words (`tandem check`).

A bare `updateMedia` with a new `path` does the same without the length
check. Don't run `tandem media --refresh` between writing the copy and
swapping it in: if a scan does pick it up as new media first, the swap
removes that copy as long as no clip plays it.

## Separate a sound with SAM Audio

Apple's isolation is free and instant, but it only knows "voice", and at
full strength it can sound processed. Meta's SAM Audio separates whatever
a short prompt describes, from everything else: "speech", "crowd
chatter", "background music", "a man speaking". On Quinn's handheld mic
in the Abstract lobby, its speech stem put the lobby 37.5 dB under the
voice, against 19.4 dB for Apple's isolation at 0.7 (which Mike had
picked), and kept more of the voice's top end.

It runs on a rented RunPod GPU, so it costs money (about US$0.30 to
US$0.50 a job, mostly ten minutes of setup and loading the model) and only
runs when you ask. Give every prompt for a file in one command:

```bash
tandem separate "audio/Mic - A058C554.wav" speech "crowd chatter"   # 10 to 20 minutes
tandem separate "audio/Mic - A058C554.wav"                          # what's been made
```

The stems stay in `.tandem/cache/separation/` by file and prompt, and a
prompt made before isn't paid for again (`--again` makes it anew). Then
clips play them, each stem at its own level (linear, 1 as recorded), in
place of their sound and of `voiceIsolation`:

```json
{"label": "SAM speech with a little lobby", "commands": [
  {"updateClip": {"clipIDs": ["clip_mic1", "clip_mic2"], "patch": {"audio": {"separation": {"prompt": "speech", "target": 1, "residual": 0.3}}}}}
]}
```

The levels are the project's call, not the tool's. `residual` 0 is the
voice alone, which Mike called "really good" but unnatural for a street
interview: there he wants some of the room under it (0.15 to 0.5;
0.3 measured close to Apple's 0.7). `{"prompt": "crowd chatter", "target":
0, "residual": 1}` takes only the chatter out; `{"prompt": "music",
"target": 0.3, "residual": 1}` turns a room's music down. `"separation":
null` plays the clip's own sound again. A clip whose stems aren't made yet
plays without them and `tandem timeline` warns, with the command to run.

What to know:

- It's a re-synthesis through the model's codec, not a mask: even the
  residual isn't the original. Listen to a review clip before handing back.
- Separating one speaker from another on the same mic works best with a
  description that tells them apart ("a woman speaking", "a child
  speaking"). In an October 2026 test of a Mac port, "child speaking"
  alone picked the adult's voice.
- It needs render-box (Mike's RunPod runner) and a Hugging Face token with
  access to `facebook/sam-audio-large` in the Keychain (service
  `huggingface`, account `token`); both are set up on Mike's Mac.

## Check the sound

Don't run ffmpeg on a review clip to hear how loud something is. Tandem
measures the mix itself, through the same composition, gain taps and
time-pitch as export:

```bash
tandem loudness --from 1:00 --to 1:30              # the mix, a row every 0.5 s
tandem loudness --from 1:00 --to 1:30 --tracks Music --step 0.2
tandem loudness --from 1:00 --to 1:30 --gains      # does the render follow the gain lanes?
tandem loudness --from 0 --to 18:00 --tracks Voice --over 0   # where does the voice clip?
tandem clip 1:00 1:30 --tracks Music --audio-only  # listen to the music bed alone
tandem assets show elevenlabs:music_2p839smz       # its prompt, licence, loudness and file
```

Each row has the momentary loudness (the 400 ms centred on its time), the
short-term (3 s) and the highest sample, with the range's integrated
loudness, true peak and a sparkline above. They're the levels the timeline
plays at, before export's master gain, which moves the whole range by the
same amount, so compare things with each other: a swell 6 dB over the bed
around it, the bed about 25 LU under the voice, a sound effect's peak
against the speech. `--tracks` measures only those audio tracks (names or
IDs); `--json` gives every point. A long range at a small step reads as
the summary without the rows; the JSON still has them.

`--over <dBFS>` lists only the windows whose highest sample is over that
level, merged into stretches with their peak: the direct answer to "where
does this clip" (`--over 0`) or "what touches the ceiling" (`--over -1`).
Without `--step` it measures every 0.4 s, so the windows cover the range.

`--gains` checks the render against the gain lanes (the clips' levelling,
gain, gain keyframes and fades). It renders each track (the `--tracks`
ones, or every one that plays there) as it is and again with its gain
flattened, and compares their difference with the lane 10 ms at a time.
It says when a change lands late and by how much, and lists where the
render plays more than 1 dB off the lane. If Mike says a gain change
plays late, run it before arguing: it checks the render does what the
lanes say (a lane set in the wrong place is a different problem, which
`tandem timeline` shows).

## Put a swoosh on every push

A swoosh belongs to its transition: give a push a `sound` and it goes
where the push goes, and away with it. The light swoosh Mike likes (the
app's default for push, slide, cut slide and wipe) is
`elevenlabs:sfx_2ybnc2tu` in his asset library. Copy it into the project
once, find the pushes that have no sound yet, and give them all one in one
batch:

```bash
tandem assets use elevenlabs:sfx_2ybnc2tu     # adds it to the media: med_rgm8r7d7
tandem timeline --json | jq -r '.project.videoTracks[].transitions[] | select(.type == "push" and .soundClipID == null) | .id'
# tr_k3f9x2mq
# tr_p8zq4w2m
```

```json
{"label": "Swooshes on the pushes", "commands": [
  {"updateTransition": {"transitionID": "tr_k3f9x2mq", "patch": {"sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}},
  {"updateTransition": {"transitionID": "tr_p8zq4w2m", "patch": {"sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}}
]}
```

Each goes on SFX (SFX 2 where SFX is taken) starting 0.39 s before the
cut, so its loudest moment lands where the push moves fastest (the light
swoosh is loudest 0.39 s in). -23.3 dB is for speech at Tandem's -20 LUFS:
its loudest 400 ms then sits 15 LU under the voice, as the section card
whooshes do. In a project whose speech plays elsewhere (`tandem loudness`
says where), move the gain by the difference: -32 for speech at -28.7. For
another sound, `offset` is minus the moment it's loudest, and the gain puts
that 15 LU under the speech. A push that already has a whoosh placed by
hand beside it can keep that one: tie it with `{"soundClipID": "clip_..."}`
in the patch, and it moves and goes with the push from then on. A new push
can get its sound in the same command:

```json
{"addTransition": {"trackID": "trk_camera", "transition": {"type": "push", "fromClipID": "clip_a", "toClipID": "clip_b"}, "sound": {"mediaID": "med_rgm8r7d7", "gainDB": -23.3, "offset": -0.39}}}
```
