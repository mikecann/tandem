---
name: tandem
description: Edit Mike's videos in Tandem, his Mac video editor, through the `tandem` command. Use when a video folder has a .tandem project, or when asked to cut, trim, tighten, place B-roll, add titles, section cards, transitions, captions, stickers, music or sound effects, look at frames, render a review clip, check an edit, or export a video in Tandem.
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
   (soft zooms) are judgement calls.
5. **Hand back.** Tell Mike in a few lines what you changed and why. Your
   edits stay highlighted on his timeline until he marks them reviewed;
   that's his to do.

## Rules

- Change the project only through `tandem` (apply, undo, and tools run
  with `--apply`). Never edit `.tandem` files or anything in a `.tandem/`
  folder by hand or with scripts.
- Never run `open tandem://...`, and never install, quit, launch or restart
  the Tandem app. While it restarts, commands wait for it (up to 90 s).
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
    pieces.
- New files you make (B-roll, sound effects, stills) go in the video
  folder, then `tandem media --refresh` adds them.
- Find music, sound effects, stickers and icons with `tandem assets search`
  and add them with `tandem assets use <id> --at <time>`. Mike's shared
  library is `~/Movies/Tandem Library`.
- To export, `tandem export` writes the finished video (4K for a 4K frame)
  into `exports/`.
