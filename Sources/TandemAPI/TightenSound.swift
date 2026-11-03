import Foundation
import TandemCore
import TandemMedia

/// Tighten's cuts, placed in the sound rather than the transcript's gaps.
///
/// Tighten used to cut the middle out of each gap between two transcript
/// words. Those words' edges come from where the waveform is over one floor
/// for the whole take, so a second speaker with no mic or an app talking
/// read as silence and got cut through (#11), and a word whose time was
/// 0.2 s off had its start cut off (#64). So each gap the transcript finds
/// is listened to on every track of the take that plays there
/// (`GapSound`): every cut goes in a real pause, the gap keeps Mike's keep
/// measured from the end of the last word's sound to the start of the
/// next, and no cut goes through sound. Then both sides of each join are
/// judged as `tandem check --cuts` would, and a join that isn't clean isn't
/// cut.
///
/// The CLI, MCP and the app's Tighten pauses all plan with this, so they
/// agree. Where any track playing a pause has a file whose sound can't be
/// read, that pause is planned from the transcript as before, with a
/// warning.
public enum SoundTightening {
    public struct Plan: Sendable {
        public var cuts: [PlannedCut] = []
        public var skipped: [SkippedPause] = []
        /// Pauses left alone for a protect time in them, as the transcript
        /// has them or as they're heard.
        public var protected: [Pause] = []
        public var warnings: [String] = []
    }

    /// The tracks a cut through the take is heard on: every unmuted audio
    /// track that ripples with the take (Voice, another mic, a device's own
    /// recording cut to match), or every unmuted audio track when none
    /// does. Music and sound effects aren't the take, and follow tracks
    /// aren't cut, so their sound is never cut through anyway. Video
    /// tracks' sound isn't played. Solo is left out on purpose: it's a way
    /// of listening, and a track that's only quiet because another is
    /// soloed is still in the video.
    public static func audibleTracks(_ project: Project) -> [Track] {
        let unmuted = project.audioTracks.filter { !$0.muted }
        let take = unmuted.filter { $0.rippleMode == .cut }
        return take.isEmpty ? unmuted : take
    }

    static func plays(_ clip: Clip, in project: Project) -> MediaItem? {
        guard TranscriptTools.isHeard(clip), let id = clip.mediaID, let item = project.media(id), item.hasAudio,
              item.role != .music, item.role != .sfx else { return nil }
        return item
    }

    /// Sound read either side of what a gap needs: the floor and speech
    /// level `CutPlacer` takes over 3 s, a second's chunk of floors, and
    /// the reach a join's judge looks over.
    static var readMargin: Double { CutAudit.around + CutAudit.reach + 1.5 }

    /// What `listen` heard: the sound under each pause (nil where it
    /// couldn't be heard) and the tracks it was heard on.
    struct Listening {
        var sounds: [GapSound?]
        var layers: [[SoundLayer]]
        /// Files whose sound couldn't be read.
        var unread: [String]
    }

    /// The words either side of a pause, in timeline seconds.
    static func words(around pause: Pause, in map: TranscriptTools.SpeechMap) -> (before: ClosedRange<Double>, after: ClosedRange<Double>)? {
        let tolerance = Time(seconds: 0.001)
        guard let before = map.words.filter({ $0.end <= pause.start + tolerance }).max(by: { $0.end < $1.end }),
              let after = map.words.first(where: { $0.start >= pause.end - tolerance }) else { return nil }
        return (before.start.seconds...max(before.start.seconds, before.end.seconds), after.start.seconds...max(after.start.seconds, after.end.seconds))
    }

    /// The timeline stretch `GapSound.listen` looks at for a pause.
    static func window(_ pause: Pause, before: ClosedRange<Double>, after: ClosedRange<Double>) -> ClosedRange<Double> {
        min(before.lowerBound - 0.1, pause.start.seconds - CutPlanner.slack)...max(after.upperBound + 0.1, pause.end.seconds + CutPlanner.slack)
    }

    static func listen(_ pauses: [Pause], map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder) async -> Listening {
        let tracks = audibleTracks(project)
        let around = pauses.map { words(around: $0, in: map) }
        let windows = zip(pauses, around).map { pause, words in words.map { window(pause, before: $0.before, after: $0.after) } }

        // Each file's stretches the pauses need, read once each.
        var needed: [String: [ClosedRange<Double>]] = [:]
        var items: [String: MediaItem] = [:]
        for window in windows.compactMap({ $0 }) {
            for track in tracks {
                for clip in track.clips where clip.start.seconds < window.upperBound && clip.end.seconds > window.lowerBound {
                    guard let item = plays(clip, in: project) else { continue }
                    let from = max(window.lowerBound, clip.start.seconds), to = min(window.upperBound, clip.end.seconds)
                    let media = { (time: Double) in clip.sourceStart.seconds + (time - clip.start.seconds) * clip.speed }
                    needed[item.id, default: []].append(max(0, media(from) - readMargin)...(media(to) + readMargin))
                    items[item.id] = item
                }
            }
        }
        var readings: [String: [CutPlacer]] = [:]
        var unread: [String] = []
        for (id, ranges) in needed.sorted(by: { $0.key < $1.key }) {
            guard let item = items[id] else { continue }
            var merged: [ClosedRange<Double>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, range.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            do {
                var energies: [SpeechEnergy] = []
                for range in merged {
                    energies.append(try await SpeechEnergy.read(url: folder.url(for: item), from: range.lowerBound, to: range.upperBound))
                }
                let levels = SpeechLevels(of: energies)
                readings[id] = energies.map { CutPlacer($0, levels: levels) }
            } catch {
                unread.append(item.path)
            }
        }

        var sounds: [GapSound?] = []
        var layers: [[SoundLayer]] = []
        for (index, pause) in pauses.enumerated() {
            guard let words = around[index], let window = windows[index] else {
                sounds.append(nil)
                layers.append([])
                continue
            }
            var heard: [SoundLayer] = []
            // The same file at the same point over the same stretch of the
            // timeline on two tracks is one sound. Every piece a track plays
            // counts, so two pieces of one file either side of a through
            // edit are both heard.
            var seen = Set<String>()
            // A track playing here whose file couldn't be read: nobody knows
            // what's on it, so the others can't call the pause quiet.
            var unheard = false
            for track in tracks {
                var pieces: [SoundLayer.Piece] = []
                var keys: [String] = []
                for clip in track.clips where clip.start.seconds < window.upperBound && clip.end.seconds > window.lowerBound {
                    guard let item = plays(clip, in: project) else { continue }
                    let start = clip.sourceStart.seconds, from = max(window.lowerBound, clip.start.seconds)
                    let media = start + (from - clip.start.seconds) * clip.speed
                    guard let placer = readings[item.id]?.first(where: { $0.energy.start <= media && media <= $0.energy.end }) else {
                        unheard = true
                        break
                    }
                    let key = "\(item.id)@\(((start - clip.start.seconds * clip.speed) * 1000).rounded())x\(clip.speed)@\(clip.start.flicks)-\(clip.end.flicks)"
                    keys.append(key)
                    guard !seen.contains(key) else { continue }
                    pieces.append(SoundLayer.Piece(timeline: clip.start.seconds..<clip.end.seconds, mediaStart: start, speed: clip.speed, placer: placer))
                }
                seen.formUnion(keys)
                if !pieces.isEmpty { heard.append(SoundLayer(name: track.name, pieces: pieces)) }
            }
            if unheard { heard = [] }
            layers.append(heard)
            sounds.append(heard.isEmpty ? nil : GapSound.listen(gap: pause.start.seconds...pause.end.seconds, before: words.before, after: words.after, layers: heard))
        }
        return Listening(sounds: sounds, layers: layers, unread: unread)
    }

    // MARK: - Phantom words

    /// The gap each side of a lone word that makes it worth listening to:
    /// a word alone between two pauses tighten would cut.
    static let phantomGap = Time(seconds: 0.5)
    /// The longest lone word that can be a phantom: the ones on the
    /// Threadbear launch video were "Yes." and "Yeah.", under half a second.
    static let phantomLength = Time(seconds: 1)

    /// The map without the transcript's phantom words, and those words.
    ///
    /// On the Threadbear launch video (November 2026) the transcript had
    /// "Yes." and "Yeah." three times in long pauses where the mic had only
    /// a foot tapping (-64 to -80 dB, and Whisper heard nothing there). Each
    /// split a long pause in two, and tighten kept each half's keep round a
    /// word that isn't there: about 1.6 s of silence. So a single short word
    /// between two gaps of `phantomGap` or more is listened to, as if it
    /// weren't in the transcript: when the gap from the word before to the
    /// word after has no voice where it is (quiet, faint sound, or a
    /// breath's hiss with nothing near the voice above 300 Hz: the third,
    /// "Yeah.", was hiss at -69 dB), it's left out. Only lone words between
    /// `from` and `to` are listened to.
    public static func withoutPhantoms(
        _ map: TranscriptTools.SpeechMap, from: Time? = nil, to: Time? = nil, project: Project, folder: ProjectFolder
    ) async -> (map: TranscriptTools.SpeechMap, phantoms: [TranscriptTools.SpokenWord]) {
        let words = map.words
        var lone: [Int] = []
        for index in words.indices.dropFirst().dropLast() {
            let word = words[index], before = words[index - 1], after = words[index + 1]
            guard word.end - word.start <= phantomLength, word.start - before.end >= phantomGap, after.start - word.end >= phantomGap else { continue }
            if let from, after.start < from { continue }
            if let to, before.end > to { continue }
            lone.append(index)
        }
        guard !lone.isEmpty else { return (map, []) }
        // Each lone word's gap, heard with it left out of the transcript.
        var without = map
        let loneSet = Set(lone)
        without.words = words.indices.filter { !loneSet.contains($0) }.map { words[$0] }
        let gaps = lone.map { index in
            let gap = TimeRange(start: words[index - 1].end, end: words[index + 1].start)
            return Pause(start: gap.start, end: gap.end, duration: gap.duration, before: words[index - 1].text, after: words[index + 1].text, clipIDs: [])
        }
        let heard = await listen(gaps, map: without, project: project, folder: folder)
        var phantoms = Set<Int>()
        for (number, index) in lone.enumerated() {
            guard let sound = heard.sounds[number], !sound.runsThrough else { continue }
            // Its sound can be part of a word either side's, with no pause
            // between ("Because," running into "to be honest" on the same
            // video): then it's said, and only a word wholly inside the gap
            // as it's heard can be a phantom.
            let tolerance = CutAudit.wordTolerance
            guard sound.span.lowerBound - tolerance <= words[index].start.seconds,
                  words[index].end.seconds <= sound.span.upperBound + tolerance else { continue }
            // Allowing for the transcript's word times being off the sound.
            let word = (words[index].start.seconds - CutPlanner.slack)...(words[index].end.seconds + CutPlanner.slack)
            if !sound.heard.contains(where: { $0.voiced && $0.range.overlaps(word) }) { phantoms.insert(index) }
        }
        guard !phantoms.isEmpty else { return (map, []) }
        var result = map
        result.words = words.indices.filter { !phantoms.contains($0) }.map { words[$0] }
        return (result, phantoms.sorted().map { words[$0] })
    }

    /// What `withoutPhantoms` left out, for warnings.
    public static func phantomWarning(_ phantoms: [TranscriptTools.SpokenWord]) -> [String] {
        guard !phantoms.isEmpty else { return [] }
        let list = phantoms.map { "\"\($0.text)\" at \($0.start)" }.joined(separator: ", ")
        return ["Left out \(list): the transcript has \(phantoms.count == 1 ? "a word" : "words") there, but the sound has no voice there, so the pauses either side are one. Listen with tandem clip if one should stay."]
    }

    /// A gap's sound as the service reports it.
    static func report(_ sound: GapSound) -> PauseSound {
        func time(_ seconds: Double) -> Time { Time(seconds: (seconds * 1000).rounded() / 1000) }
        return PauseSound(
            start: time(sound.span.lowerBound), end: time(sound.span.upperBound),
            duration: time(sound.span.upperBound) - time(sound.span.lowerBound),
            quiet: sound.pauses.map { TimeRange(start: time($0.lowerBound), end: time($0.upperBound)) },
            heard: sound.heard.map { HeardSound(start: time($0.range.lowerBound), end: time($0.range.upperBound), tracks: $0.layers) },
            runsThrough: sound.runsThrough
        )
    }

    /// The pauses with what's in the sound under each (`tandem pauses`).
    public static func listened(_ pauses: [Pause], map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder) async -> (pauses: [Pause], warnings: [String]) {
        let heard = await listen(pauses, map: map, project: project, folder: folder)
        var result = pauses
        for index in result.indices { result[index].sound = heard.sounds[index].map(report) }
        return (result, unreadWarnings(heard.unread, fallback: "so pauses there are as the transcript has them"))
    }

    static func unreadWarnings(_ unread: [String], fallback: String) -> [String] {
        unread.map { "Couldn't read the sound of \(URL(fileURLWithPath: $0).lastPathComponent), \(fallback)." }
    }

    /// The shortest gap in the transcript worth listening to for a rule's
    /// `minimum`: the minimum is measured on the sound, and the
    /// transcript's word edges can be `CutPlanner.slack` off it, so a 0.4 s
    /// gap in the transcript can be 0.7 s of quiet. Never under a real
    /// pause (`CutAudit.minPause`).
    static func shortestToListen(for minimum: Time) -> Time {
        Time(seconds: max(minimum.seconds - CutPlanner.slack, CutAudit.minPause))
    }

    /// The transcript's gaps that could be pauses the rules change, once
    /// measured from the sound, between `from` and `to`.
    public static func candidates(in map: TranscriptTools.SpeechMap, rules: TranscriptTools.PauseRules, from: Time? = nil, to: Time? = nil) -> [Pause] {
        TranscriptTools.pauses(in: map, minimum: shortestToListen(for: min(rules.minimum, rules.midMinimum)), from: from, to: to)
    }

    /// Plans the cuts for `pauses` (from `candidates`): in every real pause
    /// in each one's sound long enough to cut (`GapSound.place`), leaving
    /// the keep for what it follows between the two words' sound, on whole
    /// frames (`snug` as `TranscriptTools.plan` has it), with both sides of
    /// every join clean. A pause with any of `protect` in it, in the
    /// transcript's gap or the sound's, is left alone, and every cut stays
    /// between `from` and `to`.
    public static func plan(
        _ pauses: [Pause], rules: TranscriptTools.PauseRules, snug: Bool,
        protect: [Time] = [], from: Time? = nil, to: Time? = nil,
        map: TranscriptTools.SpeechMap, project: Project, folder: ProjectFolder
    ) async -> Plan {
        let rate = project.settings.frameRate
        let frame = rate.frameDuration
        // Pauses a protect time is in, as the transcript has them, as tighten
        // always listed them.
        let listed = min(rules.minimum, rules.midMinimum)
        var protected = pauses.filter { TranscriptTools.isProtected($0, by: protect) && $0.duration >= listed }
        // Only pauses the rules could change are listened to.
        let changing = pauses.filter { pause in
            let kind = TranscriptTools.pauseKind(after: pause.before)
            return rules.keep(for: kind) != nil && pause.duration >= shortestToListen(for: rules.shortest(for: kind))
                && !TranscriptTools.isProtected(pause, by: protect)
        }
        let heard = await listen(changing, map: map, project: project, folder: folder)
        var plan = Plan()
        var guessed = false
        // No margin when no track there carries a voice: nothing to clip.
        func side(_ join: GapSound.Join) -> CutJoinSide? {
            join.margin.map { CutJoinSide(verdict: join.verdict, margin: (Double($0) * 10).rounded() / 10) }
        }
        for (index, original) in changing.enumerated() {
            let kind = TranscriptTools.pauseKind(after: original.before)
            guard let keep = rules.keep(for: kind) else { continue }
            let shortest = rules.shortest(for: kind)
            guard let sound = heard.sounds[index] else {
                // No sound to go by: the transcript's gap, as tighten always
                // cut it (and only at the minimum measured there).
                let fallback = TranscriptTools.plan([original], rules: rules, frameRate: rate, snug: snug)
                guessed = guessed || !fallback.isEmpty
                plan.cuts += fallback
                continue
            }
            var pause = original
            pause.sound = report(sound)
            // Whether the pause is one the rules change by either measure,
            // so it's worth saying why it was left alone.
            let counts = original.duration >= shortest || sound.span.upperBound - sound.span.lowerBound >= shortest.seconds - 1e-9
            // The pause as it's heard can reach past the transcript's gap,
            // and a time protected there is protected too.
            if protect.contains(where: { sound.span.contains($0.seconds) }) {
                if counts { protected.append(original) }
                continue
            }
            func skip(_ reason: SkippedPause.Reason, start: CutJoinSide? = nil, end: CutJoinSide? = nil) {
                if counts { plan.skipped.append(SkippedPause(pause: pause, reason: reason, kind: kind, keep: keep, startEdge: start, endEdge: end)) }
            }
            let placements: [GapSound.Placement]
            switch sound.place(keep: keep.seconds, minimum: shortest.seconds, frame: frame.seconds) {
            case .success(let placed): placements = placed
            case .failure(.fits): continue
            case .failure(.speech): skip(.speech); continue
            case .failure(.sound): skip(.sound); continue
            case .failure(.short): skip(.short); continue
            }

            var cuts: [PlannedCut] = []
            var unclean: (start: CutJoinSide?, end: CutJoinSide?)?
            // Beside sound a cut takes out a real pause at least, or isn't worth its joins.
            let shortestCut = sound.heard.isEmpty ? frame : max(frame, Time(seconds: GapSound.shortestBesideSound))
            for placement in placements {
                guard var cut = frames(placement, snug: snug, from: from, to: to, rate: rate) else { continue }
                var joins = GapSound.judge(heard.layers[index], from: cut.start.seconds, to: cut.end.seconds)
                // A side that isn't clean moves a frame at a time further into
                // the quiet, away from the sound it clips, as long as the cut
                // still takes something out: keeping more of the pause than
                // the keep, never less.
                while joins.start.verdict != .clean || joins.end.verdict != .clean {
                    var moved = cut
                    if joins.start.verdict != .clean { moved = TimeRange(start: moved.start + frame, end: moved.end) }
                    if joins.end.verdict != .clean { moved = TimeRange(start: moved.start, end: moved.end - frame) }
                    guard moved.duration >= shortestCut else { break }
                    cut = moved
                    joins = GapSound.judge(heard.layers[index], from: cut.start.seconds, to: cut.end.seconds)
                }
                guard joins.start.verdict == .clean, joins.end.verdict == .clean else {
                    unclean = unclean ?? (side(joins.start), side(joins.end))
                    continue
                }
                cuts.append(PlannedCut(pause: pause, cut: cut, kind: kind, keep: keep, startEdge: side(joins.start), endEdge: side(joins.end)))
            }
            // A cut whose join wouldn't be clean is left out, and the others
            // in the pause still go: that keeps more than the keep, never less.
            if cuts.isEmpty, let unclean { skip(.notClean, start: unclean.start, end: unclean.end) }
            plan.cuts += cuts
        }
        if guessed {
            plan.warnings += unreadWarnings(heard.unread, fallback: "so pauses there were cut from the transcript's gaps alone. Listen to them")
            if heard.unread.isEmpty {
                plan.warnings.append("Some pauses have no sound to listen to, so they were cut from the transcript's gaps alone. Listen to them.")
            }
        } else {
            plan.warnings += unreadWarnings(heard.unread, fallback: "so it wasn't listened to")
        }
        plan.cuts.sort { $0.cut.start < $1.cut.start }
        plan.protected = protected.sorted { $0.start < $1.start }
        return plan
    }

    /// A cut on whole frames, inside its pause and the least kept at each
    /// end of it (`placement.earliest`, `latest`), and inside `from` and
    /// `to`, never leaving less than the keep. Nil when less than a frame
    /// of it is left.
    static func frames(_ placement: GapSound.Placement, snug: Bool, from: Time?, to: Time?, rate: FrameRate) -> TimeRange? {
        let frame = rate.frameDuration
        var lowest = TimeText.ceilToFrame(Time(seconds: placement.earliest), rate)
        var highest = TimeText.floorToFrame(Time(seconds: placement.latest), rate)
        var start = placement.from, end = placement.to
        if let from {
            lowest = max(lowest, TimeText.ceilToFrame(from, rate))
            start = max(start, from.seconds)
        }
        if let to {
            highest = min(highest, TimeText.floorToFrame(to, rate))
            end = min(end, to.seconds)
        }
        guard end > start else { return nil }
        if snug {
            var count = Int64(((end - start) / frame.seconds + 1e-9).rounded(.down))
            while count > 0 {
                let length = Time.frames(count, at: rate)
                let at = max(lowest, min(Time(seconds: start).roundedToFrame(rate), highest - length))
                if at >= lowest, at + length <= highest { return TimeRange(start: at, duration: length) }
                count -= 1
            }
            return nil
        }
        let first = max(lowest, TimeText.ceilToFrame(Time(seconds: start), rate))
        let last = min(highest, TimeText.floorToFrame(Time(seconds: end), rate))
        return last - first >= frame ? TimeRange(start: first, end: last) : nil
    }
}
