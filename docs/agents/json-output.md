# JSON output

The shapes of the `--json` results you'll read most (timeline, media, transcript, wait, status, history, diff, clips, restore, apply, cut), and which fields can be missing.

A `--json` result is an object, and the project's `revision` is in it.
A field marked `?` can be missing (or `null`), so read it with a default
(`clip.get("video")` in Python, not `clip["video"]`). Errors are
`{"error": {...}}` on standard output with exit code 1.

## timeline

`tandem timeline --json` (MCP `timeline` with `format: json`) wraps the
project. Tracks are in two lists, not one `tracks`, and video tracks go
bottom to top (`videoTracks[0]` is V1, Screen). With `--from`/`--to`, each
track keeps only the clips that overlap the range.

```
{"revision": 4,
 "project": {"id", "name", "schemaVersion", "settings": {"width", "height", "frameRate": {"numerator", "denominator"}, ...},
             "metadata": {}, "markers": [{"id", "time", "duration", "name", "kind", "note"?}],
             "media": [{"id", "path", "kind", "role", "duration", ...}],
             "videoTracks": [Track], "audioTracks": [Track]}}

Track: {"id", "name", "kind", "rippleMode", "muted", "solo", "locked", "hidden", "targeted",
        "clips": [Clip], "transitions": [{"id", "type", "duration", "direction"?, "fromClipID"?, "toClipID"?, "soundClipID"?}]}

Clip:  {"id", "start", "duration", "sourceStart", "speed", "enabled", "freezeFrame", "keyframes": {}, "tags": [],
        "content": one of {"media": {"mediaID"}}, {"text": {"text", "preset"?, ...}},
                          {"graphic": {...}}, {"solid": {"color"}}, {"adjustment": {}},
        "name"?, "linkGroup"?, "video"?, "audio"?}
```

- A clip on the timeline from a file has its media ID at
  `content.media.mediaID`, and its source range is `sourceStart` for
  `duration * speed`.
- `name` is missing on clips with no name (titles, solids).
- `video` is missing until something sets it (a default transform, full
  opacity, no crop), and `audio` likewise. Once set, `video` has
  `transform` (`position {x, y}` 0 to 1, `scale`, `rotation`), `crop`,
  `opacity`, `effects`, and maybe `layoutPreset` and `cutout`; `audio` has
  `gainDB`, `fadeIn`, `fadeOut`, `muted`, `effects`, and maybe
  `normalizeTo`.
- `linkGroup` is missing on clips that aren't linked; linked clips share it.

## media

```
{"revision": 4, "added": ["med_..."],          // what --refresh added, usually []
 "items": [{"id", "path", "kind", "role", "hasVideo", "hasAudio", "clips", "exists",
            "duration"?, "width"?, "height"?, "frameRate"?, "takeID"?, "takeOffset"?,
            "analysis": {"transcript": {"state", "progress"?, "message"?}, "loudness": ..., "waveform": ..., "proxy": ..., "thumbnails": ...}}]}
```

`clips` is how many timeline clips use the file, and `state` is `ready`,
`queued`, `running`, `failed`, `cancelled` or `none`.

## transcript

```
{"revision": 4, "scope": "timeline" | "clip" | "media", "id"?, "timelineTimes": true,
 "words": [{"text", "start", "end", "clipID"?, "confidence"?}],
 "missing": ["med_..."]}                       // media whose transcript isn't ready
```

`timelineTimes` is false for a media transcript, whose times are the
file's own. `clipID` is set on timeline transcripts.

## wait and transcribe

`tandem wait --json` (and `waited` in `tandem transcribe --json`, which also
has `revision`, `applied`, `files` and `headless`):

```
{"what": "transcript", "done": true, "timedOut": false, "elapsed": 3.2,
 "finished": [{"kind", "mediaID"?, "path", "state", "progress"?, "message"?, "words"?, "mode"?}],
 "pending": [...]}                             // what's still going after a timeout
```

`state` is `ready` (`done` for a job) or `failed` when finished, and
`waiting`, `queued` or `running` when not. `words` is a ready transcript's
word count, 0 when there's no speech.

## status

```
{"name", "path", "revision", "savedRevision", "dirty", "duration", "width", "height", "frameRate",
 "tracks", "clips", "media", "markers", "headless", "recoveredEdits", "apiVersion",
 "undo"?, "redo"?, "openIn"?: {"owner", "pid", "started"},
 "jobs": [...], "exports": [...], "warnings": [...],
 "reviewPending": [{"label", "author", "date", "clipIDs", "removals"}],
 "handback": [{"id", "author", "date", "revision", "start", "end", "name", "note"?, "question", "comments": []}]}
```

`handback` is what agents asked Mike to look at when they handed back
and he hasn't watched yet, in timeline order (see `handback` below).

## handback

```
{"revision": 155, "recorded"?: 3,
 "notes": [{"id", "author", "date", "revision", "start", "end", "name", "note"?, "question",
            "comments": [{"id", "time", "text"}]}]}  // timeline order
```

`recorded` is how many were just handed back; without notes in the
request it's absent and `notes` is what's still waiting. `comments` are
Mike's comments in or within 2 s of the stretch: his answer, when it was
a question.

## history

```
{"revision": 4, "undo": [{"label", "author", "start"?, "end"?, "tracks"?}],  // newest first
 "redo"?: "label", "events": [{"seq", "kind", "date", "revision"?, "label"?, "author"?}],
 "edits"?: [{"revision", "kind", "label", "author", "date", "start"?, "end"?, "tracks"?, "summary"?}]}  // newest first
```

`events` are the changes this server saw; `edits` is the edit history,
which lasts across restarts. `kind` is `edit`, `undo`, `redo`, `reload`
or `opened` (where the history starts again). `tracks` are labels like
`"V2 Camera"`.

## diff

```
{"revision": 98, "since": "revision 95", "sinceRevision"?: 95,
 "changes": [Change],                            // every clip that's different now
 "edits"?: [{"revision", "kind", "label", "author", "date", "start"?, "end"?, "tracks"?, "changes": [Change]}]}

Change: {"id", "kind": "added" | "removed" | "changed", "track", "trackID", "start", "end", "content",
         "details": ["start +0.500s", ...], "wasTrack"?, "wasStart"?, "wasEnd"?, "shift"?, "before"?: Clip, "after"?: Clip}
```

`edits` is there when the history reaches `since`. `shift` is set on a
clip that only moved along its track.

## clips

```
{"revision": 7, "clips": [{"id", "track", "trackID", "start", "end", "duration", "content", "mediaID"?, "name"?, "enabled"}]}
```

## restore and apply

`tandem restore --json` gives `{"revision", "from", "items": [{"id",
"action": "putBack" | "changeBack" | "remove" | "unchanged", "track",
"start", "end", "content", "details"}], "commands", "applied"?,
"problem"?}`.

`tandem apply --json` gives `{"revision", "label", "author", "createdIDs",
"added", "changed", "removed", "duration", "warnings", "dryRun",
"repeated"}`; `createdIDs` lists new clips, tracks, transitions and markers
in the order the commands made them.

`tandem check --cuts --json` has `commands` (the fixes, latest first) and
`revision`. Each problem's `cut` has `clipID`, `edge`, `margin` (dB under
the speech level), `fixKind` (`trimToPause`, `putBack` or
`nothingNearby`), and `to` and `fix` when there's a fix; a `putBack`
fix trims the clip before the join, which may not be `clipID`. `drops`
is the kept word (the transcript's text) a trim back would have dropped,
when that's why the fix isn't a trim; it's missing otherwise.
`lastWordCut` is the last word of a sentence or clause the clip ends just
before, cut with what follows, when that's what clips it; `firstWordCut`
the first word of the sentence a clip starts just after; `fragment` the
leftover last word of a cut sentence a clip opens on; and `beforeFiller`
the word a cut of a filler took with it. Marginal joins are notes of kind
`marginalJoin`, with `cut.margin`.
With `--listen` it has `listened` too:

```
"listened": {"engine": "Bark 3.0 Pro", "heard": 3, "cached": 0, "secondsPerJoin": 0.9,
  "joins": [{"time": 30, "said": "that | Now", "heard": "that | be Now.", "clipIDs": ["clip_voc1", "clip_voc2"], "cached": false,
             "findings": [{"kind": "extra", "heard": "be", "time": 30.06, "slip": false,
                           "why": "sounds like part of \"because\", which is cut"}]}]}
```

`kind` is `notHeard` (a kept word near the join that isn't heard, `said`),
`heardAs` (`said` heard as `heard`) or `extra` (`heard`, which the take
doesn't keep there). A `slip` finding is as likely the engine's mistake,
or is somewhere the join can't cut; a join with any other is a
`heardCutOff` problem, and one with only slips a `heardDifferently` note.
A join that wasn't compared has `skipped`: `no transcript`, `nothing
heard` or `couldn't listen`. `cut` is the take's words cut beside the join
(the first two past the clip before it, then the last two before the clip
after it), when the transcript has any. Where a join is heard, a finding
the take's transcript explains is marked `slip` with the reason in `why`;
a `clippedWord` problem whose words are heard whole moves to the notes as
kind `heardWhole` (with its `cut`, and no command); and one with a
listening finding at its join stays, its message saying both. `engine` reads `Bark 3.0 Pro, then
SpeechAnalyzer` when Bark kept failing and SpeechAnalyzer took over.
A plain `tandem check --json` has `commands` and `revision` too when it
can fix a flicker or a double jump: a flicker's `fix` is the `holdFrame`,
and a `doubleJump`'s the `updateClip` that runs the shot out to the cut
(`start`, `duration`, `sourceStart`, `keyframes` and `holdEdges` as
needed), with `moreFixes` for copies of the shot that move with it. A
`doubleJump` problem's `clipIDs` are the shot, or for a camera flash both
shots, and `frames` how many frames of the take show. `commands` has the
double jumps' patches first, then the holds latest first.

## cut

```
{"revision": 57, "removed": 2.15, "durationBefore", "durationAfter",
 "commands": [{"cutRanges": {...}}],              // empty when nothing's cut
 "applied"?: {...apply's result}, "warnings": [],
 "fillers"?: {"found": 179, "cut": 120, "leftIn": {"fluent": 50, "protected": 1}, "removed": 61.2},   // with fillers: true
 "cuts": [{"asked", "text", "start", "end", "status": "cut" | "kept", "before", "after", "falseStart", "fillers"?,
           "cut"?: {"start", "duration"}, "mediaID"?, "mediaStart"?, "mediaEnd"?, "keptBefore"?, "keptAfter"?,
           "startEdge"?: {"verdict", "margin"}, "endEdge"?: {"verdict", "margin"},
           "broughtBack"?, "missed"?, "reason"?, "problem"?, "problemEdge"?}]}   // in the order asked, then fillers
```

`cuts` has one entry per stretch asked for. `start` and `end` are the
stretch as found (a phrase's words, or the range given); `cut` is what
comes out, on the timeline, and `mediaStart`/`mediaEnd` the same in the
voice's file. `keptBefore` and `keptAfter` are the pause left either side
of the join, in timeline seconds. `startEdge` and `endEdge` say how each side of the join
sounds, as `check --cuts` judges it (`verdict` `clean`, `marginal` or
`clipped`, and `margin` in dB under the speech level); in a long silence
the margin is small because there's no speech near to measure against.
A `kept` stretch has a `reason`, and a `problem` (`fluent`, `runsOn`,
`noSpeech`, `nothingLeft` or `notClean`) at `problemEdge` (`start` or
`end`) when the sound was read. `broughtBack` is the words a false start
brings back. `missed` is sound in the stretch (or within 0.3 s of it) that
no transcript word claims and the cut keeps, because cutting it would cut
a word that stays too: listen there.

With `fillers: true`, the fillers come after the stretches asked for, in
timeline order, each entry one stretch: `"um"`, or `"um + uh"` for fillers
side by side. A filler joined to a stretch asked for is in that one
(`"as I said + uh"`). An entry's `fillers` is how many fillers it is or
has in it. `fillers` on the result counts them: `found` between `from` and
`to` (one two mics hear is one), `cut`, `leftIn` by why (a `problem`, so
`fluent` for one in running speech, or `protected`, `broughtBack` when a
false start's cut brought it back, or `unplaced` when the sound couldn't
be read), and `removed`, the seconds the stretches cutting fillers take
out. Each filler is counted by where the cut actually goes, so one a
protect time covers inside a range you asked for is counted as cut.
