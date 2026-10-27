import Foundation
import TandemAPI

/// One CLI command: its usage line, what it does and the options it takes.
struct CommandHelp {
    var name: String
    var usage: String
    var summary: String
    var options: Set<String>
    var details: String = ""
}

enum Help {
    static let commands: [CommandHelp] = [
        CommandHelp(name: "new", usage: "tandem new <path.tandem> [--name <name>] [--portrait | --size <width>x<height>]", summary: "Create a project with Mike's usual tracks and add the media in its folder.", options: ["name", "portrait", "size"],
                    details: """
                    The canvas is 3840x2160 unless you say otherwise: --portrait makes a 1080x1920 short, --size any other size.
                    It says which file it took for the camera take and why: a record-it -camera file, or a video from a phone or camera (or in source/) with speech and a face in it. Live Photos stay one item each, the still, with its movie in livePhotoVideo.
                    """),
        CommandHelp(name: "status", usage: "tandem status [--revision] [--json]", summary: "Revision, length, unsaved changes, who has it open, undo, background jobs and agent edits waiting for Mike's review.", options: ["revision"],
                    details: "--revision prints just the revision number, to pass to --expect. Read it when you read the timeline you're about to edit, not right before applying, or --expect protects nothing. Tandem finding new files in the folder doesn't make it stale."),
        CommandHelp(name: "media", usage: "tandem media [--refresh]", summary: "Media files, how many clips use each, and analysis status.", options: ["refresh"],
                    details: "--refresh scans the project folder for new files first."),
        CommandHelp(name: "timeline", usage: "tandem timeline [--from <time>] [--to <time>] [--words] [--summary] [--json]", summary: "The edit as readable text (or the project JSON).", options: ["from", "to", "words", "summary"],
                    details: "Tracks top to bottom as the app shows them, one line per clip. --summary gives one line per track, for finding your way round a long edit; --words adds what's said in each voice clip; --json prints the project JSON."),
        CommandHelp(name: "apply", usage: "tandem apply <file.json | - | '<json>'> [--dry-run] [--expect <revision>] [--label <text>] [--key <id>]", summary: "Apply a batch of edit commands as one undo step.", options: ["dry-run", "expect", "label", "key"],
                    details: """
                    The JSON can be a batch {"label": ..., "commands": [...]}, a list of commands, or one command like {"blade": {"at": 12.5}}, in a file, on standard input (-) or quoted as the argument itself.
                    --expect refuses the edit unless the project is at that revision. --key makes a retry safe (idempotency key).
                    `tandem help <edit command>` (like addTransition) gives its arguments and an example, and `tandem schema` prints the JSON schema. docs/AGENTS.md in the Tandem repo indexes the guides; docs/agents/edit-commands.md has what help doesn't say.
                    """),
        CommandHelp(name: "undo", usage: "tandem undo [--count <n>] [--expect <revision>]", summary: "Undo the last edit, or the last n with --count.", options: ["expect", "count"],
                    details: "--count undoes several steps in one go, stopping early if the history runs out; use it rather than undoing twice, since each undo makes a new revision. --expect refuses unless the project is at that revision, even if Tandem only found new media since, because the top undo step would then be that."),
        CommandHelp(name: "redo", usage: "tandem redo [--count <n>] [--expect <revision>]", summary: "Redo the last undone edit, or the last n with --count.", options: ["expect", "count"]),
        CommandHelp(name: "history", usage: "tandem history [--limit <n>]", summary: "What undo would undo, and the edit history: each edit's revision, who made it and where it was on the timeline.", options: ["limit"],
                    details: "The edit history is kept in .tandem/<name>.history.jsonl, so it lasts across restarts and from one command to the next, whoever made the edit (Mike in the app, an agent, the CLI). Each line has the times and tracks the edit touched. A run of Tandem finding new media is one line. `tandem diff --since <revision>` shows what each edit did to the clips."),
        CommandHelp(name: "diff", usage: "tandem diff --since <revision | file.tandem | export.mp4> [--json]", summary: "What changed on the timeline since a revision, a backup or an export, clip by clip, grouped by edit and who made it.", options: ["since"],
                    details: """
                    Each clip that's different: added, removed, moved, trimmed (start +0.500s, end -1.000s), slipped, and changed settings like scale, position, gain, fades, effects and keyframes, with its timeline times and track. Clips that moved together by the same amount (riding a ripple) are one line. Media, markers, transitions and settings aren't compared.
                    --since a revision walks the edit history back, so the changes come grouped by edit, with who made each one and where it was. The history goes back to when this version of Tandem first opened the project; past that, a backup with that revision in .tandem/backups is used, or it says what to use instead.
                    --since a .tandem file compares with it: a backup, another version, or the snapshot every export writes beside itself (exports/v3.mp4.tandem). Give the export (exports/v3.mp4) and its snapshot is read.
                    Use it to see what Mike changed since you last looked. --json has each clip before and after.
                    """),
        CommandHelp(name: "restore", usage: "tandem restore --from <revision | file.tandem | export.mp4> (--clips <id,id> | --from-time <time> --to-time <time> [--track <name>]) [--apply]", summary: "Put clips back as they were in a revision, a backup or an export (a dry run without --apply).", options: ["from", "clips", "from-time", "to-time", "track", "apply", "label", "expect"],
                    details: """
                    Each clip goes back to where it was, with its trims, settings and keyframes: one that's gone is put back on its track, one that's changed is changed back, and one that wasn't there comes out. --clips names them; --from-time and --to-time take every clip that was in that stretch (in that timeline's times) and anything in it now that wasn't there, on --track if given.
                    It's one undo step, made like any other edit. Transitions, media and markers aren't restored. If something now sits where a clip goes back, the dry run says it wouldn't apply; restore that clip too, or move it first.
                    """),
        CommandHelp(name: "clips", usage: "tandem clips [--track <name or id>] [--from <time>] [--to <time>] [--media <id or path>] [--ids] [--json]", summary: "Clips with their ID, track, start, end and what they play, filtered by track, time and media.", options: ["track", "from", "to", "media", "ids"],
                    details: "--track takes a track ID, name (Camera) or label (V2). --from and --to keep clips that overlap that stretch. --media takes a media ID, path or file name. --ids prints just the IDs, one a line. Use it to find clip IDs instead of reading the whole timeline JSON."),
        CommandHelp(name: "validate", usage: "tandem validate", summary: "Check the project for problems (exit code 1 if it has errors).", options: []),
        CommandHelp(name: "check", usage: "tandem check [--changed | --from <time> --to <time>] [--quick | --cuts [--listen]] [--width <pixels>]", summary: "Look for what Mike would catch in review: black frames, flickers, green screens that didn't key, white blocks and gaps (exit code 1 if it finds any), and notes on soft zooms, dead air, page changes with no transition and screen recordings at a low frame rate. --cuts checks for words clipped at cuts instead, and --listen hears each join too.", options: ["from", "to", "changed", "quick", "cuts", "listen", "width"],
                    details: """
                    Renders every frame of the stretch small (384 wide, from proxies where they're ready) and measures it, and the screen recordings again on their own. It reads 10 s pieces side by side and keeps what it measured in .tandem/cache/check, so the next check renders only the pieces where something changed.
                    A flicker inside one clip of a video comes with the holdFrame that holds the frame before it, when the check can tell which picture flashed, and the last line is a `tandem apply` that makes them all.
                    Notes don't fail it. Dead air is 0.8 s or more of a still picture with nothing said and no sound effect or music swell: cut it, or keep it if the pause earns it. A page change is the screen recording turning to a new page at once with no transition over it: push it if it's a page in an explainer or slides. A sliver is a clip, or a gap between clips on a track, shorter than a frame. A low frame rate is a screen recording the viewer sees moving at under 12 frames a second (macOS records the screen as it changes) for a second or more: cover it with the camera full screen or B-roll, or cut it.
                    --changed checks only what agents changed that's waiting for Mike's review, half a second either side: run it before handing back.
                    --quick skips rendering: just the gaps, slivers and pictures zoomed past their own pixels.
                    --cuts checks only the cuts on the speech tracks, from the files' own sound (nothing rendered, so it's quick); the transcript only says where a word boundary can be. A cut in a real pause (quiet for 0.08 s or more in the full band and above 4 kHz, against the floor of the 3 s around it) is fine, and so is one in a shorter quiet gap (0.025 s or more) with a word boundary by it: a gap between words, where only the side the clip keeps counts, even if the next word starts 0.04 s on. Any other short gap is inside a word (all of them, without a transcript). Voice at speech level past the cut, before a pause or a gap between words (the "t" of "extract", the rest of the kept word), is a clipped word however quiet the clip's side is, and so is a clip that ends just before the last word of its sentence with that word cut ("lies about [time.]"), even in a real pause. The transcript also catches cuts that leave a sentence wrong however clean they sound: a clip that starts just after the first word of its sentence with that word cut ("TS. [It's] like the time"), one that opens on the last word of the sentence cut before it ("places [do,] but I want", a fragment), and a cut of a filler that took the "the" (or another determiner) before it with it ("And [the like,] challenge"). Otherwise it goes by how far the clip's 25 ms beside the cut is under the speech around it: under 9 dB is a clipped word, 9 to 15 dB a marginal join (a note, worth a listen), 15 or more clean. Each clipped edge says its fix: a trim within 0.5 s, outward first, finishing the word the cut is in (or the sentence's last word, past it; or back before its first word), into the gap before the next cut word or a real pause, never bringing another cut word back or dropping a kept one (a fragment's fix drops it); or, with none, putting back a cut of 2 s or less, filler and all (it names the kept word a trim back would have dropped); or nothing nearby, to listen to and recut by hand. The last line is a `tandem apply` that makes them all. Run it after cutting the take.
                    --listen (with or without --cuts) also renders the voice 3 s either side of each join as export plays it (the speech tracks only, the soloed ones if any are), transcribes it with Bark 3.0 Pro (SpeechAnalyzer when Bark isn't downloaded or keeps failing), and compares what's heard with the take's kept words there. A join can only cut off the end of the kept word before it or the start of the one after it, so a problem is one of those two not heard, the word before heard missing its end ("extra" for "extract"), the word after heard missing its start, or a word heard between them that the take doesn't keep ("oh" from "okay"). Anything else is a note: a word further off, a word missing the end the join can't reach, a word heard as something else with nothing of it short (a name), a short word, a filler, a near spelling or an inflection, since the engine slips on those too, and a cut word heard whole (the transcript's times put it in the cut). Where the take has no transcript yet, or the engine hears nothing or fails, the join isn't compared and says why. Words match loosely: case, punctuation, numbers, "wanna" for "want to", "t. s." for "TS". It prints the take's words and the words heard across every join, so read them for anything that doesn't run on, and listen to what reads wrong with tandem clip. Each join takes about a second the first time; what's heard is kept in .tandem/cache/listen by the sound rendered and the engine's model, so a check after edits only listens again where the sound changed. It catches cut-offs the levels can't, but not all of them: a fragment heard as a whole word reads fine. With --cuts, where a join is heard the two weigh each other: a level flag whose kept words are all heard whole is a note (heardWhole), unless the clip's 25 ms at the cut is under 6 dB below the speech, where the engine fills in what's cut; a last-word, first-word or before-filler flag whose word is heard is a note too; a finding the take's transcript explains (a word it has at the edge in the cut heard whole, a word that sounds the same, nothing heard on that side at all, a word it has twice heard once) is a note; and a join with both a flag and a finding is one problem that says both.
                    """),
        CommandHelp(name: "sync", usage: "tandem sync [<seconds> [--media <id>]... [--default]] | tandem sync <file>... [--to <camera file>] [--no-place] [--dry-run]", summary: "How late each file's picture is against its sound, so lips match the voice; give a delay to set it on the camera takes. Give files instead (another camera angle, an external mic) to line them up with the camera by sound and place them.", options: ["media", "default", "to", "no-place", "dry-run", "label", "expect"],
                    details: """
                    A webcam's picture lags its mic (Mike's by about 0.08 s). With a delay, every camera take (or the --media files) shows its picture that much later in the file, everywhere: the app, frames, review clips, check and exports. The sound, the cuts and the transcript's word times stay where they are, so nothing else moves. 0 puts the picture back as recorded. Don't also slip clips by hand, or the delay doubles.
                    --default makes it the delay new camera takes get (Tandem's settings), as Settings in the app does.
                    Takes Record It already corrected (its Camera delay, tagged in the file) show "in sync as recorded" and are left alone.
                    Without a delay it lists each file's delay and the default.

                    With files (media IDs or paths) it lines each one up with the camera take by their sound, however much of the take it covers, and says how much further into the file the same moment is (+2.855 s: it started first), how much the two clocks drift apart over the overlap, and how confident the match is (unrelated sound scores under 10; under 15 is refused, and nothing changes). Then, as one undo step, it puts each file in the camera's take (takeID and takeOffset) and places it beside the take's clips, linked to them, so ripple cuts, trims and moves keep it in step (the placeSynced edit command; tandem help placeSynced). Another camera angle goes on its own track right above the camera's, "Angle 2", turned off until you show it somewhere with the showAngle edit command; its own sound isn't placed. A sound file goes on Voice, and the camera's own sound there moves to a muted "Camera sound" track, so the mic is what plays and gets transcribed. The take is cut where each file starts and stops.
                    --to names the file to line them up with when there's more than one camera take. --no-place only sets their takes. --dry-run measures and checks the edit without changing anything. A 46 min camera take and an 18 min file take about 20 s.
                    Examples:
                      tandem sync "source/Ian close-up.mov" "source/Ian mic.wav"
                      tandem apply '{"showAngle": {"range": {"start": "4:57", "end": "5:18"}, "trackID": "Angle 2"}}'
                    """),
        CommandHelp(name: "handback", usage: "tandem handback ['<json list>' | <file.json> | -] | [--at <time> --name <text> [--to <time>] [--note <text>] [--question]]", summary: "Hand a round back: the two to five places Mike should look at first, which Tandem walks him through before the rest of your changes. Alone, what he hasn't watched yet.", options: ["at", "to", "name", "note", "question"],
                    details: """
                    A round can touch hundreds of clips, and they're all highlighted the same. This is the short list: the places that carry the round's risk (a stretch of a sweeping change, the new shot, the thing you weren't sure about), with a few words each on what's there. The review chip in the app reads "3 to look at": ] steps Mike through them first, in timeline order, playing each stretch, then through the rest of the highlights. One goes once he's watched its stretch; Mark reviewed clears them all. What you hand back takes the place of what you handed back before.
                    Each is {"at": "2:45", "to": "3:10", "name": "Angles: ten zooms became two here", "note": "The busiest stretch; if it reads OK the rest will", "question": false}. --to defaults to 5 s after --at. Mike reads these off a small card at a glance, so the name is a few words (40 characters at most) and the note one short line (80 at most); the command refuses longer ones. Save the detail for your final message. A question is one you want his answer to: he leaves a comment there, which tandem handback (alone) and tandem comments both show.
                    Run it after tandem check, before your final message, then tell him in a line that Tandem will walk him through them.
                    Examples:
                      tandem handback '[{"at": "2:45", "to": "3:10", "name": "Angles: ten zooms became two here"}, {"at": "27:12", "to": "27:18", "name": "Wikipedia over your 1970s aside"}]'
                      tandem handback --at 38:24 --name "Keep the twenty dollar plan line?" --note "Pro is $25 now" --question
                      tandem handback
                    """),
        CommandHelp(name: "comments", usage: "tandem comments [resolve <id>... | resolve --all]", summary: "The comments Mike left on the timeline for you, with what's said and playing at each; resolve clears the ones you've done.", options: ["all", "label"],
                    details: """
                    Mike adds comments in Tandem at the playhead (Add comment, Shift-C) while he reviews: notes like "cut the umm here" for the next round. Each shows its ID, time and words, what's said a few seconds either side (| marks the comment) and the clips playing there.
                    Do what each asks and label the edit with what you did. Then remove the comment: in the same apply batch with {"removeMarker": {"markerID": "<id>"}}, or afterwards with tandem comments resolve <id>. Comments move with ripple edits, so list them again after one.
                    """),
        CommandHelp(name: "transcript", usage: "tandem transcript [<clip or media id>] [--from <time>] [--to <time>] [--make]", summary: "Word timings for a clip (timeline times), a file (file times) or the whole timeline.", options: ["from", "to", "make", "timeout"],
                    details: "--make makes the file's transcript first if it has none, as `tandem transcribe <id> --wait` does, so it works for any file with sound."),
        CommandHelp(name: "search", usage: "tandem search \"<phrase>\" [--limit <n>]", summary: "Find where a phrase is said, as timeline times and clip IDs.", options: ["limit"]),
        CommandHelp(name: "pauses", usage: "tandem pauses [--min 0.6] [--from <time>] [--to <time>]", summary: "Silences between words, in timeline time, and what the sound has in them.", options: ["min", "from", "to"],
                    details: "Each gap is listened to on every unmuted audio track of the take that plays there. Each line says how long it is in the sound (from the end of the last word's sound to the start of the next's), and where there's sound in it no word accounts for (a breath, an um the transcript left out, someone off mic, an app), with the track it's on. --json has it as sound: start, end, quiet (the real pauses), heard and runsThrough."),
        CommandHelp(name: "tighten", usage: "tandem tighten [--mike] [--sentence <s>] [--comma <s>] [--mid <s>] [--mid-min 0.5] [--min <s>] [--keep 0.15] [--protect <time,...>] [--widen] [--from <time>] [--to <time>] [--apply]", summary: "Shorten pauses by what they follow, or every pause over --min to --keep (a dry run without --apply).", options: ["min", "keep", "sentence", "comma", "mid", "mid-min", "mike", "protect", "widen", "from", "to", "apply", "label", "expect"],
                    details: """
                    --mike is Mike's rules: 0.4 s after a sentence (a word ending . ? !), 0.12 s after a comma (, ; :) and 0.08 s mid-sentence, changing only pauses of 0.5 s or more (--min for sentences, --mid-min for the rest) so breaths stay. --sentence, --comma and --mid set or override each keep; a kind with no keep is left alone, and a comma falls back to --mid.
                    Without them, every pause of --min (0.6) or more is shortened to --keep (0.15).
                    --protect 1:02.5,3:10 leaves the pauses containing those times alone (deliberate beats), as the transcript has them or as they're heard. --from and --to hold for the cuts too. --widen also widens joins between speech clips that leave less than the keep, with ripple trims into silence the take has either side (never past a transcribed word). Listen to widened joins: an um the transcript left out can come back.
                    The transcript finds the pauses; the sound places the cuts. Each pause is listened to on every unmuted audio track of the take that plays there, and the keep (and --min) is measured from the end of the last word's sound to the start of the next word's. Cuts go in real pauses, quiet on every track, and never through sound no word accounts for (someone off mic, an app, a breath, an um): the quiet either side of it is cut, the sound and 30 ms either side of it count towards the keep, and a pause with no quiet long enough is left alone. A join never keeps under 0.03 s after the word before or 0.08 s before the word after, as tandem cut keeps, so 0.08 s mid-sentence comes out at 0.11 s. A side of a join check --cuts wouldn't call clean moves further into the quiet until it is, or the cut is left out. The plan lists what it left alone and why, and where the sound is, so listen to those with tandem clip.
                    """),
        CommandHelp(name: "cut", usage: "tandem cut \"<phrase>\"... [--at <time>]... [--range <start>-<end>]... [--fillers [--from <time>] [--to <time>] [--protect <time,...>]] [--false-start] [--apply]", summary: "Cut words, or every um and uh, out of the whole take with both edges in real pauses, so nothing that stays is clipped (a dry run without --apply).", options: ["at", "range", "fillers", "from", "to", "protect", "false-start", "apply", "label", "expect"],
                    details: """
                    Use it instead of building rippleDeleteRange or cutRanges from search times, which are 30 to 200 ms off the sound. Each phrase is found as tandem search finds it on the timeline; one said more than once needs --at with the time of the one to cut (the first --at goes with the first phrase, and so on), overlapping ones included ("very very" twice in "very very very"). A phrase two voice tracks both hear is said once. --range cuts a timeline stretch instead, from roughly where its words start to where they end.
                    Each cut starts in the real pause before the first word and ends in the one after the last, found in the voice's own sound (the raw mic, as check --cuts reads it); the transcript only says roughly where the words are and which stay. The join keeps Mike's tighten pauses: 0.4 s after a sentence, 0.12 s after a comma, 0.08 s mid-sentence, never under 0.03 s after the word before or 0.08 s before the word after. Both sides of each join are judged as check --cuts would, with the margin.
                    A stretch with no pause round it (a filler or a repeat in running speech) is left in and the reason given: cutting there clips a word, and leaving the filler in sounded right. A long false start (over 2 s, or every stretch with --false-start) is cut pause to pause anyway, even if a word of it comes back with the restart; the result says which. Sound in the stretch that no word claims goes with it, and when it can't (a word that stays is past it) the result says how much stays.
                    --fillers also cuts every filler the transcript has between --from and --to: um, uh, uhm, erm, er, ah, mm and hmm, in any case, with punctuation and drawn out ("Ummm,"). Not oh, eh, uh-huh or mm-hmm, which mean something, nor like or you know, nor one with a digit in it ("10mm") or a question mark ("Hmm?"). Each is planned like a phrase, so one between pauses goes pause to pause and one that runs into a word that stays is left in (fluent): a natural um beats a chopped word. Fillers side by side ("um, uh"), or beside a phrase or range being cut, with no word that stays between them, are one stretch, within one run of the take (never across an earlier cut or a clip with no transcript). --false-start doesn't apply to fillers on their own. --protect 1:02.5,3:10 leaves in a filler with one of those times in it or the pauses round it, unless it's inside a phrase or range you asked to cut. The result counts the fillers found, cut and left in (and why) and the seconds they take out, and lists each one at its timeline time, so listen to the ones left in with tandem clip. Cut fillers before tighten: tighten then shortens what's left, and the join a filler leaves already keeps what tighten would.
                    Every stretch is one cutRanges: the camera, screen and voice of the take all lose the same time, B-roll, music and titles follow, and one undo puts it all back. For an exact cut at times you've checked yourself, use cutRanges.
                    Examples:
                      tandem cut "as I said before" "you know" --at 2:14 --at 3:10
                      tandem cut --range 1:02.4-1:09.8 --false-start --apply
                      tandem cut --fillers --from 2:00 --to 5:00
                    """),
        CommandHelp(name: "join", usage: "tandem join [--from <time>] [--to <time>] [--apply]", summary: "Join through-edits, cuts where a clip carries straight on into the next piece of the same file, so the take is one clip again (a dry run without --apply).", options: ["from", "to", "apply", "label", "expect"],
                    details: """
                    A through-edit is a cut where nothing changes: the same file at the same speed carries straight on (within half a frame) with the same settings. Putting cuts back with ripple trims leaves them behind. Each is joined into one clip with the first clip's ID and link group, along with the clips linked to it across the cut (camera, screen and voice), and what plays doesn't change.
                    Cuts that would play differently joined are left and listed with the reason: a transition or a fade on the cut, different settings, animation that wouldn't carry on, or a linked clip cut somewhere else. --from and --to only join cuts between them.
                    To join one cut: tandem apply '{"join": {"clipID": "<the clip before the cut>"}}'.
                    """),
        CommandHelp(name: "short", usage: "tandem short [--apply] [--copy [-o \"Name Short.tandem\"]]", summary: "Lay the edit out as a 9:16 short: screen on top, camera below (a dry run without --apply).", options: ["apply", "copy", "output", "label", "expect"],
                    details: "With --copy (what you usually want) the short becomes a project of its own beside this one, \"<Name> Short.tandem\" or -o's name: laid out, then made 1080x1920, so the app shows it portrait and you cut it down there. This project isn't edited, and an existing file is never replaced. Without --copy it adds the portrait format (1080x1920) to this project and places each video clip in it; the landscape edit is untouched, but the app still shows the landscape canvas. Then `tandem export --preset short`. A project whose canvas is already 9:16 (`tandem new --portrait`) is its own short, so there's nothing to lay out: export it with `tandem export --preset short`."),
        CommandHelp(name: "captions", usage: "tandem captions [--from <time>] [--to <time>] [--max-words 3] [--y 0.42] [--track Captions] [--apply]", summary: "Add word-by-word captions from the transcripts (a dry run without --apply).", options: ["from", "to", "max-words", "y", "track", "apply", "label", "expect"],
                    details: "Captions go on a video track (made if missing, rippling with the speech), a few words at a time with the spoken word highlighted. --y places them: 0.42 (the default) sits between the screen and the camera in a short; about 0.85 suits landscape."),
        CommandHelp(name: "cards", usage: "tandem cards [--kicker <words>] [--duration <s>] [--insert] [--no-sounds] [--marker <id>]... [--track <id>] [--apply]", summary: "Put a numbered section card at every section marker (a dry run without --apply).", options: ["kicker", "duration", "insert", "no-sounds", "marker", "track", "apply", "label", "expect"],
                    details: """
                    Every section marker after 0:00 gets a card (or just the --marker ones): numbered in time order, the marker's name as the title, its note as the subtitle, and progress bars for the count. --kicker Section (or Tip) adds SECTION 1 OF 3 beside the number; Mike prefers the number alone, so leave it off unless he asks. A card already at a marker is renumbered and keeps its words, so run it again after adding a section.
                    Each card is as long as its words need to be read: 1.4 s for the wipes and 0.8 s to take it in, then its title, subtitle and kicker at 15 characters a second, from 4 s to 7 s. --duration sets one length for them all.
                    Cards go on Graphics, hiding the frame from each marker on. --insert also makes room at each marker, so the card is a pause and its wipes show the shots either side (the whole take moves). It cuts the take in the pause before the section's first word: a marker on a word moves the cut into the pause beside it (up to 0.3 s), so the word isn't clipped, and the plan says so. The whooshes come from the asset library and go on SFX; --no-sounds leaves them out.
                    """),
        CommandHelp(name: "frame", usage: "tandem frame <time> [-o out.png] [--width <px>]", summary: "Render one frame of the timeline to a PNG.", options: ["output", "width", "height", "format"]),
        CommandHelp(name: "frames", usage: "tandem frames <time>... [--every <seconds> [--from <time>] [--to <time>]] [-o sheet.png] [--width <px>] [--format <id>]", summary: "Render several frames onto one contact sheet PNG, each labelled with its time.", options: ["output", "width", "every", "from", "to", "format"],
                    details: """
                    Give times, or --every <seconds> through the timeline (--from and --to for part of it; --to is shown, the timeline's own end isn't), or both. The frames go in time order, each 480 px wide by default (--width, 64 to 1920), about four to a row for landscape and seven for portrait, with its time in the strip underneath so captions stay visible. At most 48 frames on a sheet.
                    The default file is frames-<first>-<last>.png in this folder, with dots for the colons. --format renders an alternate format, like portrait.
                    """),
        CommandHelp(name: "screenshot", usage: "tandem screenshot [-o out.png]", summary: "Save a picture of the app window (needs the app to have the project open).", options: ["output"]),
        CommandHelp(name: "clip", usage: "tandem clip <start> <end> [-o out.mp4] [--preset review] [--tracks <name,...>] [--audio-only]", summary: "Render part of the timeline to a review MP4, or only some audio tracks, or the sound alone.", options: ["output", "preset", "tracks", "audio-only"],
                    details: """
                    The default file is exports/review <start>-<end>.mp4 in the project folder. The mix is mastered to the project's loudness target over the clip, as an export is.
                    --tracks Music,SFX plays only those audio tracks (names or IDs), at the timeline's own level rather than mastered, so a stem sounds as it sits in the mix. Video still renders; the track names go in the file name.
                    --audio-only writes the sound alone as a .m4a; -o something.wav writes 24-bit PCM instead (a stem over 0 dBFS clips there).
                    To measure rather than listen, `tandem loudness --from <t> --to <t>` takes the same --tracks.
                    """),
        CommandHelp(name: "export", usage: "tandem export [--preset <name>] [-o out.mp4] [--from <time>] [--to <time>] [--format <id>]", summary: "Export the video, loudness matched (presets: youtube4k, youtube1080, review, short).", options: ["output", "preset", "from", "to", "format"],
                    details: """
                    A preset sets the quality: codec, bitrate and resolution (pixels on the frame's short side). The frame keeps the canvas's shape, so youtube1080 is 1920x1080 for a landscape project, 1080x1920 for a 9:16 one and 1080x1080 for a square.
                      youtube4k    HEVC, 2160 on the short side, 80 Mbps. For a 4K landscape video.
                      youtube1080  H.264, 1080 on the short side, 20 Mbps. For a 1080p video, landscape or portrait.
                      review       H.264, 720 on the short side, 5 Mbps. A small file to watch or send.
                      short        H.264 1080x1920, 20 Mbps. The 9:16 short: the portrait format that `tandem short --apply` lays out in a landscape project, or the canvas itself in a project made with `tandem new --portrait`.
                    Without --preset the canvas decides: youtube1080 for a canvas 1080 or less on its short side (1920x1080, 1080x1920), youtube4k for anything bigger.
                    Bitrates are for 16:9 at up to 30 fps. A frame with less area gets proportionally less (1080x1080 gets 11.3 Mbps), and 48 to 60 fps gets half as much again, as YouTube recommends.
                    A preset bigger than the canvas (youtube4k of a 1080x1920 project is 2160x3840) upscales it, with a warning. --format renders an alternate format, like portrait, at the preset's quality.
                    It prints the preset, size, codec and bitrate it used, and the mix's loudness: -14 LUFS, with true peaks limited 0.5 dB under the -1 dBTP ceiling so the AAC file stays under it too.
                    """),
        CommandHelp(name: "archive", usage: "tandem archive [<project>] [--to <folder>] [--with-cache] [--dry-run]", summary: "Make the project standalone: copy what it uses from outside its folder into it, or with --to write a standalone copy of the whole folder somewhere else.", options: ["to", "with-cache", "dry-run", "label"],
                    details: """
                    Without --to, media, LUTs and fonts the project uses from outside its folder are copied into media/<folder they were in>/, assets/lut/ and assets/font/, and the project points at the copies (one undo step). Other .tandem files in the folder are pointed at them too.
                    With --to <folder>, the whole project folder is copied to <folder>/<project folder name>, with those files brought in and every path relative; the original is left as it was. Proxies, mattes, thumbnails and isolated voice are left out (Tandem makes them again) unless --with-cache; transcripts, waveforms and loudness always go. npm packages are left out.
                    Copies are APFS clones where they can be, checked by SHA-256 otherwise, and never replace a different file (they go beside it as "name 2"). archive.json records where each file came from. Missing files are listed and left as they are. A run that stops part way can be run again.
                    --dry-run lists what would be copied and the sizes.
                    """),
        CommandHelp(name: "relink", usage: "tandem relink [--search <folder>]... [--dry-run]", summary: "Find missing media files by name (and content) in the project folder, any --search folders and then the shared library, and point the project at them.", options: ["search", "dry-run", "label"]),
        CommandHelp(name: "loudness", usage: "tandem loudness [<media id>] | --from <time> --to <time> [--step <s>] [--tracks <name,...>] [--gains] [--over <dBFS>]", summary: "Measured loudness per file and the levelling each clip gets, or the rendered mix's loudness over time.", options: ["from", "to", "step", "tracks", "gains", "over"],
                    details: """
                    Without options it lists each file's measured loudness and how each track's clips are levelled, which clips a limiter holds, and the speech clips whose levelling puts their peaks over the true peak ceiling with nothing holding them (normalizeSpeech holds those).
                    With --from, --to, --step or --tracks it renders the mix the way export does and prints its loudness every step (about 50 rows unless --step says, at least 0.1 s): momentary (the 400 ms centred on the time), short-term (the 3 s) and the highest sample, plus the range's integrated loudness and true peak and a sparkline. Levels are as the timeline plays them, before export's master gain, which moves everything by the same amount. Use it for music swells and fades, a sound effect against the voice, or a bed under speech, instead of ffmpeg on a review clip. --tracks Music,SFX measures only those audio tracks; --json gives every point. Past 2,000 rows (a long take at a small step) the plain text gives the summary and sparkline without the rows; --json still has them all, up to 100,000.
                    --over <dBFS> answers "where does this clip": it lists the windows whose highest sample is over that level, neighbours merged into stretches with their peak, instead of the rows. `tandem loudness --from 0 --to 18:00 --tracks Voice --over 0` finds where the Voice track goes over full scale; --over -1 finds what would touch the -1 dBTP ceiling. Without --step it measures every 0.4 s, so the 400 ms windows cover the whole range.
                    --gains also renders each track (the --tracks ones, or every one that plays there) as it is and with its gain flattened, and compares the difference with its gain lane 10 ms at a time: the clip's levelling, gain, gain keyframes and fades. It says if a change lands late (and by how much) or not at all. It checks the render does what the lanes say, not that the lanes are right.
                    """),
        CommandHelp(name: "transcribe", usage: "tandem transcribe <media id | clip id | path>... [--wait | --no-wait] [--timeout <seconds>]", summary: "Make a transcript of any file with sound, whatever its role or track (a generated clip, a sound effect), and wait for it.", options: ["wait", "no-wait", "timeout", "label"],
                    details: """
                    Tandem transcribes camera takes and what's on a speech track by itself. This asks for anything else with sound, with the same on-device engine (Bark 3.0 Pro; SpeechAnalyzer for a language other than English, or in the app while Bark's model downloads, and the job says so), and marks the file (transcribe: true, one undo step) so the transcript is made wherever the project is open. An empty transcript means no speech.
                    With the app closed it waits by default, making the transcript here and printing progress; with the app open it queues it and returns, unless --wait. --no-wait only queues it. --timeout defaults to 600 seconds.
                    The first transcript made here downloads Bark's model (1.23 GB, once) before transcribing, and the progress lines say so. A wait that times out leaves the download where it got to, and the next command carries on from there.
                    Then `tandem transcript <id>` reads it. Exit code 1 if a transcript failed or the wait timed out.
                    """),
        CommandHelp(name: "wait", usage: "tandem wait [transcript | matte | proxy | jobs | export] [--media <id or path>]... [--timeout <seconds>]", summary: "Wait for background work to finish (transcripts, mattes, proxies, every job, or exports), printing progress, then say what finished.", options: ["media", "timeout"],
                    details: """
                    Without a kind it waits for every background job. transcript, matte and proxy wait for the ones the project makes (camera takes' and the voice's transcripts, mattes for clips with their cutout on, proxies for large video on the timeline), or with --media just those files'. A file nothing makes one for is an error that says how to get it made.
                    With the app closed, the wait makes the work itself for as long as it runs, the way `tandem serve` does: other commands still work meanwhile, and Mike opening the project hands it to the app, where the wait carries on.
                    export waits for exports and review clips rendering through the app or `tandem serve`.
                    --timeout defaults to 600 seconds; when it passes, the wait says what's still going. Exit code 1 if anything failed or it timed out.
                    """),
        CommandHelp(name: "watch", usage: "tandem watch [--once] [--timeout <seconds>]", summary: "Print changes as they happen (or wait for the next one with --once).", options: ["once", "timeout"]),
        CommandHelp(name: "effects", usage: "tandem effects [<type>]", summary: "Effects with their parameters, transitions, layouts and animatable parameters.", options: []),
        CommandHelp(name: "schema", usage: "tandem schema", summary: "Print the JSON schema for edit batches.", options: []),
        CommandHelp(name: "import", usage: "tandem import filmora <file.wfp> [--keep-levels] | edl [edl.json] --recipe <name|recipe.json> | compare <a.tandem> <b.tandem> [--out <folder>] [--name <name>] [--search <folder>]... [--rewrite <from>=<to>]...", summary: "Import a Filmora project or an agent EDL, or compare two cuts of the same footage.", options: ["out", "name", "search", "rewrite", "recipe", "keep-levels"],
                    details: """
                    Writes <out>/<name>/<name>.tandem with a report beside it (<name>.import.txt and .json). --out defaults to this folder.
                    Filmora media that moved is looked for in the project's folder and every --search folder; --rewrite from=to fixes paths saved on another Mac.
                    Speech (the camera's sound, the Voice tracks) is normalised to the project's speech level, -20 LUFS, with no gain. --keep-levels keeps Filmora's own levels instead: Auto Normalization becomes normalise to -24 LUFS plus the clip's gain.
                    Built-in EDL recipes: decision-models. Exit code 1 if anything failed to import.
                    """),
        CommandHelp(name: "assets", usage: "tandem assets providers | search \"<text>\" [--kind sfx|music|sticker|...] [--provider <id>] [--online] [--limit <n>] | fetch <id> | show <id> | use <id> [--at <time>] [--duration <time>] [--anchor bottom|bottomLeft|bottomRight|top|topLeft|topRight|centre|lowerThird] [--pop] | credits [--optional] | generate sfx|music \"<prompt>\" [--duration <s>] [--variations <n>] | install-starter",
                    summary: "The asset library: find, fetch, generate and use music, sound effects, stickers, icons and logos, and build the description credits.",
                    options: ["kind", "provider", "online", "limit", "at", "duration", "anchor", "pop", "label", "optional", "variations"],
                    details: """
                    providers        which sources work now, and what to fix (a key, a permission)
                    search           the library's catalogue; --online asks the providers too
                    fetch <id>       download and normalise an asset
                    show <id>        what the library knows about it: prompt and model, provider, duration, loudness, licence and credit, and its file (instead of reading meta.json)
                    use <id>         copy it into the project and add it to the media; --at places it on its track. Shared library assets (shared:...) are used where they are, not copied. Stickers sit at the bottom of the frame (at most 40% of its width, 30% of its height); --anchor puts a picture at another edge or corner, and --pop pops it in and out
                    credits          the credits block for the video description, and anything to sort out first
                    generate         make a sound effect or music cue with ElevenLabs (paid, one request per take)
                    install-starter  add the starter emoji, icons and logos to the catalogue
                    The library is per user, at ~/Library/Application Support/Tandem/Assets. The shared library folder, ~/Movies/Tandem Library, is the "shared" source.
                    """),
        CommandHelp(name: "segments", usage: "tandem segments list | save \"<name>\" (--clips <id,id> | --from <time> --to <time>) [--field <clip id>[=<label>]]... [--replace] | insert \"<name>\" --at <time> [--value <key>=<text>]... [--mode place|overwrite|insert]",
                    summary: "Reusable bits of timeline (intro, outro, like and subscribe) saved in the shared library: list them, save clips as one, put one on the timeline.",
                    options: ["clips", "from", "to", "field", "replace", "at", "value", "mode", "label"],
                    details: """
                    list     the segments in ~/Movies/Tandem Library/Segments, with their fields
                    save     save clips as a segment, with copies of the files they play beside it. --clips takes exactly those clips (linked ones aren't added); --from and --to take every clip wholly between them. --field clip_x=Title makes a title's words a field asked for on insert. --replace saves over one of the same name (files only the old one had stay, for the projects that play them; the rest goes to the Trash)
                    insert   put a segment on the timeline at --at, one undo step. Its files are used where they are in the library; archiving the project copies them in. --value key=text fills a field; --mode overwrite replaces what's in the way
                    The shared library's place is in Tandem's settings; $TANDEM_LIBRARY moves it for one command.
                    """),
        CommandHelp(name: "serve", usage: "tandem serve [--port <n>]", summary: "Open the project and serve the API until stopped (for agents, with the app closed).", options: ["port"]),
        CommandHelp(name: "mcp", usage: "tandem mcp", summary: "Run the MCP server on stdin and stdout.", options: [],
                    details: "Add it to Claude Code with: claude mcp add tandem -- ~/Applications/Tandem.app/Contents/MacOS/tandem mcp"),
        CommandHelp(name: "help", usage: "tandem help [<command> | <edit command>]", summary: "Show help, for a command or an edit command like addTransition.", options: [])
    ]

    static func command(_ name: String) -> CommandHelp? {
        commands.first { $0.name == name }
    }

    /// `tandem help <topic>`: a CLI command, an edit command from the
    /// schema (in any case, as agents type addtransition too), or both for
    /// a name that's each, like join.
    static func topic(_ name: String) -> String? {
        let edit = CommandCase(rawValue: name) ?? CommandCase.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
        let cli = command(name)
        switch (cli, edit) {
        case let (cli?, edit?): return detail(cli) + "\n\n" + CommandSchema.help(edit)
        case let (cli?, nil): return detail(cli)
        case let (nil, edit?): return CommandSchema.help(edit)
        case (nil, nil): return nil
        }
    }

    static var overview: String {
        var lines = [
            "tandem \(TandemAPI.version): edit Tandem video projects from the command line.",
            "",
            "Usage: tandem <command> [arguments] [options]",
            "",
            "Commands:"
        ]
        let width = commands.map(\.name.count).max() ?? 0
        for command in commands {
            lines.append("  \(command.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(command.summary)")
        }
        lines += [
            "",
            "Options for every command:",
            "  --project <path>  The .tandem file, or its folder. Default: the one in this folder or a parent.",
            "  --author <name>   Who edits are credited to. Default: $TANDEM_AUTHOR, or \"cli\".",
            "  --json            Print the result as JSON.",
            "",
            "Times are seconds (83.5) or mm:ss.mmm (01:23.500).",
            "When the Tandem app has the project open, commands go through the app; otherwise they open the file.",
            "Run `tandem help <command>` for more, and `tandem help <edit command>` (like addTransition) for an edit command's arguments and example."
        ]
        return lines.joined(separator: "\n")
    }

    static func detail(_ command: CommandHelp) -> String {
        var lines = ["Usage: \(command.usage)", "", command.summary]
        if !command.details.isEmpty { lines += ["", command.details] }
        lines += ["", "Also: --project <path>, --author <name>, --json."]
        return lines.joined(separator: "\n")
    }
}
