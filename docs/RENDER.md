# Tandem render module

How a project becomes pixels and sound: the viewer, frame grabs and export
all go through the same path, so what Mike sees is what YouTube gets.

```
Project ──RenderPlanner──▶ RenderPlan (pure)
                             │
                 CompositionAssembler (AVFoundation)
                             │
        AVMutableComposition + AVVideoComposition + AVAudioMix
           │                  │ TandemCompositor (Core Image, Metal)
           │                  │   └─ FrameComposer: one frame from a layer stack
     AVPlayer (viewer's picture)   FrameRenderer (AVAssetImageGenerator, RGBA)
     ViewerAudio (its sound)       Exporter (AVAssetReader ▶ VideoToolbox ▶ AVAssetWriter)
```

## Files

| File | What it does |
| --- | --- |
| `RenderAPI.swift` | The public contract: `RenderContext`, `CompositionBuilder`, `FrameRenderer`, `ExportPreset`, `Exporter` |
| `LayerMath.swift` | Placement maths shared with the viewer: fit, transform, orientation, crop, zoom to rectangle, format overrides |
| `RenderPlan.swift` | Pure plan: composition track pools (A/B), instruction splits and layer stacks, audio segments |
| `AudioEnvelope.swift` | Clip gain, fades, keyframes, crossfades and micro-fades as volume breakpoints |
| `AudioGain.swift` | Each audio track's envelope applied sample by sample by an `MTAudioProcessingTap` |
| `ViewerAudio.swift` | The viewer's sound: the mix read ahead through the gain taps into an `AVSampleBufferAudioRenderer`, forwards or backwards, on the clock the viewer's players run on |
| `CompositionAssembler.swift` | Plan to AVFoundation: source loading, speed, freeze, hold, base track, audio mix |
| `Compositor.swift` | `TandemInstruction`, `TandemCompositor` (4:2:0 video range) and `TandemRGBCompositor` (grabs) |
| `FrameComposer.swift` | The per-layer pipeline, cutout, repair masks, text layers, still image cache |
| `Effects.swift` | Colour, colour wheels, HSL, vignette, sharpen, LUT and Core Image bindings; rounded corners, border, drop shadow |
| `ColourWheelGrade.swift` | The colour wheels as per-channel lift, gain and gamma, and the same maths on the CPU for tests |
| `Kernels.swift` | Runtime-compiled Metal Core Image kernels |
| `Transitions.swift` | All transition types |
| `TextRenderer.swift`, `TitlePresets.swift` | Core Text titles, presets, animations, word captions |
| `SectionCardRenderer.swift`, `CardFonts.swift` | The built-in section card (`sectionCard` graphic clips): layout, drawing and its bundled typefaces (`Resources/Fonts`) |
| `Limiter.swift` | Lookahead true-peak limiter |
| `Export.swift` | Loudness passes, VideoToolbox encoder, mastered audio, snapshot |
| `PowerAssertion.swift` | Keeping the Mac awake: exports stop it idling to sleep, the app's player keeps the display on |
| `RenderAssets.swift` | `RenderAssets`: proxies, mattes, isolated voice, loudness, converted copies (from `MediaAnalysis`) |
| `ConvertedMedia.swift` | Frame grabs and exports convert what macOS can't decode before they build |

## Timeline rules

- Video tracks draw bottom to top. Hidden tracks, disabled clips and clips
  hidden in the current format are skipped.
- Every media video segment goes on the first free composition track of one
  shared pool, so clips overlapping in a centred transition land on
  different tracks (A/B). Cutout mattes get their own segments with the same
  time mapping. A tiny black movie underlies everything, so the video spans
  the whole timeline even with only titles or a trailing gap.
- Pictures with alpha only share composition tracks with each other.
  AVFoundation decodes a track's files with one decoder while their codec
  and size match, and a plain HEVC decoder drops the alpha of HEVC with
  alpha: it hands over 4:2:0, or BGRA with alpha 255 when that's all it's
  asked for, even across a gap or when reading starts after the plain file.
  Every proxy is 1080p HEVC, so an overlay's proxy on a track after a
  camera's or screen's played black wherever the overlay was clear, and
  `tandem check` found its clear frames black (issue #10). Originals of the
  same codec and size did it too, in exports; frame grabs decoded them
  right. Alpha after alpha keeps each file's alpha and its straight or
  premultiplied mode, and plain after alpha decodes fine.
- A two-sided transition is centred on the cut (the outgoing clip plays on
  for half, the incoming one starts half early from its handle, holding its
  first frame where the file has none before, as the outgoing one holds its
  last). A one-sided
  transition sits inside its clip. Short clips with overlapping transitions
  nest: `(A to B) to C`.
- Speed uses `scaleTimeRange`; a freeze frame is one frame stretched; media
  that runs out holds its edge frame (video, first or last; the direct
  decode path clamps to the first frame too) or goes quiet (audio). That's
  how a clip with `holdEdges` runs past its file, too.
- Instructions split at every visible clip edge and transition edge.
- Graphic clips (`.graphic`) with a built-in template, the section card
  (`sectionCard`), are drawn by the compositor like titles. Other graphic
  templates aren't rendered yet: there's no rendered-file contract, and
  they produce a warning.
- A file macOS can't decode (`MediaItem.undecodableCodec`: QuickTime
  Animation or PNG stickers) plays from its `converted` HEVC copy
  (docs/MEDIA.md). Frame grabs and exports make a missing copy before they
  build (`ConvertedMedia`), about a quarter of a second for a sticker, so
  the sticker is in the picture. The viewer doesn't wait: the clip is left
  out, with a warning, until the background conversion lands. A file that
  can't be converted (no ffmpeg) is left out with a warning saying why,
  and a source that turns out undecodable anyway (scanned before Tandem
  checked) is loaded without its video. One undecodable track used to fail
  the whole composition with "Cannot Decode".

## Layer pipeline

Per layer: source frame the right way up (the track's preferred transform),
the media's `look`, the clip's colour and utility effects in order, crop,
cutout, rounded corners, border, transform, drop shadow, opacity.
Keyframes are evaluated per frame at clip-relative time. Adjustment layers
apply their effects to everything below, mixed in by their opacity.

- **Units.** `px@1080` values are output pixels at 1080p, scaled by the
  canvas's short side (a 4K export doubles them, a 9:16 short keeps them).
  Effects that run in source pixels divide by the layer's scale, so a blur
  or border looks the same whatever the zoom. Cutout feather and choke use
  the same rule.
- **Colour.** Core Image colour management is off: pixels are composited as
  the encoded values they are, like Filmora. Sources are decoded with their
  own YCbCr matrix and range (the Kiyo camera is full-range BT.601);
  output is tagged BT.709 video range. Solid and text colours are sRGB
  code values. The video composition carries no colour properties: with
  them AVFoundation re-tags every source frame BT.709 without converting
  it, and BT.601 footage came out with the wrong matrix (red 180/40/50 as
  192/54/48). The compositor also attaches Core Media's 709 colour space
  to its output, as decoders do for 709 files: with the tags alone,
  AVPlayerLayer uses the exact BT.709 curve and lifts the shadows (black
  16 showed as 32 on screen, against 14 for paused stills and exports).
- **Colour effect.** One kernel: exposure (stops), contrast (pivot mid grey,
  +100 is 1.5x), black level, highlights, shadows, saturation, vibrance,
  temperature, tint. Black level and the vignette were calibrated against
  Filmora's v14 export of the same footage (tone percentiles and the radial
  fall-off match to about 1%). Contrast hasn't been calibrated yet: v14 has
  none.
- **HSL.** Eight ranges (red 0, orange 30, yellow 60, green 120, aqua 180,
  blue 240, purple 270, magenta 300 degrees); a pixel blends its two
  neighbours; near-greys are untouched. Hue ±100 is ±30 degrees.
- **Colour wheels.** Shadows, midtones and highlights as lift, gamma and
  gain per channel: `x + lift * (1 - x)`, times `gain`, raised to `power`.
  `ColourWheelGrade` works the three out on the CPU and one kernel applies
  them. A wheel's colour is its amount (0 to 1) times its hue's direction,
  the change in R'G'B' with no BT.709 luma and one unit of chroma
  (`ColourWheels`, in Core, which the inspector's wheels use too), so a
  puck changes a range's colour but not its brightness, and moves it on a
  BT.709 vectorscope the way the puck points. Hues are HSV degrees, the
  same as the HSL ranges. At amount 100, black (shadows) and white
  (highlights) move 0.1 of chroma and mid grey about half that for each
  wheel; brightness 100 lifts black by 0.15, raises white by 25% or takes
  mid grey from 0.5 to 0.61 (an exponent of 2^-0.5). Nothing is
  clamped and the exponent is odd about zero, so values below black or
  above white (extended range, or an earlier effect's overshoot) stay
  finite and in order, and a later effect can still bring them back.
  `ColourWheelsRenderTests` checks all of this on patches read back in
  float.
- **Live previews.** While something is dragged, `LiveVideoOverrides` in
  the render scene stands in for what isn't committed yet, read for every
  layer on every frame: clips' video properties (a viewer drag, the
  inspector's sliders, a clip's own colour) and files' looks (the Colour
  tab's whole take, for every clip of the file). A paused player
  composites its frame again. `set([:])` ends a preview, looks included,
  once the composition with the committed edit is on screen.
- **LUT.** `.cube` 3D or 1D (1D is expanded to 33 points), path relative to
  the project folder, parsed once and cached.
- **Cutout.** The matte multiplies alpha (its luma, full range). Feather,
  choke and repair shapes are worked out at the matte's resolution. The
  matte covers the whole frame with the source's frame times, and its own
  preferred transform is applied. A clip uses the matte made in its cutout
  mode (`matteURL(for:mode:)`), else the default one; no matte yet means no
  cutout, with a warning.
- **Border** follows the alpha when the layer is cut out, otherwise it's a
  crisp frame outside the (rounded) rectangle.
- **Drop shadow** follows the alpha. `angle` is where the light comes from,
  degrees anticlockwise from the right, so the default 135 casts down right.
- **Text** is drawn with Core Text at output resolution (times the clip's own
  scale, up to 4x, so big titles stay sharp) and cached per content, size
  and animation state. Fonts that aren't installed fall back to the system
  font at the requested weight (CSS weights, 100 to 900). Lines wrap at 90%
  of the canvas width.

## Transitions

Directions are the direction of motion; the default is `left`.

| Type | Behaviour |
| --- | --- |
| dissolve | Even mix; one-sided fades from or to transparent |
| fadeToBlack, fadeFromBlack | A dip: the outgoing side darkens, the incoming side brightens; one-sided uses its whole length. Alpha is kept, so a PiP dips to a dark silhouette |
| push | Both shots move together, ease in and out |
| slide | The incoming shot slides over a still outgoing one |
| cutSlide | A short, fast push (quartic ease) with a hint of motion blur |
| wipe | A soft edge sweeps in the direction of motion |
| zoom | Cross zoom: into the outgoing shot, out of the incoming one, with a light zoom blur |

On audio tracks every transition is an equal-power crossfade. A
transition's sound (ARCHITECTURE.md) is an ordinary clip on SFX, mixed like
any sound effect.

## Titles

`TextContent.preset` picks a row from `TitlePresets.builtIn`: `label`,
`callout`, `sectionHeader` (two lines, the first smaller in the accent
colour), `version`, and `caption` (word by word, the spoken word
highlighted). The clip's `style` overrides any field it changes from
`TextStyle()`'s defaults; `animationIn`/`animationOut` override when set;
`animationDuration` overrides when it isn't the 0.4 s default. A text clip
without video properties sits at the preset's position. Animation names:
`fade`, `pop` (scale with overshoot), `slideUp`, `typewriter`, plus common
aliases (`popIn`, `fadeOut`...).

## Section cards

A `sectionCard` graphic clip is Mike's section card, the design he picked
from `~/dev/me/tandem-research/title-cards/mockup-template.html`: card B's
Convex bands (yellow #F3B01C, red #EE342F, purple #8D2676 on #141418)
with card D's progress row. `SectionCardRenderer` draws each frame with
Core Graphics and Core Text at the output size and hands it to the layer
pipeline as a canvas-sized picture, so a clip transform, opacity or effect
applies as to any other, and the viewer, paused stills, frame grabs and
export all show the same frame.

- **Layout** (`SectionCardLayout`) is the mockup's CSS in cqw, a hundredth
  of the frame's width, so the card scales with the frame. A grid centred
  both ways, rows 1.6cqw apart: the number chip (JetBrains Mono 700 at
  1.6cqw, letter-spacing .08em, padding .55cqw by 1cqw, radius .5cqw, the
  card's colour on the accent) with the kicker 1.4cqw to its right
  (Instrument Sans 600 at 1.45cqw, .2em, #D9DCE1, centred on the chip);
  the title (Anton at 9.4cqw, line height .95, .01em, white, at most
  84cqw wide and balanced like `text-wrap: balance`); the subtitle
  (Instrument Sans 600 at 1.7cqw, .34em with as much again on the left so
  the words sit in the middle, accent); then .6cqw further, D's progress
  row: bars .35cqw by 5cqw, .6cqw apart, lit up to this section in the
  accent and the rest white at 28%, or past six sections one 30cqw bar in
  proportion and the count (JetBrains Mono 500 at 1.5cqw, #CFD3D9). Text
  is upper case except the count. Baselines sit where CSS puts them: the
  font's ascent and descent centred in the line box.
- **Motion** (`SectionCard.Motion`, in Core, which `addSectionCards` uses
  too): each band is 46% of the width wide and 140% of the height tall,
  skewed 16 degrees, and sweeps left to right in 0.72 s with
  `cubic-bezier(.65, 0, .35, 1)`, the next 0.08 s behind. The sweep in
  starts with the clip; the sweep out starts 0.88 s before the end, so the
  last band leaves as the clip does. A longer or shorter card holds longer
  or shorter; a card under 1.76 s shrinks both wipes to fit. The words
  come in 0.52 s after the start over 0.45 s with `cubic-bezier(.16, 1,
  .3, 1)`, from transparent, 2.5cqw lower and 98% of their size, about the
  frame's centre.
- **Cursor.** Mike asked for a little life on the hold: a text cursor
  after the last letter of the title's last line, a solid bar in the
  accent 0.1em wide (of the title's size) from the baseline up to the
  capitals' height, 0.07em after the letter and its letter-spacing. The
  title stays centred as the mockup has it and the cursor hangs after it,
  so nothing moves as it blinks. It comes in with the words (same fade
  and rise), is lit as the title lands (0.97 s), then goes off and on
  every 0.53 s with hard steps, like a terminal's (Windows' standard caret
  blink), and is gone once the wipe out starts; a lit spell the wipe out
  would cut to under half isn't started, so it never flashes before the
  wipe. The `cursor` prop (on unless false) and the Video tab's switch
  turn it off. `SectionCardRenderTests` pins it at 1080p (x 1464, y 447,
  17 by 154 after METHODOLOGY) and 4K (twice that, to the pixel), in the
  compositor, a frame grab and an export.
- **Length.** A card's words set how long it needs
  (`SectionCard.fittedDuration(for:)`): 1.4 s for the wipes (the words
  are fully in from about 0.7 s, and the wipe out's first band reaches
  them about 0.7 s before the end), 0.8 s to find the card and take it
  in, then the title, subtitle and kicker as the card shows them, spaces
  included, at 15 characters a second: a little slower than Netflix's 17
  for adult subtitles, since Mike found cards at 17 went by a bit fast.
  Rounded up to a tenth of a second (and to a frame), at least 4 s and at
  most 7 s (about 72 characters; longer stops being a breather), so
  METHODOLOGY / LET'S KEEP IT FAIR (30 characters) gets 4.2 s. `addSectionCards`, `tandem cards` and
  the Templates tile use it unless given a length, and the Video tab's Fit
  to text sets it for a card whose words changed, moving its whoosh out
  with the wipe out.
- **Wipes.** The card shows behind the first band on the way in (left of
  its left edge) and the next shot shows behind the last band on the way
  out, so the wipes reveal the shots either side; the bands are drawn on
  top, first to last. The card hides the whole frame from about 0.43 s to
  0.41 s before the end at 16:9, which is where `addSectionCards` puts the
  cut.
- **On purpose, not the mockup.** Rendered in Chrome, the mockup's second
  `b-sweep` animation (fill mode both) held the bands off screen during
  the first, so they never swept in and the card popped in at 1.28 s;
  both sweeps play here. Its bands travelled 360% of their width, which
  left a purple sliver bottom right; they travel 372% (more on a tall
  frame) and leave. Its card switched in and out at single moments
  (1.28 s and 3.62 s), which showed as a pop across the right fifth of
  the frame; here the reveal follows the bands. Timings count from the
  clip. D's lit bars were Tandem's amber and sat at the top of the row
  beside the count; here they're the accent and centred on it.
- **Checked against the mockup.** `title-cards/tandem/reference-b-with-
  progress.html` is the mockup's CSS with those changes (the reveal is a
  clip-path set from where Chrome put the bands). Its frames from headless
  Chrome and Tandem's for the same moments of the four sample cards, 1920
  by 1080, differ by under 1 level on average and in under 1% of pixels by
  more than 24, all on antialiased edges: positions agree to a pixel.
  `SectionCardRenderTests` pins the chip, title, subtitle and bars to
  Chrome's positions at 1080p and 4K, and checks every pixel of two rows
  against the motion at moments in both sweeps.
- **Fonts.** Anton, Instrument Sans and JetBrains Mono (the last two
  variable, set to their weights) ship in `Resources/Fonts` with their
  OFL licences and are read straight into font descriptors from the
  resource bundle, wherever it is (the app's Resources, beside the CLI,
  beside a test bundle), so nothing is installed and every process and Mac
  draws the same card. Without the bundle the card falls back to Impact,
  the system font and SF Mono or Menlo.
- **Cost.** The words are drawn once per card and frame size; a wipe
  frame fills the card, draws them over it (and the cursor), clips and
  draws the bands, about 22 ms at 4K in a debug build. The hold is drawn
  twice, cursor lit and not, and reused.
  A 3.2 s card exports at 4K in 1.1 s against 0.9 s for a plain solid
  (release build).

## Audio

- Clip gain (dB, -96 or lower is silence), `normalizeTo` (target minus the
  file's measured loudness, capped at ±30 dB, nothing for a silent file),
  `audio.gainDB` keyframes, fades (equal power), transitions, and voice
  isolation (original times 1 - v plus the isolated file times v) all
  multiply into one envelope per segment, sampled finely enough that
  straight lines between its points sound smooth. Levels below has how
  normalise and gain combine.
- The envelopes are applied to the samples, not by AVAudioMix volumes: an
  `MTAudioProcessingTap` on each audio track of the mix (`AudioGain.swift`)
  multiplies every sample by the gain at its timeline time, in the viewer,
  review clips, export and the loudness passes. AVAudioMix's volume ramps
  lag (see Gotchas): a clip held at +16 dB up to a cut carried into the
  next clip for 0.35 s, and a keyframed ramp from +24 dB landed 0.4 s late.
  The tap sits before AVFoundation's effects, so it sees each file's own
  samples, before a speed change is time-stretched or the player's rate
  applied, and it maps them to the timeline through the segment's speed.
- The viewer reads its sound the way export does, ahead of time, through
  taps of its own (Viewer sound, below); its `AVPlayer` shows the picture
  only.
- Every hard cut gets a 3 ms fade each side. Joins that continue the same
  media seamlessly (same file, contiguous source, same speed and gain) don't.
  (Until the tap, AVAudioMix's lag meant these fades never happened.)
- A composition audio track only plays sound in one format (codec, rate,
  channels, sample layout), so a camera's AAC and a sound effect's WAV go
  on different tracks (`RenderPlanner.assignTracks`). A tapped track that
  changes format part way stalls AVFoundation's reader for good.
- Speed changes keep their pitch (spectral time-pitch).
- `pitchShift` (semitones, keyframable) renders the clip's sound once
  through Apple's time-pitch unit, offline, into a cached copy in
  `~/Library/Caches/Tandem/pitch` (keyed by the file, range, pitch and,
  for keyframes, the timing), and the composition plays the copy. The unit
  adds no delay offline, so sync is untouched; a speed change on the same
  clip still keeps the shifted pitch.

## Viewer sound

The viewer's `AVPlayer` shows the picture only (`makePlayerItem` leaves
the composition's audio tracks out). Its sound is read ahead of time by
`ViewerAudio`, the way export reads the mix: an `AVAssetReader` on the
composition with an `AVAssetReaderAudioMixOutput` and gain taps of its
own (the same envelopes), into an `AVSampleBufferAudioRenderer` under an
`AVSampleBufferRenderSynchronizer`.

Why: with the taps in AVPlayer, a tapped track's sound went through them
in real time, about 0.4 s ahead of what's heard and only once playing
started, so play took about 0.5 s to start after a seek or an edit, and
tracks after the first joined about 0.1 s late, missing that much sound
(Gotchas). A reader runs far faster than real time: the first 8192
frames of a three-track mix arrive in about 10 ms.

- While paused, the sound from the playhead is queued: a prime reads it
  into the renderer, which takes about a second and then stops asking.
  It's queued 0.1 s after the playhead comes to rest (scrubbing seeks
  many times a second), and at once after a pause or when a new cut
  comes on screen. A quarter of a second queued counts as ready, 25 to
  35 ms after the prime starts.
- Play asks the synchronizer to start from the playhead and lets it
  choose when. Once it has (20 to 30 ms later), its timebase gives the
  host time it reaches the playhead at, about 0.1 s after that, and the
  picture starts at that host time (`setRate(_:time:atHostTime:)`). Left
  to choose, it gives the output time to start, so the first sample is
  heard as the first frame shows. A fixed 0.1 s lead wasn't safe: woken
  from idle, the output takes 0.1 s more. If the sound isn't queued yet
  (play straight after a seek), the start waits for the prime.
- The output device goes idle about 2.5 s after the last sound, and
  waking it takes 0.1 s, so a start from idle took 0.2 s. AVPlayer kept
  the device running for about 35 s after a pause, and `ViewerAudio`
  keeps it running for 30 s after it plays or queues sound
  (`AudioDeviceStart` with no IOProc, about 0.1% of a core, following the
  default device when it changes). Starts take about 0.13 s, and 0.2 s
  after a longer rest. Not for ever: a running output keeps the Mac from
  idling to sleep.
- Both run on the default output device's clock: the players' `sourceClock`
  is `CMAudioDeviceClockCreate`'s, and the synchronizer runs on the
  device once it has sound. Measured over 180 s of play, the picture and
  the sound were never more than 0.06 ms apart and drifted under
  0.01 ms.
- Pausing stops the picture where it is and primes again from there,
  rather than trusting what the renderer kept. The sound runs on for up
  to 40 ms after the picture stops, as the synchronizer stops.
- J and L at 2x, 4x and 8x change both at the same host time,
  `ViewerAudio.startLead` (0.1 s) ahead, with spectral time-pitch, as
  AVPlayer played them: sound at every speed, pitch kept.
- Backwards, AVPlayer played these compositions with the sound reversed.
  The synchronizer can't run backwards, so its time counts from where
  reverse play started and the sound is read in 2 s blocks going back,
  each through new taps and reversed (four readers a second at 8x, about
  5% of a core). A start backwards waits for its first block, about
  85 ms, where a prime forwards takes about 15 ms (on a 1080p take with
  three audio tracks, and on ten minutes of 520 sound clips alike). A
  composition that can't play backwards still steps the picture with a
  clock, silently.
- A seek while playing (clicking a clip away from the playhead), a change
  of direction, an edit landing while playing and the renderer dropping
  its sound (an output device change) stop both and start them again
  from the playhead, with the new mix after an edit: the picture stands
  still about 0.19 s. The renderer can't splice in new sound sooner than
  a second ahead (Gotchas), so this is quicker than a seamless swap.
- The sound is padded with silence to the end of the timeline, so the
  renderer never runs dry before the picture does.
- Scrubbing makes no sound, as before. `TANDEM_MUTED=1` (and every test)
  mutes the renderer.
- The synchronizer is told what to do on a queue of its own: stopping or
  changing speed holds up its caller for 30 to 40 ms. Each prime feeds
  the renderer from a queue of its own too, so a reader that stalls holds
  up nothing else.

Measured on an M5 Pro with `PlaybackController` itself, a 1080p take with
its sound, music and a sound effect (three composition audio tracks),
October 2026:

| | AVPlayer with the gain taps | `ViewerAudio` |
| --- | --- | --- |
| Play after a seek (median of 6) | 0.53 s | 0.13 s |
| Play after an edit, paused | 0.50 s | 0.13 s |
| Play on after a pause | 0.10 s | 0.13 s |
| Picture standing still as an edit lands while playing | 0.61 s | 0.19 s |
| Sound of tracks after the first at the start | 0.10 to 0.14 s missing | there from the first sample |
| Picture against sound over 180 s of play | one player | 0.06 ms apart at most |
| CPU playing, this process | 6% of a core | 6% |
| CPU paused, this process | 0.15% | 0.08% |

Before the taps, AVPlayer started in 0.14 to 0.17 s (0.21 s with the
output idle), and played on after a pause in 0.02 s; its audio queue
stayed primed while paused. The synchronizer has no such shortcut, so
playing on now takes a start like any other, 0.03 s more than with the
taps. coreaudiod ran at 4 to 5% of a core in both, most of it other
apps' sound.

## Levels

Speech is levelled per take, then export masters the whole mix.

- A clip with `normalizeTo` gets a constant gain: the target minus its
  file's integrated loudness (BS.1770, measured in the background), at most
  30 dB either way, and none for a silent file. The clip gain (`gainDB`, or
  its keyframes) is added on top, then fades. A -32.2 LUFS take normalised
  to -20 with +2 dB plays at about -18. The maths is in `AudioLevels`; the
  render plan, `tandem loudness` and the Audio tab share it, and the viewer,
  review clips and export all take their sound from the same plan
  (`LevelRenderTests` checks the viewer's mix against the export's). Stills
  have no sound.
- Speech is a camera's sound, a file with no clearer role (a rendered
  intro), or anything on a `cut` audio track like Voice, muted or not.
  Placing it normalises it to `settings.speechLoudness` with no gain, and
  `normalizeSpeech` (Normalise speech clips in the Audio tab) sets every
  speech clip to it and clears its gain, as one undo step. Changing the
  setting moves the clips normalised to the old level. Music (-31 dB with a
  2 s fade out) and sound effects (-15 dB) keep plain gains.
- Export then brings the mix to the project's loudness target (-14 LUFS
  unless set) under its ceiling (-1 dBTP), so the speech level
  decides the balance against music and sound effects, and how loud the
  viewer plays (it plays the mix before the master), not how loud the video
  is.

The speech level is -20 LUFS because:

- It's where Mike's voice played in Filmora. Filmora's Auto Normalization,
  on for the voice in every Filmora project in convex-videos (24 files
  from five videos), levels a file to about -24 LUFS on Tandem's meter
  (Filmora says -23), and his LoudnessGain of +1.9 to +4.1 dB goes on top.
  On the v14 export, 62 voice clips from three takes played at -24.1 LUFS
  plus their LoudnessGain (spread 0.7 dB) and the music at its plain
  VolumeGain; the voice sits at -20.4 LUFS and the whole export at -20.1.
  The -31 and -15 dB music and SFX gains come from those projects, so they
  keep the balance Mike mixed by ear.
- It's the quiet end of the -16 to -20 LUFS that AES recommends for speech
  streams (TD1004, TD1008), and leaves the master about 6 dB to add.
- The viewer has no limiter. Levelled to -20, the demo's 635 s of voice
  goes over 0 dBFS in 4 clips by at most 2 dB; at -18 in 22 clips by up to
  4 dB, at -16 in 58 by up to 6 dB, which would crackle in the app and not
  in the export.

On the v14 demo, Normalise speech clips moves its 230 speech clips (Voice,
Voice 2 and the intro) to -20 LUFS. The export still measures -14.0 LUFS
with true peaks at -1.1 dBTP before the AAC encode (ffmpeg reads -0.8 from
the file, and -0.9 before the change: the codec's overshoot). The voice
now sits 23.7 dB over the music in the pauses, against 25.9 dB in
Filmora's own export and 18.0 dB with the gains the Filmora import copied.

A Filmora import normalises speech to the speech level, the way placing
does. It used to copy LoudnessGain as a plain gain, which put the voice
8 dB lower against the music than Filmora played it. `--keep-levels`
keeps Filmora's own levels instead, as `normalizeTo: -24` plus the clip's
gain. The decision-models EDL recipe's -28.74 LUFS voice came from the same
reading of LoudnessGain; it now uses the speech level.

## Export

1. Plan the preset for the project (see Presets below) and build the
   composition at the plan's size and format (never proxies).
2. Measure the mix (audio only, fast). If the gain would push true peaks
   over the ceiling, the limiter will take some loudness with them, so one
   more pass runs four gain and limiter chains side by side (the gain plus
   0, 0.75, 1.5 and 2.5 dB) and interpolates the gain that hits the
   target. On the v14 edit that lands within 0.02 LU.
3. Composed frames go to a hardware `VTCompressionSession` (HEVC Main or
   H.264 High, speed priority, preset average bitrate, 2 s GOP, BT.709) and
   are muxed with AVAssetWriter. The mix gets the master gain and the
   true-peak limiter (5 ms lookahead, 4x oversampled detection, 0.1 dB
   margin, delay compensated), then AAC 48 kHz stereo. Timelines without
   sound get a silent track. The limiter aims 0.5 dB under the preset's
   ceiling, because AAC overshoots the limited mix (see Presets).
4. `<output>.tandem` is written beside the file: the project with absolute
   media paths and `export.*` metadata.

The loudness target and true peak ceiling come from the project's settings:
`ExportPreset.plan(for:)` puts them on every preset that masters
(`mastered(by:)`), so a project at -16 LUFS exports at -16 whatever the
preset says (mikecann/tandem#3). A preset with nil loudness leaves the mix
alone. The exporter takes the planned values, less the AAC margin on the
ceiling. The encoder lock is held at `.export` priority
while encoding, released on every exit including cancel and errors (not
held during the loudness passes, which don't encode). Outputs must be
.mp4, .mov or .m4v and can't be one of the project's media files.

While it runs, `Exporter` holds a PreventUserIdleSystemSleep power
assertion, so a long export left alone isn't paused by the Mac going to
sleep; the display can still sleep. The app's export queue, `tandem
export`, `tandem clip` and the HTTP and MCP exports all run through it,
and it's let go however the export ends.

### Presets

A preset sets the quality and the project sets the shape.
`ExportPreset.plan(for:format:)` (`ExportPlan.swift`) works out what a
preset renders for a project, and the CLI, the API, the exporter and the
app's Export dialog all use it, so they agree:

- **Frame.** The main canvas, or an alternate format. "portrait" is the
  project's 9:16 frame: its portrait format, or the canvas itself when
  that's 9:16 (`tandem new --portrait`). The short preset asks for it, so
  on a landscape project without a portrait format it fails with an error
  that names `tandem short --apply`. `tandem short` refuses a 9:16 canvas,
  which is already the short.
- **Size.** A preset's `resolution` is the frame's short side, and the
  frame keeps its shape: YouTube 1080p is 1920x1080 on a landscape canvas,
  1080x1920 on a 9:16 one and 1080x1080 on a square; YouTube 4K of a
  1080x1920 canvas is 2160x3840. Sizes round to even numbers. An exact
  `width` and `height` win; with neither the frame keeps its size.
- **Upscales.** Allowed (YouTube serves a 4K upload at higher bitrates)
  but warned about, since they add no detail.
- **Bitrate.** A preset's rate is for a 16:9 frame of its class at up to
  30 fps. It follows the frame's area (1080x1080 gets 56%, 2560x1080 133%)
  and gets half as much again above 30 fps, as YouTube's table does.
  Presets without a resolution keep their numbers.
- **Default.** With no preset named, the frame decides: YouTube 1080p for
  a frame 1080 or less on its short side (1920x1080, 1080x1920, 1080x1080),
  YouTube 4K for anything bigger (3840x2160, and 3200x1800 or 5120x2880,
  scaled to 3840x2160).

| Preset | Codec | Short side | Bitrate (16:9, 30 fps) |
| --- | --- | --- | --- |
| youtube4k | HEVC | 2160 | 80 Mbps |
| youtube1080 | H.264 | 1080 | 20 Mbps |
| review | H.264 | 720 | 5 Mbps |
| short | H.264 | 1080, portrait frame | 20 Mbps |

The bitrates were checked against YouTube's recommended upload settings
in September 2026: 8 Mbps for 1080p and 35 to 45 for 4K at 24 to 30 fps,
12 and 53 to 68 at 48 to 60 fps, all for H.264, and 384 kbps AAC stereo.
20 Mbps is 2.5 times YouTube's 1080p rate, and HEVC at 80 is about as
generous for 4K (HEVC needs roughly a third fewer bits than H.264). That
headroom is for the speed-priority hardware encoder and YouTube's
re-encode, and it's what Mike's Filmora presets used ("Mike High" was
1080p H.264 at 20 Mbps, the 2026 4K preset HEVC at 80). What changed:
the high frame rate step and the area scaling come from YouTube's table,
and audio went from 256 to 320 kbps, the most Apple's AAC encoder takes at
48 kHz stereo (it refuses 384). The bug these rules fixed: a 1080x1920
project exported at the 4K preset's 80 Mbps (752 MB for 76 s), and
YouTube 1080p laid it out again as 1920x1080.

AAC overshoots the limited mix, so the limiter aims 0.5 dB under the
ceiling. On synthetic hits that keep the limiter busy, the file measured
0.1 to 0.4 dB over the mix at 320 kbps and up to 1.1 dB at 256 kbps; with
the margin it stays under -1 dBTP (`testTheAACFileStaysUnderTheCeiling`).
The workbench short's file measured -1.01 dBTP with ffmpeg before the
margin and -1.51 after, at -14.0 LUFS both times. The export reports the
loudness of the mix before AAC, so its true peak reads about -1.6 dBTP.

## Proxies

The viewer plays 1080p proxies (docs/MEDIA.md has how they're made);
paused stills, API frame grabs and export read the originals. Since proxy
version 3 a proxy has a keyframe every 15 frames with P-frames between, no
reordering, at quality 0.78.

Overlays and stickers with alpha get HEVC-with-alpha proxies, straight or
premultiplied as the source is, and the compositor reads them as BGRA like
the originals. Before, the viewer showed a black box (or the colour hidden
under straight alpha) behind any overlay bigger than 1080p while playing,
then the right picture once paused. `AlphaVideoTests` checks a ProRes 4444,
an HEVC and a QuickTime Animation overlay, each 2400x1350, through a frame
grab from the original and from the proxy and through the viewer's player.

Versions 1 and 2 were all keyframes, so every frame's compression noise was
new and crawled over still walls and screen text while playing, gone the
moment the player paused. A P-frame leaves a still area as it was. The costs
are a tick at each keyframe, where the noise changes all at once, and seeks
that decode from the keyframe before.

Measured on the demo footage (`ProxyRealMediaTests` pins these): a minute of
Mike's camera and of his screen recording through `ProxyJob`, and 150 frames
of still areas in it: the wall beside him, and the sidebar and code boxes of
the screen while only the pointer moves. Changes are the mean absolute
change of 8x8 block means (luma levels) from one frame to the next, into
keyframes and into the rest; the deviation is that of the block means over
the 5 s, the measure behind the choice of 0.6.

| Proxies | Wall: a frame | Wall: at keyframes | Wall: deviation | Sidebar: a frame / keyframes | Text: a frame / keyframes | Camera MB/min | Screen MB/min |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Original | 0.13 | 0.26, every 2 s | 0.33 | 0.013 / 0.075 | 0.004 / 0.040 | 104 | 5 (whole file) |
| All keyframes, 0.6 (version 2) | 0.45 | every frame is one | 0.50 | 0.113 | 0.044 | 105 | 92 |
| Every 15, 0.6 | 0.044 | 0.54 | 0.47 | 0.023 / 0.19 | 0.014 / 0.089 | 16 | 7 |
| Every 15, 0.75 | 0.056 | 0.35 | 0.36 | 0.007 / 0.085 | 0.002 / 0.030 | 67 | 11 |
| Every 15, 0.78 (version 3) | 0.067 | 0.31 | 0.35 | 0.007 / 0.070 | 0.003 / 0.030 | 95 | 13 |
| Every 15, 0.8 | 0.071 | 0.29 | 0.34 | 0.007 / 0.070 | 0.003 / 0.028 | 111 | 14 |
| Every 30, 0.8 | 0.065 | 0.32 | 0.34 | 0.004 / 0.081 | 0.001 / 0.024 | 103 | 9 |

- The crawl is gone: a still wall changes 0.067 a frame where it changed
  0.45, half as much as in the camera file itself, whose sensor noise the
  proxy mostly drops. Screen text changes less than in the original.
- The tick is about the camera's own. Its keyframes (every 2 s) change the
  wall by 0.26; the proxy's (twice a second) by 0.31. Over 32x32 blocks,
  where a change of brightness would show as pumping, the proxy's tick is
  0.12, against 0.14 at the camera's keyframes and 0.09 for its ordinary
  change from frame to frame. Fine detail doesn't breathe either: it drops
  9% into a proxy keyframe, where the camera's keyframes add 27%. On the
  screen the ticks are no bigger than the recording's own keyframes'. At
  quality 0.6 the tick was bigger than all-intra's change every frame,
  which is why the quality went up.
- Quality rounds in steps: 0.76 and 0.77 make the same file, as do 0.79 and
  0.8; 0.78 is the highest step no bigger than all-intra at 0.6. Over the
  whole demo (24 minutes each of camera and screen, and some b-roll) version
  3 proxies take 2.6 GB where version 2 took 4.0: 97 MB a minute of camera
  (was 105), 11 of screen (was 57). They build as fast: 3.7 s a minute of 4K
  camera, 2.3 of screen recording.
- A keyframe every 30 frames saves little (the camera at 0.8 is 105 MB a
  minute) and costs seeks: see below.

The viewer's random access, on the whole v14 edit (screen, camera PiP with
its cutout matte, b-roll) built from each set of proxies as the viewer builds
it: an exact `AVPlayer` seek of a paused player, timed until the frame
reaches the player's output, at 150 random frames, twice. Steps are the arrow
keys: a dozen frames forwards and two dozen back from 8 places. Drags ask
for a new time 60 times a second, as dragging the ruler does, and count the
frames that reach the output.

| Proxies | Seek p50 / p95 | A frame back p50 / p95 | A frame forward p95 | Dragging backwards, 1x / 4x |
| --- | --- | --- | --- | --- |
| All keyframes, 0.6 | 7.1 / 9.2 ms | 4.5 / 7.9 ms | 5.5 ms | 60 / 60 frames a second |
| Every 15, 0.78 | 11.5 / 15.8 ms | 9.3 / 14.2 ms | 5.8 ms | 60 / 60 |
| Every 30, 0.8 | 15.9 / 24.8 ms | 14.3 / 22.6 ms | 5.4 ms | 47 / 34 |
| The 4K originals | 45 / 146 ms | 31 / 190 ms | 11 ms | 30 / 3.5 |

(The last two rows are from an earlier run, in which all-intra was 6.2 /
8.3 ms.) A frame forward carries on decoding, so it costs the same; a frame
back decodes from the keyframe. Forward drags show every frame either way.
Playing at 1x and 8x and backwards (J: the composition can play in reverse)
shows as many frames a second with either proxy. A frame grab through proxies
(project icons) takes 35 ms at p50 against 33. `ProxyExactFrameTests` checks
that seeks, steps across keyframes both ways, and playing forwards and
backwards from a paused frame show the frame for their time. The whole-demo
comparison is `~/dev/me/tandem-research/proxy-gop/ProxyGOPExperiment.swift`,
kept out of the package, and `compare/` beside it has a side-by-side clip of
the wall (the original, all keyframes at 0.6, every 15 at 0.78).

## Random access

The frame at a time is always the last one at or before it: variable frame
rate recordings hold their frame through static gaps (up to 20 s in Mike's
screen recordings). AVFoundation gets that right on its own.

What it gets wrong is open-GOP HEVC that doesn't mark its keyframes. A CRA
keyframe's leading frames show just before it but decode after it,
referring back to the previous GOP, and a file says which keyframes are
CRAs with a `sync` sample group. record-it's files have one; copies
remuxed by ffmpeg (`-c copy`) lose it, like decision-models'
`edit/main-screen.mov` and `edit/main-camera.mov`. Seeking into those
leading frames (about 4% of that screen file) then:

- returns nothing to the compositor (black frame grabs, a black paused
  player: the bug the app hit at 404 s of v14),
- or repeats the previous clip's frame when a cut starts on them,
- or stalls an AVAssetReader for good when its first frame is one of them
  (a range export starting there never finished).

Decoding straight through from a little earlier gets them right, which is
why full exports were fine. So:

- `LeadingFrameMap` reads a file's sample tables (in 20 ms for a 24 minute
  recording) and lists the leading-frame windows, for HEVC with frame
  reordering, sync samples and no `sync` group. Other files get no map.
- A segment that starts inside a window goes into the composition from the
  window's keyframe; the frames before it are left out.
- `FrameRecovery` decodes a frame directly, reading from a second before
  (backing off to 4, 16 and 64 s if the start lands on undecodable frames
  too) and keeping the reader open so the next frames continue from it. The
  compositor uses it for frames left out, for any window frame in a grab,
  and whenever AVFoundation hands it no frame for a layer that should show.
- A range export starting inside a window reads from a moment before it and
  drops what comes before the range (the frame showing at the start goes in
  at the start).
- If AVFoundation stalls anyway, the export gives up after two minutes with
  no frames ("reading the timeline stalled") rather than hanging, and
  cancel wakes it.

Filmora shows the nearest frame of variable frame rate footage, Tandem the
last one at or before the time, so mid-scroll the two can be a frame apart.

## Measured (M5 Pro, release build)

| Job | Speed |
| --- | --- |
| 60 s 4K: screen + 50% cutout PiP camera with grade and shadow, voice, music, HEVC 80 Mbps | 15.8 s, 3.8x real time |
| Same at 30 Mbps | 3.7x |
| 60 s range of the imported v14 edit (494 clips) | 4.4x |
| The whole v14 edit, 11 min 7 s, HEVC 80 Mbps | 156 s, 4.3x, -14.09 LUFS, -1.1 dBTP (loudness passes about 5% of it) |
| Frame grab, 4K composite (first grab builds the composition) | 0.05 to 0.4 s |
| Frame grab that decodes leading frames directly | 0.1 to 0.25 s |
| 20 s of a 4K still with a title and shadow | 4.0x |
| A 3.2 s section card alone, 4K HEVC 80 Mbps | 1.1 s, 2.9x (a plain solid: 0.9 s) |

The spike's plain composite managed about 3.5x; the encoder is the limit.

## Gotchas

- Core Image (macOS 26) runs the first-used kernel's code for every
  stitchable kernel compiled in the same `kernels(withMetalString:)` call,
  and `destination` coordinates come back as zero when a kernel has other
  arguments. Each kernel is compiled on its own and the vignette uses a
  generated mask. There's a regression test.
- `CGColor(red:green:blue:alpha:)` is Generic RGB: drawing it into an sRGB
  context colour-matches it. Use `CGColor(srgbRed:...)`.
- Setting `colorPrimaries`, `colorTransferFunction` or `colorYCbCrMatrix` on
  a video composition with a custom compositor re-tags the source frames
  without converting them. And a pixel buffer tagged BT.709 with no
  `CGColorSpace` attachment shows lighter in AVPlayerLayer than the same
  pixels as a CGImage. `PlaybackMatchTests` covers both.
- A `FrameRenderer` keeps the composition it first built. The viewer makes
  a new one after every rebuild, since mattes and proxies arrive later
  than edits.
- AVAssetWriter interleaves inputs: pushing all video before any audio
  stalls. Pull each input with `requestMediaDataWhenReady`.
- AVAudioMix volume ramps lag. Measured on a constant source in October
  2026 (macOS 26), a track's volume moves at most 1.0 (linear) every
  25 ms, however short the ramp: 1 to 4 takes 75 ms, 1 to 30 takes 724 ms.
  Reading or playing from part way starts each track at about the volume
  it had 0.3 s earlier and moves it from there at the same pace. So
  Tandem never ramps volume; `GainTap` applies the gain to the samples.
- `MTAudioProcessingTap` quirks, measured the same way. A pre-effects
  tap's time stamps are exact to the sample in `AVAssetReaderAudioMixOutput`
  and in AVPlayer at rates 0.5, 1 and 2; within a call, a segment at speed
  s advances the timeline 1 / (48000 s) a sample, and the call's
  `duration` is wrong for speed changes. A post-effects tap runs 4096
  samples (85 ms) behind in the player and drifts at other rates. AVPlayer's
  first call has no time and is silent. Neither kind sees AVAudioMix
  volume, which comes after both. A tapped track whose files change
  format (AAC to PCM, mono to stereo, 16-bit to float) stalls the reader
  or reads the wrong number of samples. And taps cost AVPlayer at the
  start: after a seek or a rebuild, play took about 0.5 s to start
  instead of 0.15 s, tracks after the first joined about 0.1 s late, and
  resuming from a pause took 0.1 s instead of 0.02 s. That's why the
  viewer reads its sound ahead (Viewer sound). Readers with taps run
  about 1.6 s slower per 10 minutes of three-track audio (0.5 s of it
  CPU).
- Nothing cheap shortens that start, measured in October 2026. A tapped
  track's audio goes through the taps in real time, about 0.4 s ahead
  of what you hear, and only once playing starts, so AVPlayer either
  waits for it or loses it. `preroll(atRate:)` doesn't run the taps (it
  finishes in a millisecond); `playImmediately(atRate:)`,
  `automaticallyWaitsToMinimizeStalling` and varispeed change nothing.
  Scheduling the start ahead while paused (`setRate(_:time:atHostTime:)`
  with a far-off host time, then now on play) starts the clock in
  0.17 s, but the first 0.15 to 0.6 s of every track is silent, AVPlayer
  reports itself playing meanwhile, and it costs about 0.8% of a core.
  The fix renders the mix ahead of time: the viewer feeds an
  `AVSampleBufferAudioRenderer` from the tapped reader (Viewer sound).
- `AVPlayer.isMuted` stops AVPlayer decoding sound after about a second,
  so a tap sees silence from then on. Measure with `volume = 0`.
- AVPlayer plays these compositions backwards (`canPlayReverse` is true
  for H.264 and for HEVC proxies), its sound reversed, and keeps the
  pitch at 2x, 4x and 8x.
- `AVSampleBufferRenderSynchronizer.setRate` holds up its caller for 30
  to 40 ms when it stops or changes speed while playing (7 ms to start,
  under 1 ms to resume), measured October 2026. AVPlayer's rate calls
  take under 0.3 ms. `ViewerAudio` calls it on a queue of its own.
- Left to start by itself, the synchronizer begins 0.12 to 0.13 s after
  it's asked with the output device running, and 0.2 s when the device
  has to wake (it's idle about 2.5 s after the last sound). AVPlayer,
  before the gain taps, started in 0.14 to 0.17 s with the device awake
  and 0.21 s from idle, and kept the device running for about 35 s after
  a pause. `AudioDeviceStart(device, nil)` keeps it running with no
  IOProc, and while it runs coreaudiod holds a
  `PreventUserIdleSystemSleep` assertion.
- `AVSampleBufferAudioRenderer.flush(fromSourceTime:)` only works about a
  second ahead (0.5 s fails), so an edit can't be spliced into what's
  queued any sooner; the viewer stops and starts again from the playhead.
- While paused the renderer takes about a second of sound and stops
  asking; at 8x it keeps about 7 s queued. A feed that has run out must
  `stopRequestingMediaData`, or the renderer calls it over and over.
- `AVPlayer.setRate(0, time:atHostTime:)` ignores the time and the host
  time and just stops, about where it is. Pausing the viewer reads where
  the picture stopped instead.
- The synchronizer's timebase runs on the host clock until it has sound,
  then on the default output device's clock. A picture-only player item
  is on that device's clock too by default; the viewer sets it anyway
  (`CMAudioDeviceClockCreate`, `AVPlayer.sourceClock`), so the two can't
  drift.
- Calling `cancelReading()` on an AVAssetReader while another thread is in
  `copyNextSampleBuffer()`, or reading an output after its reader has been
  released, crashes. Export cancel is a flag: the encoder feed and muxers
  stop at the next sample, the feed thread (which holds the reader) is
  joined, and only then is the reader cancelled.

## Tests

`swift test --package-path .` runs the render tests in about
8 s (the whole package in about 40 s):
pure maths and plan tests, golden-pixel compositor tests with stand-in
frames, end-to-end grabs and exports of synthetic movies (frame-number
stripes, a flash and a beep, tones with clicks). `GainAcrossCutsTests`
read every gain case the way export does and the way the viewer does.
`ViewerAudioTests` check the viewer's sound: queued from the playhead to
the sample with every track in it, exactly what export reads, reversed
backwards, and, with an output device and on a Mac, a flash and a beep
landing together and the picture and sound starting together and
staying within a millisecond (muted). The app's `EditorBehaviourTests`
play real sound through the editor: start times, pause, a seek and an
edit while playing, J K L and scrubbing. Real footage is opt-in:

```
TANDEM_REAL_MEDIA=1 swift test -c release -Xswiftc -enable-testing \
    --package-path . --filter RealMediaTests
```

It reads the decision-models folder and the imported v14 project (never
writing there) and writes to `/private/tmp/claude-501/tandem-render/bench`.
`RealColourTests` measures the demo project's player, stills, export and
camera file, `ProxyNoiseTests` how much proxies flicker at each quality,
and `ProxyRealMediaTests` today's proxies against all-intra ones: flicker,
keyframe ticks, size, build speed and seek times (all with
`TANDEM_REAL_MEDIA=1`). `ColourOnScreenTests` shows the
player and a still side by side in a window and reads them back from a
screen capture (`TANDEM_SCREEN=1`).
