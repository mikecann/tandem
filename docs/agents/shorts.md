# Shorts and captions

Recipes for making a 9:16 short (cut from a landscape video, or portrait from the start) and adding word-by-word captions.

## Make a short

A short is 1080x1920, and there are two ways to make one.
`tandem export --preset short` renders either.

**Cut from a landscape video.** Make the short a project of its own,
beside the long one:

```bash
tandem short --copy                            # the plan, nothing written
tandem short --copy --apply                    # writes "<Name> Short.tandem"
tandem app "Decision Models Short.tandem"      # cut it down there
tandem captions --apply --project "Decision Models Short.tandem"
tandem export --preset short --project "Decision Models Short.tandem"
```

Screen, B-roll and graphics fill the top half, the camera fills the bottom
half with its background, and full-frame camera moments fill the frame.
Then the copy's canvas becomes 1080x1920 (`adoptFormat`), so the app shows
the short portrait, as it exports. The long video's project isn't edited,
and an existing file is never replaced (`-o` names the copy).

Without `--copy`, `tandem short --apply` adds the short to the same
project as an alternate output format instead, so every edit shows up in
both videos (`setFormatLayout` places each clip in it). The app still shows
the landscape canvas then; look at the short with `tandem frame 0:30
--format portrait -o /tmp/short.png`.

**Made portrait from the start**, for a short that isn't cut from a long
video (phone footage, photos). The canvas is the short, so there's no
portrait format and no `tandem short` step (it refuses, as there's
nothing to lay out):

```bash
tandem new "Workbench.tandem" --portrait       # a 1080x1920 canvas
tandem captions --apply
tandem frame 0:30 -o /tmp/short.png
tandem export --preset short                   # exports/Workbench r<revision>.mp4
```

The `fill` layout makes a landscape photo or clip cover the frame, and
`addMotion` gives a still a slow zoom or pan (apply `fill` first). Presets
keep the canvas's shape, so plain `tandem export` and `--preset
youtube1080` make the same 1080x1920 H.264 at 20 Mbps as `--preset short`,
and `--preset youtube4k` upscales to 2160x3840 with a warning. Every export
prints the size, codec and bitrate it used; `tandem help export` has the
presets.

## Caption a short

```bash
tandem captions --from 0:00 --to 1:30                 # the plan, nothing changes
tandem captions --from 0:00 --to 1:30 --apply
tandem frame 0:12 -o /tmp/caption.png --format portrait
```

Captions come from the transcripts: up to three words at a time
(`--max-words`), breaking at sentence ends and pauses, with the word being
spoken highlighted (the `caption` title preset, Tilt Warp with a black
outline, which is what Mike's shorts use). They go on a "Captions" video
track that follows ripple edits, so tightening pauses afterwards keeps them
in sync. `--y` moves them: the default 0.42 sits between the screen and the
camera in a 9:16 short; use about 0.85 for landscape. Run it again over the
same range to redo them (it overwrites what's on the track there). After
cutting pauses or stumbles, a word shows once, on the side of the cut where
most of it plays, and words that were cut out don't show.

Each caption stores the preset, its words and only what you passed (`--y`
is its position), so the preset decides the look and a later change to it
reaches every caption. Tilt Warp doesn't come with macOS: the first time
captions are applied, Tandem installs it from Fontsource into the project's
`assets/font/` (the output says so), and the app picks it up. If that can't
happen (offline), the captions still go in and the output says what to run.
To restyle them, patch the captions' `style` (see
[Add a title](broll-and-titles.md#add-a-title)).

### Plain captions

```bash
tandem captions --style plain --max-words 1 --size 150 --y 0.82 --apply
```

`--style plain` uses the `plainCaption` preset: white Helvetica Neue bold
with a soft shadow, no outline and no spoken-word highlight. It's the look
Databased's old editor used, one big word at a time. `--color #RRGGBB`,
`--font <family>` and `--size <points>` go on each caption over either
style, so `--style caption --color #FFFFFF` keeps Tilt Warp and the yellow
highlight with white words. The highlight comes from the preset, not the
colour: to drop it from captions already on the timeline, set their
`content.text.preset` to `plainCaption` rather than patching the colour.
