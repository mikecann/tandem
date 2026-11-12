import Foundation
import TandemCore
import TandemMedia

/// Tighten the way Mike's old Filmora silence detection did (`tandem
/// tighten --filmora`): by how loud the take is, not by the transcript.
///
/// Anything quieter than the threshold (-35 dB) for at least the minimum
/// (0.5 s) is a silence, and each silence keeps the buffer (0.4 s) at both
/// ends, so a long pause comes out at 0.8 s and one under 0.8 s isn't
/// touched. That's Filmora's Volume Threshold, Minimum Duration and
/// Softening Buffer as Mike had them. Measured on his Filmora-cut AI Tips
/// video, no pause was longer than about 0.85 s.
///
/// Then each pause is cut to its kind (`FilmoraKind`): 0.12 s mid-phrase,
/// 0.2 s at a clause, 0.4 s between sentences, Filmora's 0.8 s at a new
/// topic, and a deliberate one kept. On the Convex Auth v2 cut (12 Nov 2026)
/// Filmora's 0.8 s everywhere drew 7 comments: 5 mid-sentence ("no big
/// pause") and 2 between sentences at 0.59 and 0.77 s ("longer than needed
/// pause here between sentences"). Bark puts a full stop wherever he pauses,
/// so the kind is read from the words by the agent doing the edit: the dry
/// run guesses, and `apply` needs every pause's kind given.
///
/// Why not the transcript's gaps (`SoundTightening`): on 12 Nov 2026 Mike
/// listened to one take cut five ways and picked this one. The transcript
/// rules closed sentence pauses to 0.4 s and mid-sentence ones to 0.11 s,
/// and left any pause with a breath or a noise in it whole, so the gaps ran
/// from 0.15 s to 1.6 s ("all over the place"). By volume, quiet noise is
/// silence too and every long pause lands at the same length. What it
/// keeps is anything loud enough, a stray "um" or "so" included, so cut
/// those with `tandem cut`.
public enum VolumeTightening {
    public struct Settings: Equatable, Sendable {
        /// Peak level, in dBFS, under which a frame is silent.
        public var threshold: Double
        /// The shortest silence that's cut.
        public var minimum: Double
        /// What a new topic's silence keeps at each end (Filmora's softening
        /// buffer). The other kinds keep `FilmoraKind.total`.
        public var buffer: Double
        /// The shortest clip a cut may leave between two others: a shorter
        /// one gets the pause beside it put back, if that pause is
        /// `putBackLimit` or less. 0 is no minimum. Filmora had no such
        /// setting; it's Mike's "no clips under 2 s" (Build Your Own Convex,
        /// Oct 2026), because a run of very short clips makes the picture
        /// jump about.
        public var minimumClip: Double = 0
        /// The longest pause put back for `minimumClip`: never a thinking
        /// pause or a long silence.
        public static let putBackLimit = 1.0
        /// Mike's Filmora settings. Its 25% volume threshold was matched
        /// to -35 dB on his recordings (automate-filmora's rough-cut plan).
        /// The minimum is 0.3 s rather than Filmora's 0.5 s, so a thinking
        /// pause of 0.3 to 0.5 s mid-sentence is closed too (his own trims
        /// on the Threadbear launch took gaps like that to 0.1 s).
        public static let filmora = Settings(threshold: -35, minimum: 0.3, buffer: 0.4, minimumClip: 0)

        /// What a pause of `kind` keeps after the word before and before
        /// the word after, nil when it's kept whole. A new topic splits
        /// evenly, as Filmora did; the rest keep about a third after the
        /// word (at least 40 ms, a word's tail) and the rest before the
        /// next (at least 70 ms, as a voice starts before its burst).
        func keeps(for kind: FilmoraKind) -> (after: Double, before: Double)? {
            guard let total = kind.total else { return nil }
            if kind == .topic { return (buffer, buffer) }
            let after = max(0.04, 0.35 * total)
            return (after, max(0.07, total - after))
        }
    }

    public struct Plan: Sendable {
        public var cuts: [PlannedCut] = []
        public var protected: [Pause] = []
        /// Cuts left out so no clip is under `Settings.minimumClip`.
        public var putBack: [PlannedCut] = []
        /// Every pause found, with its guessed and given kind.
        public var pauses: [FilmoraPause] = []
        /// Cuts left out because no place for them gave a clean join.
        public var notClean: [PlannedCut] = []
        public var warnings: [String] = []
    }

    /// Silent stretches of a run of frame levels: every frame under the
    /// threshold, for at least the minimum. `levels` nil is a frame nothing
    /// plays on, which is never silent: a hole in the take isn't a pause.
    static func silences(_ levels: [Float?], hiss: [Float]? = nil, start: Double, frame: Double, threshold: Double, minimum: Double) -> [ClosedRange<Double>] {
        var found: [ClosedRange<Double>] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let range = (start + Double(first) * frame)...(start + Double(end) * frame)
            if range.upperBound - range.lowerBound >= minimum - 1e-9 { found.append(range) }
        }
        for (index, level) in levels.enumerated() {
            // Quiet in the full band and above 4 kHz: a final "s" or "t"
            // under the threshold is still a word. A breath (-53 to -60 dB
            // on the Auth v2 take) is quiet in both, so it's pause.
            if let level, Double(level) < threshold, (hiss.map { index >= $0.count || $0[index] < hissFloor } ?? true) {
                if runStart == nil { runStart = index }
            } else {
                close(index)
            }
        }
        close(levels.count)
        return found
    }

    /// The cut in a silence: all but the buffer at each end, on whole
    /// frames (keeping more, never less). A silence that reaches the very
    /// start or end of the timeline has no word on that side, so it's cut
    /// right to the edge, as Filmora trims a recording's lead-in. Nil when
    /// less than a frame would go.
    static func cut(in silence: ClosedRange<Double>, buffer: Double, timelineEnd: Time, rate: FrameRate) -> TimeRange? {
        cut(in: silence, after: buffer, before: buffer, timelineEnd: timelineEnd, rate: rate)
    }

    /// Above 4 kHz, louder than this is a word's hiss (an "s", a "t"
    /// released), not the room.
    static let hissFloor: Float = -50

    /// Under these (RMS, and RMS above 4 kHz) a frame has no word in it:
    /// what the Auth v2 agent's hand cuts went by, which `check --cuts
    /// --listen` heard clean on all 63. A breath (-53 to -60 dB) is under.
    static let wordFloor: Float = -47
    static let wordHissFloor: Float = -58
    /// How far a word's soft edge is followed into a pause.
    static let edgeReach = 0.3

    /// The silence from where the word before it really ends to where the
    /// next really starts: each end moved in past any frame loud enough to
    /// be a word (`wordFloor`, `wordHissFloor`), up to `edgeReach`. Never
    /// past the timeline's own ends, which have no word beside them.
    static func speechEdges(_ silence: ClosedRange<Double>, rms: [Float], hiss: [Float], start: Double, frame: Double) -> ClosedRange<Double> {
        func index(_ time: Double) -> Int { Int(((time - start) / frame).rounded()) }
        let first = max(0, index(silence.lowerBound)), last = min(rms.count, hiss.count, index(silence.upperBound))
        guard first < last else { return silence }
        func word(_ i: Int) -> Bool { rms[i] >= wordFloor || hiss[i] >= wordHissFloor }
        let reach = Int((edgeReach / frame).rounded())
        var low = first
        // The last word-loud frame near the start, and the first near the end.
        if let tail = (first..<min(last, first + reach)).last(where: word) { low = tail + 1 }
        var high = last
        if let lead = (max(low, last - reach)..<last).first(where: word) { high = lead }
        guard high > low else { return silence.lowerBound...silence.lowerBound }
        let lower = silence.lowerBound <= 1e-6 ? silence.lowerBound : start + Double(low) * frame
        let upper = start + Double(high) * frame
        return lower...max(lower, min(silence.upperBound, upper))
    }

    static func cut(in silence: ClosedRange<Double>, after: Double, before: Double, timelineEnd: Time, rate: FrameRate) -> TimeRange? {
        let buffer = after
        let fps = rate.framesPerSecond
        let start = silence.lowerBound <= 1e-6
            ? Time.zero
            // Up to the next frame, so the buffer is kept whole; a hair's
            // tolerance so a time on a frame stays on it.
            : Time.frames(Int64(((silence.lowerBound + buffer) * fps - 1e-6).rounded(.up)), at: rate)
        // The levels stop at the last whole 5 ms frame, so a silence that
        // reaches within a frame of the end is at the end (29.97 fps
        // timelines rarely end on one).
        let end = silence.upperBound >= timelineEnd.seconds - SpeechEnergy.frameSeconds - 1e-6
            ? timelineEnd
            : Time.frames(Int64(((silence.upperBound - before) * fps + 1e-6).rounded(.down)), at: rate)
        guard end - start >= rate.frameDuration else { return nil }
        return TimeRange(start: start, end: end)
    }

    /// The loudest any take track is in each 5 ms frame from `from` to
    /// `to` (timeline seconds), nil where nothing on them plays, and the
    /// files that couldn't be read (whose stretches stay nil, so they're
    /// never cut).
    static func levels(from: Double, to: Double, project: Project, folder: ProjectFolder) async -> (levels: [Float?], hiss: [Float], rms: [Float], unread: [String]) {
        let frame = SpeechEnergy.frameSeconds
        let count = max(0, Int(((to - from) / frame).rounded(.down)))
        var levels = [Float?](repeating: nil, count: count)
        // The loudest any track is above 4 kHz in each frame: a word's
        // final "s" or "t" can be under the threshold and still be heard.
        var hiss = [Float](repeating: -120, count: count)
        // And how loud it is on average (RMS): where a word really ends.
        var rms = [Float](repeating: -120, count: count)
        var unread: [String] = []
        // A long take is read a minute of the file at a time, so a whole
        // hour's sound is never in memory at once, even sped up.
        let fileChunk = 60.0
        for track in SoundTightening.audibleTracks(project) {
            for clip in track.clips where clip.start.seconds < to && clip.end.seconds > from {
                guard let item = SoundTightening.plays(clip, in: project) else { continue }
                let clipFrom = max(from, clip.start.seconds), clipTo = min(to, clip.end.seconds)
                let speed = clip.speed
                let chunk = fileChunk / max(abs(speed), 1e-3)
                func media(_ time: Double) -> Double { clip.sourceStart.seconds + (time - clip.start.seconds) * speed }
                var piece = clipFrom
                while piece < clipTo {
                    let pieceEnd = min(clipTo, piece + chunk)
                    let energy: SpeechEnergy
                    do {
                        energy = try await SpeechEnergy.read(url: folder.url(for: item), from: media(piece) - frame, to: media(pieceEnd) + frame)
                    } catch {
                        if !unread.contains(item.path) { unread.append(item.path) }
                        break
                    }
                    let first = max(0, Int(((piece - from) / frame).rounded(.down)))
                    let last = min(count, Int(((pieceEnd - from) / frame).rounded(.up)))
                    if first < last {
                        for index in first..<last {
                            // A timeline frame at any speed covers this much
                            // of the file: its loudest sample counts.
                            let start = media(from + Double(index) * frame)
                            let end = media(from + Double(index + 1) * frame)
                            let a = energy.index(of: start), b = max(a, energy.index(of: end - 1e-9))
                            var loudest: Float?
                            for i in a...b where i >= 0 && i < energy.peak.count {
                                loudest = max(loudest ?? -120, energy.peak[i])
                                if i < energy.high.count { hiss[index] = max(hiss[index], energy.high[i]) }
                                if i < energy.full.count { rms[index] = max(rms[index], energy.full[i]) }
                            }
                            // Nothing measured (the file's last few ms, which
                            // don't fill a frame): never call it silent.
                            let level = loudest ?? 0
                            levels[index] = max(levels[index] ?? -120, level)
                        }
                    }
                    piece = pieceEnd
                }
            }
        }
        // An unread file's stretches stay unknown: never call them silent.
        if !unread.isEmpty {
            for track in SoundTightening.audibleTracks(project) {
                for clip in track.clips where clip.start.seconds < to && clip.end.seconds > from {
                    guard let item = SoundTightening.plays(clip, in: project), unread.contains(item.path) else { continue }
                    let first = max(0, Int(((clip.start.seconds - from) / frame).rounded(.down)))
                    let last = min(count, Int(((clip.end.seconds - from) / frame).rounded(.up)))
                    if first < last { for index in first..<last { levels[index] = 0 } }
                }
            }
        }
        return (levels, hiss, rms, unread)
    }

    /// Filmora's cuts over the timeline (or `from` to `to`): every silence
    /// on every take track at once, less a buffer at each end. A silence
    /// with a `protect` time in it is left alone.
    static func plan(
        settings: Settings, protect: [Time], kinds: [PauseKindMark] = [], from: Time?, to: Time?,
        map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder
    ) async -> Plan {
        var plan = Plan()
        let start = max(0, from?.seconds ?? 0)
        let end = min(project.duration.seconds, to?.seconds ?? project.duration.seconds)
        guard end > start else { return plan }
        let frame = SpeechEnergy.frameSeconds
        let read = await levels(from: start, to: end, project: project, folder: folder)
        if !read.unread.isEmpty {
            plan.warnings.append("Couldn't read the sound of \(read.unread.joined(separator: ", ")), so nothing it plays under was cut.")
        }
        let rate = project.settings.frameRate
        // Only the timeline's own ends are cut to the edge. A silence that
        // runs into a `from` or `to` inside the timeline keeps its keep
        // there, as if a word were beyond it.
        for silence in silences(read.levels, hiss: read.hiss, start: start, frame: frame, threshold: settings.threshold, minimum: settings.minimum) {
            let pause = Self.pause(silence, map: map, project: project)
            if protect.contains(where: { $0.seconds >= silence.lowerBound && $0.seconds <= silence.upperBound }) {
                plan.protected.append(pause)
                continue
            }
            let guess = Self.guess(silence, map: map)
            let marks = Set(kinds.filter { $0.at.seconds >= silence.lowerBound && $0.at.seconds <= silence.upperBound }.map(\.kind))
            // Two kinds in one pause: the pauses aren't the ones the kinds
            // were read for (other settings, or an edit since). Neither is
            // trusted, so it counts as not given and apply refuses.
            if marks.count > 1 {
                plan.warnings.append("The pause at \(pause.start)-\(pause.end) has \(marks.count) kinds given (\(marks.map(\.rawValue).sorted().joined(separator: ", "))): two pauses the kinds were read for are one now. Make the kinds file again with the same settings.")
            }
            let given = marks.count == 1 ? marks.first : nil
            plan.pauses.append(FilmoraPause(
                start: pause.start, end: pause.end, heard: pause.duration,
                before: Self.words(map, before: silence.lowerBound), after: Self.words(map, after: silence.upperBound),
                guess: guess, kind: given
            ))
            let kind = given ?? guess
            // The keep is measured from where the words really end and
            // start: a soft "v" or a vowel's onset can sit under the
            // threshold that found the pause ("We now have | north" lost the
            // end of "have" on the Auth v2 take).
            let speech = Self.speechEdges(silence, rms: read.rms, hiss: read.hiss, start: start, frame: frame)
            guard let keep = settings.keeps(for: kind),
                  let cut = cut(in: speech, after: keep.after, before: keep.before, timelineEnd: project.duration, rate: rate) else { continue }
            plan.cuts.append(PlannedCut(pause: pause, cut: cut, keep: Time(seconds: keep.after + keep.before), spoken: kind, guessed: given == nil))
        }
        // Each join judged as `check --cuts` would, and moved further into
        // the pause until it's clean, or the cut left out: a soft lead-in to
        // a word ("have | north" on the Auth v2 take) can read as pause by
        // volume and as voice to the ear.
        let judged = await judgingJoins(plan.cuts, project: project, folder: folder, rate: rate)
        plan.notClean = judged.notClean
        let (kept, putBack) = keepingClips(judged.kept, minimum: settings.minimumClip, timelineEnd: project.duration)
        plan.cuts = kept
        plan.putBack = putBack
        return plan
    }

    /// The cuts with each join judged on every take track that plays there
    /// (`GapSound.judge`, as `check --cuts` judges): a side that isn't clean
    /// moves a frame at a time into the pause, keeping more of it, while the
    /// cut still takes out a frame; a cut that can't be made clean is left
    /// out. Where a file can't be read the cut stays as planned.
    static func judgingJoins(_ cuts: [PlannedCut], project: Project, folder: ProjectFolder, rate: FrameRate) async -> (kept: [PlannedCut], notClean: [PlannedCut]) {
        guard !cuts.isEmpty else { return (cuts, []) }
        let tracks = SoundTightening.audibleTracks(project)
        let margin = SoundTightening.readMargin
        // How far either side of an edge it can move or is judged over.
        let around = 1.0
        // Only the sound round each edge is read, never the whole of a
        // long cut, so a long take is never in memory at once.
        func windows(_ cut: TimeRange) -> [ClosedRange<Double>] {
            [(cut.start.seconds - around)...(cut.start.seconds + around), (cut.end.seconds - around)...(cut.end.seconds + around)]
        }
        var needed: [String: [ClosedRange<Double>]] = [:]
        var items: [String: MediaItem] = [:]
        for cut in cuts {
            for window in windows(cut.cut) {
                for track in tracks {
                    for clip in track.clips where clip.start.seconds < window.upperBound && clip.end.seconds > window.lowerBound {
                        guard let item = SoundTightening.plays(clip, in: project) else { continue }
                        func media(_ time: Double) -> Double { clip.sourceStart.seconds + (time - clip.start.seconds) * clip.speed }
                        let from = max(clip.start.seconds, window.lowerBound), to = min(clip.end.seconds, window.upperBound)
                        guard to > from else { continue }
                        needed[item.id, default: []].append(max(0, min(media(from), media(to)) - margin)...(max(media(from), media(to)) + margin))
                        items[item.id] = item
                    }
                }
            }
        }
        var readings: [String: [CutPlacer]] = [:]
        for (id, ranges) in needed {
            guard let item = items[id] else { continue }
            var merged: [ClosedRange<Double>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                // Neighbouring edges merge only while the read stays short.
                if let last = merged.last, range.lowerBound <= last.upperBound, range.upperBound - last.lowerBound <= 60 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            guard let energies = try? await merged.asyncMap({ try await SpeechEnergy.read(url: folder.url(for: item), from: $0.lowerBound, to: $0.upperBound) }) else { continue }
            let levels = SpeechLevels(of: energies)
            readings[id] = energies.map { CutPlacer($0, levels: levels) }
        }

        /// The take's tracks round one edge, each clip with the reading
        /// that holds that edge.
        func layers(at edge: Double) -> [SoundLayer]? {
            var layers: [SoundLayer] = []
            for track in tracks {
                var pieces: [SoundLayer.Piece] = []
                for clip in track.clips where clip.start.seconds < edge + around && clip.end.seconds > edge - around {
                    guard let item = SoundTightening.plays(clip, in: project) else { continue }
                    let at = min(max(edge, clip.start.seconds), clip.end.seconds)
                    let media = clip.sourceStart.seconds + (at - clip.start.seconds) * clip.speed
                    // The reading the edge sits deepest in, so the sound either
                    // side of it, and as far as the edge may move, is in it.
                    guard let placer = readings[item.id]?
                        .filter({ $0.energy.start <= media && media <= $0.energy.end })
                        .max(by: { min(media - $0.energy.start, $0.energy.end - media) < min(media - $1.energy.start, $1.energy.end - media) })
                    else { return nil }
                    pieces.append(SoundLayer.Piece(timeline: clip.start.seconds..<clip.end.seconds, mediaStart: clip.sourceStart.seconds, speed: clip.speed, placer: placer))
                }
                if !pieces.isEmpty { layers.append(SoundLayer(name: track.name, pieces: pieces)) }
            }
            return layers.isEmpty ? nil : layers
        }

        var kept: [PlannedCut] = [], notClean: [PlannedCut] = []
        let frame = rate.frameDuration
        for planned in cuts {
            // Unheard (a file that can't be read): the cut stays as planned.
            guard let startLayers = layers(at: planned.cut.start.seconds), let endLayers = layers(at: planned.cut.end.seconds) else {
                kept.append(planned)
                continue
            }
            // Each side judged on the sound read round it.
            func judge(_ cut: TimeRange) -> (start: CutAudit.Verdict, end: CutAudit.Verdict) {
                (GapSound.judge(startLayers, from: cut.start.seconds, to: cut.end.seconds).start.verdict,
                 GapSound.judge(endLayers, from: cut.start.seconds, to: cut.end.seconds).end.verdict)
            }
            var cut = planned.cut
            var joins = judge(cut)
            // The timeline's own ends have nothing beside them to clip.
            let atStart = cut.start == .zero, atEnd = cut.end >= project.duration
            func clean(_ joins: (start: CutAudit.Verdict, end: CutAudit.Verdict)) -> Bool {
                (joins.start == .clean || atStart) && (joins.end == .clean || atEnd)
            }
            // A side moves at most `around` into the pause, where it was read.
            let limit = Time(seconds: around - 0.05)
            while !clean(joins) {
                var moved = cut
                if joins.start != .clean && !atStart { moved = TimeRange(start: moved.start + frame, end: moved.end) }
                if joins.end != .clean && !atEnd { moved = TimeRange(start: moved.start, end: moved.end - frame) }
                guard moved.duration >= frame, moved.start - planned.cut.start <= limit, planned.cut.end - moved.end <= limit else { break }
                cut = moved
                joins = judge(cut)
            }
            var judged = planned
            judged.cut = cut
            if clean(joins) { kept.append(judged) } else { notClean.append(planned) }
        }
        return (kept, notClean)
    }

    /// About eight words before `time`, and after it, for reading a
    /// pause's kind.
    static func words(_ map: TranscriptTools.SpeechMap, before time: Double) -> String {
        let index = map.words.firstIndex { $0.start.seconds >= time } ?? map.words.count
        return TranscriptTools.context(map.words, upTo: index, count: 8)
    }

    static func words(_ map: TranscriptTools.SpeechMap, after time: Double) -> String {
        let index = map.words.firstIndex { $0.start.seconds >= time - 0.15 } ?? map.words.count
        return TranscriptTools.context(map.words, from: index, count: 8)
    }

    /// The cuts with the pause put back beside every clip shorter than
    /// `minimum` that one could lengthen: of the two cuts round it, the one
    /// that takes out less, if it takes out `putBackLimit` or less. Putting
    /// one back joins the clip to its neighbour, so it goes round again
    /// until nothing changes. The timeline's first and last pieces don't
    /// count: they're the take's lead-in and run-out.
    static func keepingClips(_ cuts: [PlannedCut], minimum: Double, timelineEnd: Time? = nil) -> (kept: [PlannedCut], putBack: [PlannedCut]) {
        guard minimum > 0 else { return (cuts, []) }
        var kept = cuts.sorted { $0.cut.start < $1.cut.start }
        var putBack: [PlannedCut] = []
        var changed = true
        while changed {
            changed = false
            for index in kept.indices.dropFirst() {
                let clip = (kept[index].cut.start - kept[index - 1].cut.end).seconds
                guard clip < minimum - 1e-9 else { continue }
                // After a cut of the lead-in, or before one of the run-out,
                // it's the video's first or last clip: no clip beside it to
                // join.
                if kept[index - 1].cut.start == .zero { continue }
                if let timelineEnd, kept[index].cut.end >= timelineEnd { continue }
                let shorter = kept[index - 1].cut.duration <= kept[index].cut.duration ? index - 1 : index
                let other = shorter == index ? index - 1 : index
                // The shorter pause if it's short enough, or else the other.
                // Only one between sentences or topics: putting back a
                // thinking pause mid-sentence is the big pause Mike doesn't
                // want.
                guard let back = [shorter, other].first(where: {
                    kept[$0].cut.duration.seconds <= Settings.putBackLimit + 1e-9
                        && (kept[$0].kind ?? .sentence) == .sentence && [nil, .sentence, .topic].contains(kept[$0].spoken)
                }) else { continue }
                putBack.append(kept.remove(at: back))
                changed = true
                break
            }
        }
        return (kept, putBack.sorted { $0.cut.start < $1.cut.start })
    }

    /// Words that start a clause after a pause with no punctuation.
    static let clauseStarters: Set<String> = ["and", "but", "so", "because", "which", "if", "or", "where", "when", "while", "then"]

    /// The dry run's guess at a pause's kind, from the transcript: a
    /// starting point for the agent, who reads the words and decides. With
    /// no word before or after (the take's start or end, or sound no word
    /// accounts for at the edge), it's a sentence's: the safe side.
    static func guess(_ silence: ClosedRange<Double>, map: TranscriptTools.SpeechMap) -> FilmoraKind {
        let reach = 1.0
        guard let before = map.words.last(where: { $0.start.seconds < silence.lowerBound }),
              before.end.seconds > silence.lowerBound - reach,
              let after = map.words.first(where: { $0.start.seconds >= silence.upperBound - 0.15 }),
              after.start.seconds < silence.upperBound + reach,
              // Between them, sound the transcript doesn't cover (another
              // clip, no transcript) could end a sentence of its own.
              !map.unknown.contains(where: { $0.overlaps(TimeRange(start: before.end, end: max(before.end, after.start))) })
        else { return .sentence }
        let next = after.text.lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        switch TranscriptTools.spokenKind(after: before.text) {
        case .mid: return clauseStarters.contains(next) ? .clause : .mid
        case .comma: return .clause
        case .sentence: return silence.upperBound - silence.lowerBound > 1.5 ? .topic : .sentence
        }
    }

    /// A silence as a `Pause`, with the words either side for the plan.
    static func pause(_ silence: ClosedRange<Double>, map: TranscriptTools.SpeechMap, project: Project) -> Pause {
        let start = Time(seconds: silence.lowerBound), end = Time(seconds: silence.upperBound)
        // Word times can be a little off the sound, so a word half inside
        // the silence still counts as the one before or after it.
        let middle = Time(seconds: (silence.lowerBound + silence.upperBound) / 2)
        let after = map.words.firstIndex { $0.start >= middle } ?? map.words.count
        let clips = SoundTightening.audibleTracks(project).flatMap(\.clips)
            .filter { $0.start < end && $0.end > start }.map(\.id)
        return Pause(
            start: start, end: end, duration: end - start,
            before: TranscriptTools.context(map.words, upTo: after),
            after: TranscriptTools.context(map.words, from: after),
            clipIDs: clips
        )
    }
}

extension Array {
    /// Each element mapped in turn, awaiting each.
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
