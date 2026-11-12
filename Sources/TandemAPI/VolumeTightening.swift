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
        /// What each silence keeps at each end.
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
        /// What a silence after a comma, and one mid-sentence, keeps at
        /// each end. Filmora kept 0.4 s everywhere, and a 0.8 s pause
        /// mid-sentence sounds broken: "don't forget mid sentence no big
        /// pause" (Convex Auth v2, 12 Nov 2026). At -35 dB a word's tail is
        /// already well inside what's kept, so these come out about where
        /// `--mike` put them (0.12 s after a comma, about 0.1 s mid-sentence).
        public var commaBuffer = 0.1
        public var midBuffer = 0.08

        func buffer(for kind: PauseKind) -> Double {
            switch kind {
            case .sentence: return buffer
            case .comma: return commaBuffer
            case .mid: return midBuffer
            }
        }

        /// Mike's Filmora settings. Its 25% volume threshold was matched
        /// to -35 dB on his recordings (automate-filmora's rough-cut plan).
        public static let filmora = Settings(threshold: -35, minimum: 0.5, buffer: 0.4, minimumClip: 2)
    }

    public struct Plan: Sendable {
        public var cuts: [PlannedCut] = []
        public var protected: [Pause] = []
        /// Cuts left out so no clip is under `Settings.minimumClip`.
        public var putBack: [PlannedCut] = []
        public var warnings: [String] = []
    }

    /// Silent stretches of a run of frame levels: every frame under the
    /// threshold, for at least the minimum. `levels` nil is a frame nothing
    /// plays on, which is never silent: a hole in the take isn't a pause.
    static func silences(_ levels: [Float?], start: Double, frame: Double, threshold: Double, minimum: Double) -> [ClosedRange<Double>] {
        var found: [ClosedRange<Double>] = []
        var runStart: Int?
        func close(_ end: Int) {
            guard let first = runStart else { return }
            runStart = nil
            let range = (start + Double(first) * frame)...(start + Double(end) * frame)
            if range.upperBound - range.lowerBound >= minimum - 1e-9 { found.append(range) }
        }
        for (index, level) in levels.enumerated() {
            if let level, Double(level) < threshold {
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
    /// Kept past the last hiss at a silence's end.
    static let hissPad = 0.03

    /// What a short keep leaves after the word before and before the word
    /// after: `buffer`, or more where hiss runs on into the silence (up to
    /// `limit`, the sentence buffer).
    static func clearOfHiss(_ silence: ClosedRange<Double>, buffer: Double, limit: Double, hiss: [Float], start: Double, frame: Double) -> (after: Double, before: Double) {
        func index(_ time: Double) -> Int { Int(((time - start) / frame).rounded(.down)) }
        let first = max(0, index(silence.lowerBound)), last = min(hiss.count, index(silence.upperBound))
        guard first < last else { return (buffer, buffer) }
        let reach = Int((limit / frame).rounded(.down))
        var after = buffer, before = buffer
        // The last hissing frame near the start, and the first near the end.
        if let tail = (first..<min(last, first + reach)).last(where: { hiss[$0] >= hissFloor }) {
            after = min(limit, max(buffer, Double(tail + 1) * frame + start - silence.lowerBound + hissPad))
        }
        if let lead = (max(first, last - reach)..<last).first(where: { hiss[$0] >= hissFloor }) {
            before = min(limit, max(buffer, silence.upperBound - (Double(lead) * frame + start) + hissPad))
        }
        return (after, before)
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
    static func levels(from: Double, to: Double, project: Project, folder: ProjectFolder) async -> (levels: [Float?], hiss: [Float], unread: [String]) {
        let frame = SpeechEnergy.frameSeconds
        let count = max(0, Int(((to - from) / frame).rounded(.down)))
        var levels = [Float?](repeating: nil, count: count)
        // The loudest any track is above 4 kHz in each frame: a word's
        // final "s" or "t" can be under the threshold and still be heard.
        var hiss = [Float](repeating: -120, count: count)
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
        return (levels, hiss, unread)
    }

    /// Filmora's cuts over the timeline (or `from` to `to`): every silence
    /// on every take track at once, less a buffer at each end. A silence
    /// with a `protect` time in it is left alone.
    static func plan(
        settings: Settings, protect: [Time], midAt: [Time] = [], sentenceAt: [Time] = [], from: Time?, to: Time?,
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
        // runs into a `from` or `to` inside the timeline keeps its buffer
        // there, as if a word were beyond it.
        for silence in silences(read.levels, start: start, frame: frame, threshold: settings.threshold, minimum: settings.minimum) {
            let pause = Self.pause(silence, map: map, project: project)
            if protect.contains(where: { $0.seconds >= silence.lowerBound && $0.seconds <= silence.upperBound }) {
                plan.protected.append(pause)
                continue
            }
            func marked(_ times: [Time]) -> Bool { times.contains { $0.seconds >= silence.lowerBound && $0.seconds <= silence.upperBound } }
            let kind: PauseKind = marked(sentenceAt) ? .sentence : marked(midAt) ? .mid : Self.kind(of: silence, map: map)
            let buffer = settings.buffer(for: kind)
            // A short keep moves out past any hiss at the silence's ends, so a
            // soft final "s" under the threshold isn't cut off; never past
            // the sentence buffer.
            let (after, before) = kind == .sentence ? (buffer, buffer)
                : clearOfHiss(silence, buffer: buffer, limit: settings.buffer, hiss: read.hiss, start: start, frame: frame)
            guard let cut = cut(in: silence, after: after, before: before, timelineEnd: project.duration, rate: rate) else { continue }
            plan.cuts.append(PlannedCut(pause: pause, cut: cut, kind: kind, keep: Time(seconds: after + before)))
        }
        let (kept, putBack) = keepingClips(plan.cuts, minimum: settings.minimumClip, timelineEnd: project.duration)
        plan.cuts = kept
        plan.putBack = putBack
        return plan
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
                // Only one between sentences: putting back a thinking pause
                // mid-sentence is the big pause Mike doesn't want.
                guard let back = [shorter, other].first(where: {
                    kept[$0].cut.duration.seconds <= Settings.putBackLimit + 1e-9 && (kept[$0].kind ?? .sentence) == .sentence
                }) else { continue }
                putBack.append(kept.remove(at: back))
                changed = true
                break
            }
        }
        return (kept, putBack.sorted { $0.cut.start < $1.cut.start })
    }

    /// What a silence follows, by the word before it as it's spoken
    /// (`TranscriptTools.spokenKind`). With no word before or after (the
    /// take's start or end, or sound no word accounts for at the edge),
    /// it's a sentence's: the long keep is the safe one.
    static func kind(of silence: ClosedRange<Double>, map: TranscriptTools.SpeechMap) -> PauseKind {
        // The word that ends at the silence (started before it) and the one
        // that starts after it. A word starting inside the silence is a
        // phantom or a mumble and doesn't count; words far from the
        // silence (sound no transcript covers in between) say nothing
        // about it.
        let reach = 1.0
        guard let before = map.words.last(where: { $0.start.seconds < silence.lowerBound + 0.05 }),
              before.end.seconds > silence.lowerBound - reach,
              let after = map.words.first(where: { $0.start.seconds >= silence.upperBound - 0.15 }),
              after.start.seconds < silence.upperBound + reach else { return .sentence }
        return TranscriptTools.spokenKind(after: before.text)
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
