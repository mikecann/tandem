# Layout, zooms and colour

Recipes for the PiP camera layout, zooming into the screen recording, hiding part of the picture, and grading the camera take (the Colour tab's sections and how colour wheels work).

## Set the PiP layout

Put the camera in the bottom-right corner with the cutout and shadow, the
way Mike does:

```json
{"label": "Camera to PiP", "commands": [
  {"applyLayout": {"clipIDs": ["clip_cam1", "clip_cam2"], "preset": "pipRight"}}
]}
```

`full` puts it back to full frame for a talking-head section, `pipLeft`
moves it to the other corner when the screen has something important
bottom right (and flips the camera, so Mike faces into the frame rather
than off its edge), and `split` puts camera and screen side by side. To fine-tune
the corner, patch the transform:
`{"updateClip": {"clipID": "clip_cam1", "patch": {"video": {"transform": {"position": {"x": 0.86, "y": 0.76}}}}}}`.
`"flipped": true` in the transform mirrors any clip left to right about its
centre; the layout presets set it and clear it for the camera.

## Zoom into the screen recording

Zoom the screen clip into the top-right quarter at 1:12 and back out at
1:20:

```json
{"label": "Zoom on the settings panel", "commands": [
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0.5, "y": 0, "width": 0.5, "height": 0.5}, "at": 72, "duration": 0.5}},
  {"zoomToRegion": {"clipID": "clip_scr2", "rect": {"x": 0, "y": 0, "width": 1, "height": 1}, "at": 80, "duration": 0.5}}
]}
```

`tandem check` notes a zoom past three times the picture's own pixels as
soft.

Zooms into screen recordings stay sharp in the export without anything
from you. Pictures scaled up are resampled with Lanczos rather than
bilinear (Core Image's own filter only if the kernel can't load), and
where a zoom draws a screen recording (role `screen`) at 1.3 times its own
pixels or more at the export's size, the export first makes a
twice-the-size copy of that stretch with an upscaling model (Real-ESRGAN's
realesr-animevideov3, on the Mac) and plays it from the copy. If a copy
can't be made, that stretch plays from the original and the export's
warnings say so. A 3200 px Retina recording zoomed 1.8x into a 4K frame is 2.16x, so
it gets one. The first export with new zooms spends the first half of its
progress bar making them (about 3 s per second of zoomed screen recording
on an M5), and the copies are cached in `.tandem/cache/upscale`, so later
exports reuse them, trims included. A 1080p review render draws the same
zoom at half the scale and doesn't wait for copies. The viewer and
`tandem frame` show the original, Lanczos only.

## Hide part of the picture

A QR code, an email column, an API key or a phone's notifications that
shouldn't go out: `redact` pixelates (or blurs) a rectangle of the
recording over a stretch of the timeline. The rectangle is fractions of
the source frame from its top left, as `zoomToRegion` takes, so measure it
on the file's own picture (a `tandem frame` where the clip fills the frame,
or a frame of the file), not where a PiP sits on the canvas; it then holds
wherever the clip is placed, PiP or zoomed.

```json
{"label": "Hide the QR code", "commands": [
  {"redact": {"mediaID": "med_phone", "range": {"start": 1134.1, "duration": 2.8},
              "rect": {"x": 0.05, "y": 0.22, "width": 0.9, "height": 0.63}, "size": 40, "name": "QR code"}}
]}
```

Each clip of the file there gets a copy of itself on a `cut` track right
above its own, "Privacy (Phone)", cropped to the region, with the same
times, placement and animation, so it follows a phone shown as a PiP. The
take is cut at the range's edges and every copy is linked to the piece it
hides, so ripple cuts, trims, slips and moves keep it on it, and it goes
on and off with an angle that `showAngle` switches. `check` doesn't count
it as the same shot twice. Give `trackID` instead of `mediaID` to hide
part of whatever's on a track. Two regions at once stack on "Privacy
(Screen) 2". To undo one, remove its copies (the clips named
"Privacy: ...") with `removeClips` and `"includeLinked": false`: they're
linked to the take, so the default takes the screen, camera and voice
with them.

Layouts move the copies with their picture: `applyLayout`,
`setFormatLayout`, `tandem short` (in place or `--copy`) and `adoptFormat`
put each copy where the clip it hides goes, cut to its region within what
that clip shows there, whichever clips you name. A layout preset or slot
asked for a copy itself does the same, so a blur never fills the frame or
the top half of a short. A locked privacy track stops a layout that would
leave its copies behind: unlock it first.

The project remembers the selected source regions independently of their
current copies. Ordinary crop, transform, motion, keyframe, direct timing
and hold edits keep the copies aligned. A later edit that would expose a
protected source frame refuses the entire batch: this includes neighbour
trims/slips, unsafe rolls/slides, track transfers and locked blades. Even a
cut that removes every current copy retains the source intent, so inserting
those frames again must still cover them. Changing a protected file's
picture delay also refuses.

A timing edit to a copy cannot release its protected tail, including an
animated blur. Adding another effect keeps the active privacy effect's
identity; removing it uses another effective blur or pixelate if one remains.
Clearing the copy's whole `video` object refuses rather than clear ownership.
Repointing a privacy copy to different content also refuses; redact the other
source to create its own request. Stills do not need a video flag to be
redacted. A one-pixel mosaic is ineffective, so pixelate size must be above1
(blur radius above0).
An automatic privacy fix needs source evidence from the actual composed
frame. An alpha-capable or unknown video format stays a finding to inspect,
even when its project entry says it has no alpha. A loaded video that fails
to supply a frame cannot take attribution from the picture visible below it.
If a replacement file's rendered dimensions differ from its saved dimensions,
the scan retains findings without an automatic fix until the media is refreshed.
Privacy copies need their own tracks: mixing them with ordinary footage
refuses the edit, so that footage remains available to redact and scan.
Naming an ordinary track Privacy does not give it this role.

Fractional source cuts retain the whole decoded source frames they show.
The renderer reads actual presentation timestamps, including isolated dropped
frames in recordings still classified as constant-rate. If that table cannot
be read, it conceals the region throughout the file instead of guessing.
For variable-rate files, the nominal frame rate cannot identify every sample
a freeze can repeat. The renderer therefore conceals each protected region
throughout that source file. This can hide the region outside the selected
timeline range too; convert and probe a constant-rate file before redaction
when precise source timing is needed. Later edits still require coverage
where the recorded source selection applies. Every variable-rate occurrence
also receives the file-wide concealment, including freezes outside that selection.

Templates cannot introduce privacy-copy metadata. Insert their ordinary
pictures and run `redact` afterwards; a saved segment containing privacy
copies refuses rather than import unverified ownership of protected frames.

The renderer obscures the source region before effects, placement and
transition motion or mixing, including transition handles. A still image
has one source frame at every time. Protection matches a file's saved
identity as well as its media ID, so another reference to the same file
cannot evade it. Blur strength is retained in source pixels through later
zooms. Renaming a privacy track keeps its identity.

Switching a copy or its last effective privacy effect off, hiding its track, or explicitly removing
it relinquishes that copy's selected source region. Blading partitions that
selection; joining combines it again. Ordinary cuts that happen to remove
the copy do not relinquish the source intent. Undo restores the whole edit,
including its protection. Older projects acquire this intent on load.
Old copies with disabled or removed effects keep their identity too, so they
stay undrawn until an effect is restored. A copy deliberately disabled stays
off when its picture is hidden and shown again or the camera angle changes,
including after reload. An inactive copy on a locked track does not block
picture transforms or layout changes.
Removing or editing an already inactive copy cannot relinquish another
copy's retained protection. Separate redaction requests retain separate
ownership even over the same pixels; a later copy cannot turn off an older
request that a cut retained. A new redaction uses a visible privacy track.
Editing a copy's speed or source start cannot claim its request's cut-away
frames. Those frames return to its controls when its linked picture shows
them again, including after a trim is extended or a picture is slipped.
A copy keeps its picture partners when links are regrouped. Assigning it
to another picture refuses; create that picture's own redaction. An old
ambiguous group needs its original owner established before source edits.
A blur control acts on the picture's source selection at that command,
including within a batch.
Strengthening a blur keeps its recorded source timing and all earlier file
identities, including an offline original after relinking. A locked privacy
copy cannot be rewritten when adopting a format, even when unlinked or off;
unlock the track first. Locked tracks cannot be reordered.
Originless policies from unreleased development versions retain separate
historical protection: their old merged rows cannot prove who owns them.
Disabling a surviving copy can refuse if it would expose that history.
Released schema1/2 projects acquire ordinary ownership when loaded.
At a file's opening, the recovery decoder can hold a later frame within
250 ms of the track start. Protection covers that possible held frame too,
which can conceal an opening region earlier than the selected time.

Turning a copy's blur off (Mike's "Turn off blur" in the inspector), or
removing it, leaves the copy hiding nothing, so it isn't drawn: drawn,
it's the same footage over itself with a faint seam along its crop. Turn
it back on and it hides the region again. `check` never counts a privacy
copy as the same shot twice, blur on or off.

The edges are where you ask, to the frame: `redact` never runs a copy
past them to a clip's edge (once it ran on by up to half a second, and
blurred the next window as it opened). An edge less than a frame from a
clip's edge goes to it, and a clip the range only grazes by less than a
frame gets no copy (with a warning naming it), so no sliver is left on
either track. Elsewhere the
take is cut where asked; that's a through-edit, which plays straight on,
and `check` doesn't count a privacy copy's edges as cuts in the take.

Pad the range a frame or two where the picture under it carries on: the
copy is cut on whole frames, and hiding a moment too long is better than
showing one frame. Where the picture changes (a new window opens), end it
on the frame the new one shows, not past it. Find when the thing appears
with `tandem frame` at the clip's times, or let `tandem check --privacy`
find it (below). If you time it
by diffing the file's frames with ffmpeg instead, add the video stream's
`start_time` ([reading.md](reading.md#source-times-and-ffmpeg)): Record It's
screen files have started as late as 0.77 s, and a time 0.77 s early puts
the redaction on before the QR code shows and takes it off while it's
still there.

## Find private text before export

A sweep by eye misses things. On the Threadbear launch video it missed a
thread's answer listing Mike's projects (personal errands, travel, an
internal plan) at three places, another person's quotes
waiting for his OK, and lines scrolling through a strip above a fixed
blur. `tandem check --privacy` reads the video as export renders it, a
frame at the output frame rate, with Vision on the Mac, and flags what looks
private. Run it on the whole video before every export:

```
tandem check --privacy
```

Recognised private-looking text stays a finding even where a title contains
the same words. A title's transparent padding cannot prove where OCR's glyphs
came from. Public contact details you authored may therefore need review too.

Each `privateText` problem has its edges to the frame, the file the text
is in, what was read (`crypto ("wallet"); travel plans ("flights")`)
and, when the source is known, a `redact` blurring what was flagged in that file's frame:

```
04:58.700-05:04.067  Private text on screen.mov: crypto ("wallet"); travel plans ("flights") ...
    hide it: tandem apply --label "Blur private text" '{"redact": {...}}'
```

Look at a frame of each before applying it. The rectangle covers only the
lines that matched, and the lines round them are often as private (the
rest of the answer, the whole card), so widen it to the block. Apply them
one at a time, never as a batch: a false alarm (a price in a tutorial, a
name that's public) should stay sharp.

`readableText` notes are every stretch with 40 or more words readable a
frame, flagged or not. Look through each (`tandem frames` across it): the
rules can't know that a plan is internal, a quote is someone else's, or a
list of projects is private. A title or caption is left out only when the
read text matches its words and drawn position. Recognised private text is
flagged even when its source has a blur effect. Text in a transition lists
its possible contributors, with no automatic redaction. Overlapping cutouts,
mixed or unknown transparency, and translucent titles can also leave the
source uncertain. Those findings still need inspection and have no automatic
redaction. Adjustment layers and graphics outside the text do not hide its
source. Missing frames or failed OCR stop the scan
with an error, so they cannot produce a clean result. The reader uses
original media and only reuses OCR for byte-identical rendered frames.
Source attribution checks each rendered media layer over the whole text
rectangle, after filtering and scaling. Downscaled 4K, Shorts and PiP can
keep their source fixes; an unrelated still does not invalidate the frame.
Mixed pixels or unknown source geometry still require manual inspection.
Recovery reads start on the output frame grid. A nearby frame across a cut
cannot stand in for the one requested.
It reads the main layout; a format with its own layout
(the portrait Short `tandem short` lays out) can show text the main one
crops off, so scan each one too, in its own frame:

```
tandem check --privacy --format portrait
```

Without `--format`, a project with formats gets a warning naming them. A
Short made with `tandem short --copy` is a 9:16 project of its own, with
no format: scan it with plain `--privacy`, in that project.
The redacts it gives are in the file's frame either way, and a redact
covers every format.

Reading every output frame from original media takes longer than the old
half-second sweep. Re-run it after blurring until every flag left is one
you've looked at. An earlier "leave the blurs off for now" isn't a sign-off
on what shows.

## Grade the camera take

Mike grades a camera take once, on the file's look (`MediaItem.look`), so
every clip from it gets the same grade; the Colour tab calls that the whole
take. A clip's own colour effects go on top of it, for one shot that needs
more, and they can animate like any effect parameter
(`video.effects.<effectID>.<param>`). The look can't.

The Colour tab shows a grade as fixed sections in the order they apply, each
backed by one effect (`tandem effects` has each parameter's range and default):

| Section | Effect | Parameters |
| --- | --- | --- |
| LUT | `lut` | `path`, `intensity` |
| Light | `colorAdjust` | `exposure` (stops), `contrast`, `highlights`, `shadows`, `blackLevel` |
| Colour | `colorAdjust` | `temperature`, `tint`, `saturation`, `vibrance` |
| Colour wheels | `colorWheels` | `shadows`, `midtones` and `highlights`, each with `Hue`, `Amount` and `Brightness` (`shadowsHue`...) |
| Colour mixer | `hsl` | `red`, `orange`, `yellow`, `green`, `aqua`, `blue`, `purple` and `magenta`, each with `Hue`, `Saturation` and `Luminance` (`redSaturation`...) |
| Vignette | `vignette` | `amount`, `size`, `feather` |
| Sharpen | `sharpen` | `amount` |

`look` applies in list order, so put a `lut` first: it turns log footage into
a normal picture, and everything after it then works on what's on screen. The
tab adds new effects that way. A grade with effects before its LUT (a Filmora
import) keeps its order, and the LUT section says which ones.

Write a grade the way the tab reads it: one effect of each type, with the
Light and Colour values in the same `colorAdjust`, as Filmora imports have
them. A section switched off is its effect turned off, so when Mike turns
Light off while Colour has values the tab splits them into two
`colorAdjust` effects, Light's first; a section that's reset loses its
effect (or, when it shares one, its values). Anything the tab can't place,
like a second `hsl`, shows after the sections as it is.

`colorWheels` grades like lift, gamma and gain: the shadows wheel moves
black and leaves white alone, highlights the other way round, and midtones
leaves both. A wheel's hue says which colour it pushes towards (0 red, 60
yellow, 120 green, 180 cyan, 240 blue, 300 magenta, the same degrees as the
mixer's ranges) and its amount how far: 10 to 25 is a normal grade, 100 is
strong, and the hue does nothing while the amount is 0. A wheel changes the
colour of its range, not its brightness; that's what the wheel's brightness
(-100 to 100) is for. Teal shadows and warm highlights, on top of Mike's
usual grade:

```json
{"label": "Grade the camera", "commands": [
  {"updateMedia": {"mediaID": "med_camera", "patch": {"look": [
    {"type": "colorAdjust", "params": {"contrast": 25, "blackLevel": -7, "temperature": -3}},
    {"type": "colorWheels", "params": {"shadowsHue": 200, "shadowsAmount": 12, "highlightsHue": 35, "highlightsAmount": 10}},
    {"type": "hsl", "params": {"redSaturation": -8, "orangeSaturation": -8}},
    {"type": "vignette", "params": {"amount": -30}},
    {"type": "sharpen", "params": {"amount": 3}}
  ]}}}
]}
```

A look reaches every clip of its file, but only the ones on screen show it.
Check what's showing before grading a shot: a clip marked `disabled` in
`tandem timeline` isn't, however high its track, nor is one under a full-frame
clip. With linked angles, grade the file of the angle that's on.

`look` is replaced as a whole, so read it first (`tandem timeline --json`,
under `media`) and send it back with your change. Check the result with
`tandem frame`.
