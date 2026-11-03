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

Pad the range a few frames either side: the copy is cut on whole frames,
and hiding a moment too long is better than showing one frame. Find when
the thing appears with `tandem frame` at the clip's times. If you time it
by diffing the file's frames with ffmpeg instead, add the video stream's
`start_time` ([reading.md](reading.md#source-times-and-ffmpeg)): Record It's
screen files have started as late as 0.77 s, and a time 0.77 s early puts
the redaction on before the QR code shows and takes it off while it's
still there.

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
