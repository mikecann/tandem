# Assets, credits and segments

The asset library (music, sound effects, stickers, icons, logos, fonts and stock footage), Mike's shared library, the description credits, and saving and reusing segments like an intro or outro. `docs/ASSETS.md` explains the sources and licences.

## The asset library

Music, sound effects, stickers, icons, logos, fonts and stock footage come
from Mike's asset library, one per user at
`~/Library/Application Support/Tandem/Assets/`, shared with the app's
browser. Every asset records its licence, and every use in a project is
recorded, which is what the description credits are built from.

Mike's own reusable things live in his **shared library**, the folder
`~/Movies/Tandem Library` (Stickers, Graphics, Sound effects, Music, Looks,
Fonts, Segments). Its files are the `shared` source, with IDs that are
their path in the folder: `shared:Stickers/Star.mov`, `shared:Sound
effects/Whoosh.wav`. Unlike every other source, a shared asset isn't copied
into the project when it's used: the project refers to the library's file
where it is (absolute path), so a sticker Mike improves in the library
improves every video that uses it. Archiving the project copies those files
in (see [Archive a finished video](operations-and-troubleshooting.md#archive-a-finished-video)).
`tandem assets search --provider shared` lists them. The app watches the
folder, and the CLI and MCP look at it again before they search (only
changed files are read), so a file dropped in is found straight away.

- `tandem assets providers` (MCP `assets_providers`) lists the sources and
  whether each works now, with what to fix: a missing key, or an ElevenLabs
  key without the `sound_generation` permission (music still works then).
- `tandem assets search "whoosh" --kind sfx` (`assets_search`) searches the
  library's catalogue: import folders, downloaded and generated assets, the
  starter set and recent provider results. `--online` asks the providers
  too (Noto emoji, Iconify, SVGL logos and Fontsource, plus Pexels, Pixabay
  and Freesound when they have keys), and `--provider noto` limits it to one
  source. Kinds are music, sfx, sticker, overlay, video, image, font, icon,
  logo, lut, title and transition. Asset IDs look like `noto:1f680`,
  `svgl:convex` or `import:sfx-3fa2c1/Whoosh_03.wav`.
- `tandem assets use <id>` (`assets_use`) downloads and normalises the asset
  if needed, copies it into the project's `assets/<kind>/` folder (a
  `shared:` asset is used where it is instead, and the result says
  `referencedInPlace`), records the use and adds it to the project's media.
  With `--at 1:23` it's also placed on the track for its kind: sound effects
  on SFX at -15 dB, music on Music at -31 dB with a 2 s fade out, stickers,
  icons and logos on Graphics, stock video on B-roll. Stickers sit at the
  bottom of the frame (see [placeMedia](edit-commands.md#placemedia));
  `--anchor topRight` puts a picture somewhere else and `--pop` pops it in
  and out. A sticker stays up for at least 2 s, and `--duration` longer
  than its file holds its last frame. If the folder watcher added the
  copied file first, `use` places that media item and gives it the
  asset's role, and the output names the track the clip really went on. The edit goes through the app when the app has the project
  open, as one undo step under your name.
- Fonts are installed instead of placed, into the project's `assets/font/`
  (a shared library font stays in the library, where every render finds
  it, until the project is archived); use their name in a title's style.
  When the app has the project open it has the font straight away too (the
  output says so), with no restart. A `fontsource:<name>` ID works without
  searching first, so the fix a missing-font warning gives can be run as it
  is.
- `tandem assets fetch <id>` downloads and normalises without using it.
- `tandem assets show <id>` (`assets_show`) prints what the library knows
  about an asset without downloading anything: name, kind, provider and
  model, the prompt a generated one was made from, duration, BPM and key,
  loudness, licence, holder and credit line, and the file it plays from
  (and the original). Use it instead of reading the `meta.json` files in
  the library folder; `--json` has the whole record.
- `tandem assets credits` (`assets_credits`) prints the credits block for
  the video description ([below](#credits-for-the-description)).
- `tandem assets generate sfx "short airy whoosh" --duration 1`
  (`assets_generate`) makes a sound effect (0.5 to 30 s) or music cue (3 to
  600 s) with ElevenLabs. Each take is a paid request, so make one unless
  asked for more; `--variations 3` makes three.
- `tandem assets install-starter` puts the starter set (about 40 animated
  emoji, 30 icons and the tech logos Mike uses) in the catalogue. Each one
  downloads the first time it's used.

`$TANDEM_ASSETS_ROOT` moves the library, and `TANDEM_ASSETS_OFFLINE=1`
keeps it off the network and out of the Keychain (for tests, or a flight).
`$TANDEM_LIBRARY` moves the shared library for one command; with
`$TANDEM_ASSETS_ROOT` set and no `$TANDEM_LIBRARY`, the shared library is
`Tandem Library` inside that root, so tests never touch the real one.

## Credits for the description

```bash
tandem assets credits
```

prints the block to paste into the YouTube description, for example:

```
Paste into the description:

Credits
Animated Noto Emoji by Google, CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)

Before publishing:
  - No licence on record for "Glitch Hit 02". Add a tandem-licence.json to their import folder, or replace them.
```

It counts the assets still in the project's media, and any a clip names in
an `asset:<id>` tag (a saved segment's clips carry them for the library
assets they came from), so run it last, after removing media the cut no
longer uses. Sort out everything under "Before publishing" first: assets
with no licence on record, credits without a credit line, subscriptions
that must stay active. `--optional` adds courtesy credits nobody requires
(Pexels creators).

## Reuse an intro, an outro or a call to action (segments)

A segment is a bit of timeline saved to reuse: a group of clips with their
offsets, settings, effects and keyframes, saved into the shared library's
`Segments/<name>/` with copies of the files they play. Mike saves them from
the timeline (Timeline > Save selection as segment…); agents do the same
from clip IDs or a range:

```bash
tandem timeline --from 0:00 --to 0:08          # find the intro's clips
tandem segments save "Intro" --clips clip_card,clip_title,clip_whoosh --field clip_title=Title
tandem segments save "Outro" --from 10:02 --to 10:15    # every clip wholly inside
tandem segments list
```

`--clips` takes exactly those clips (a linked partner isn't added, so name
the camera's sound too if it should come). `--field clip=Label` makes a
title's words a field: they're asked for on insert, and the words it has now
are the default. A `{{key}}` already in a title is a field too.
Transitions come along when every clip they join is saved: a dissolve
between two of the clips, a fade at one's head or tail. Saving under a name
that's taken fails unless `--replace`. Projects the old version went into
play its files from the library, so the new version keeps every file only
the old one had, and the rest of the old one goes to the Trash.

Then put one on the timeline, as one undo step:

```bash
tandem segments insert "Intro" --at 0 --value title="DECISION MODELS"
tandem segments insert "Like and subscribe" --at 4:12 --mode overwrite
```

Each clip goes on the track with the same name and kind (made if the
project hasn't one), at the same offset, linked to the rest. The segment's
files are added to the project's media where they are in the library (no
copy), and inserting again reuses them; archiving the project copies them
in. `--mode` is `place` (the default: fails where a track is taken),
`overwrite` or `insert` (pushes later clips right). In MCP:
`segments_insert {"name": "Intro", "at": 0, "values": {"title": "..."}}`.

On disk a segment is plain JSON beside its files:

```
Tandem Library/Segments/Intro/
  segment.json      {"version": 1, "name": "Intro", "template": {...}, "media": [...], "savedFrom": "Decision Models", "notes": []}
  card.mov          the files its clips play, named as they were
  whoosh.wav
  warm.cube         and the looks they use
```

`template` is an [`insertTemplate`](edit-commands.md#inserttemplate)
template whose `mediaPath`s and LUT paths are relative to the folder;
`media` holds the media items for those files.
