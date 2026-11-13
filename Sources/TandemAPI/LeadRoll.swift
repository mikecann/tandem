import Foundation
import TandemCore
import TandemMedia

/// `tandem tighten --lead-only`, and the waits `tandem check` notes: at
/// every join between two pieces of a take, how long the clip coming in
/// runs before his first word, and the roll that starts it `lead` before
/// the word and gives the rest to the end of the clip going out (`LeadIn`).
///
/// It's how the hand-made fix on the Let's Build It edit (13 Nov 2026) went:
/// the word's start found in the take's own sound, `lead` left, the rest
/// rolled across the join on whole frames. The clip going out only grows
/// through quiet (no word or click of what was cut), and never into what
/// the clip coming in plays. The timeline keeps its length and every other
/// clip stays put.
enum LeadRoll {
    /// The clip coming in keeps at least this after a roll.
    static let shortestLeft = 0.3
    /// Read either side of each edge: `CutAudit.around` for the floor, and
    /// how far a word is looked for.
    static var margin: Double { CutAudit.around + 0.1 }

    /// The words `check --cuts` judges an edge at `time` with: 3 s either
    /// side of it, and all of the stretch cut at the join with 3 s past it
    /// (`CutCheck.run`). With other words the transcript's rules come out
    /// differently.
    static func said(_ words: [CutAudit.Word], at time: Double, removed: ClosedRange<Double>) -> [CutAudit.Word] {
        let window = CutCheck.window
        let reach = min(time - window, removed.lowerBound)...max(time + window, removed.upperBound + window)
        return words.filter { $0.end >= reach.lowerBound && $0.start <= reach.upperBound }
    }

    /// The waits at the take's joins in `ranges`, and the rolls (with their
    /// commands) that take each down to `lead`. A join whose sound can't be
    /// read, or with no word within `LeadIn.reach`, isn't in it.
    /// - Parameter words: each file's transcript words (media time), by
    ///   media ID (`CutCheck.words`), so each join is judged as
    ///   `check --cuts` judges it.
    static func waits(
        project: Project, folder: ProjectFolder, ranges: [TimeRange], lead: Double, map: TranscriptTools.SpeechMap? = nil,
        words: [String: [CutAudit.Word]] = [:], verify: Bool = false
    ) async -> (waits: [QualityCheck.FaceWait], unread: [String]) {
        let speech = Set(TranscriptTools.speechTracks(project).map(\.id))
        let joins = QualityCheck.takeJoins(in: project, ranges: ranges, speechTrackIDs: speech)
        guard !joins.isEmpty else { return ([], []) }

        // One read for each stretch of a file the joins' sound is in.
        var needed: [String: [ClosedRange<Double>]] = [:]
        for join in joins {
            for pair in join.heard {
                guard let id = pair.incoming.mediaID else { continue }
                let from = pair.outgoing.sourceEnd.seconds, to = pair.incoming.sourceStart.seconds
                needed[id, default: []] += [(from - margin)...(from + margin), (to - margin)...(to + LeadIn.reach + margin)]
            }
        }
        var placers: [String: [CutPlacer]] = [:]
        var unread: [String] = []
        // Read fine, but no voice in it (a screen recording's own sound,
        // mostly digital silence): nothing there to clip or wait for.
        var silent: Set<String> = []
        for (id, ranges) in needed {
            guard let item = project.media(id) else { continue }
            var merged: [ClosedRange<Double>] = []
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let range = max(0, range.lowerBound)...range.upperBound
                // Neighbouring joins merge only while the read stays short.
                if let last = merged.last, range.lowerBound <= last.upperBound, range.upperBound - last.lowerBound <= 60 {
                    merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
                } else {
                    merged.append(range)
                }
            }
            do {
                var readings: [SpeechEnergy] = []
                for range in merged {
                    readings.append(try await SpeechEnergy.read(url: folder.url(for: item), from: range.lowerBound, to: range.upperBound))
                }
                let levels = SpeechLevels(of: readings)
                guard levels.isVoice else { silent.insert(id); continue }
                placers[id] = readings.map { CutPlacer($0, levels: levels) }
            } catch {
                unread.append(URL(fileURLWithPath: item.path).lastPathComponent)
            }
        }
        /// The reading `time` sits deepest in, so the sound either side is in it.
        func placer(_ id: String?, at time: Double) -> CutPlacer? {
            guard let id else { return nil }
            return placers[id]?
                .filter { $0.energy.start <= time && time <= $0.energy.end }
                .max { min(time - $0.energy.start, $0.energy.end - time) < min(time - $1.energy.start, $1.energy.end - time) }
        }

        let rate = project.settings.frameRate
        let fps = rate.framesPerSecond
        var waits: [QualityCheck.FaceWait] = []
        joinLoop: for join in joins {
            // The word's start on every speech track there; the earliest
            // counts. Then how far each side can go.
            var wait = Double.infinity, roll = Double.infinity
            // Each speech track's sound and words, to judge the roll it ends up with.
            var judged: [(incoming: CutPlacer, outgoing: CutPlacer, start: Double, end: Double, words: [CutAudit.Word])] = []
            for pair in join.heard {
                if pair.incoming.mediaID.map(silent.contains) ?? false { continue }
                let start = pair.incoming.sourceStart.seconds, end = pair.outgoing.sourceEnd.seconds
                guard let incoming = placer(pair.incoming.mediaID, at: start + LeadIn.reach / 2),
                      let outgoing = placer(pair.outgoing.mediaID, at: end),
                      let onset = LeadIn.speechStart(incoming, after: start) else { continue joinLoop }
                wait = min(wait, onset - start)
                let all = pair.incoming.mediaID.flatMap { words[$0] } ?? []
                judged.append((incoming, outgoing, start, end, all))
                let said = Self.said(all, at: start, removed: end...start)
                guard let edge = LeadIn.start(incoming, onset: onset, lead: lead, earliest: start, outgoingEnd: end, transcript: said) else {
                    roll = 0
                    continue
                }
                // The clip going out grows only through quiet, and never
                // into what the clip coming in plays.
                let want = min(edge - start, start - end, pair.incoming.duration.seconds - shortestLeft)
                roll = min(roll, want <= 0 ? 0 : LeadIn.quietAfter(outgoing, from: end, limit: want, incomingStart: start, transcript: said))
            }
            guard wait.isFinite else { continue }
            // Every clip the roll moves (camera, screen, voice) has to take
            // it: the one coming in keeps `shortestLeft`, the one going out
            // stays short of what the next plays and inside its file, or
            // `Editing.roll` would refuse the whole batch.
            for pair in join.pairs {
                roll = min(roll, pair.incoming.duration.seconds - shortestLeft, (pair.incoming.sourceStart - pair.outgoing.sourceEnd).seconds)
                if let length = pair.outgoing.mediaID.flatMap(project.media)?.duration {
                    roll = min(roll, (length - pair.outgoing.sourceEnd).seconds)
                }
            }
            // Whole frames, so the cut stays on one. The roll it comes to can
            // be less than the edge judged above (the clip going out ran
            // into sound, say), so both sides are judged again where they
            // land, as check --cuts will, a frame less at a time until clean.
            var frames = roll.isFinite ? Int64((roll * fps + 1e-6).rounded(.down)) : 0
            func clean(_ frames: Int64) -> Bool {
                let r = Time.frames(frames, at: rate).seconds
                return judged.allSatisfy { side in
                    let removed = (side.end + r)...(side.start + r)
                    return side.incoming.judge(at: side.start + r, keeps: .after, removed: removed, transcript: Self.said(side.words, at: side.start + r, removed: removed)).verdict == .clean
                        && side.outgoing.judge(at: side.end + r, keeps: .before, removed: removed, cutAway: removed, transcript: Self.said(side.words, at: side.end + r, removed: removed)).verdict == .clean
                }
            }
            while frames > 0, !clean(frames) { frames -= 1 }
            let moved = frames > 0 ? Time.frames(frames, at: rate) : nil
            let commands = moved.map { delta in
                join.rolled.map { EditCommand.roll(leftClipID: $0.outgoing.id, rightClipID: $0.incoming.id, delta: delta) }
            } ?? []
            let words = map.map { map in
                map.words.filter { $0.start >= join.time - Time(seconds: 0.15) }.prefix(6).map(\.text).joined(separator: " ")
            } ?? ""
            waits.append(QualityCheck.FaceWait(
                time: join.time, wait: Time(seconds: (wait * 1000).rounded() / 1000), roll: moved, commands: commands, words: words,
                clipIDs: join.heard.flatMap { [$0.outgoing.id, $0.incoming.id] }
            ))
        }
        return (verify ? await verified(waits, project: project, folder: folder, words: words) : waits, unread)
    }

    /// The rolls checked by `check --cuts` itself: each join is judged on
    /// the edit as it would be after them, and a roll whose join that flags
    /// (when it didn't before) is dropped, until none does. Judging each
    /// edge here with the same calls wasn't enough: check reads its own
    /// stretches of the file, whose 5 ms frames fall elsewhere, and on the
    /// Let's Build It take that moved the floor 0.2 dB and flipped a
    /// borderline edge to clipped.
    static func verified(
        _ waits: [QualityCheck.FaceWait], project: Project, folder: ProjectFolder, words: [String: [CutAudit.Word]]
    ) async -> [QualityCheck.FaceWait] {
        var waits = waits
        guard waits.contains(where: { $0.roll != nil }) else { return waits }
        // The whole edit, as `tandem check --cuts` reads it: checking only
        // round the joins reads other stretches of the file, and a
        // borderline edge came out clean there and clipped in the full check.
        func ranges() -> [TimeRange] { [TimeRange(start: .zero, end: project.duration)] }
        func flagged(_ outcome: CutCheck.Outcome) -> Set<String> {
            Set(outcome.problems.compactMap { $0.cut.map { "\($0.clipID)/\($0.edge.rawValue)" } })
        }
        let before = flagged(await CutCheck.run(project: project, folder: folder, ranges: ranges(), words: words))
        for _ in 0..<4 {
            var rolled = project
            var context = EditContext()
            do {
                for command in waits.flatMap(\.commands) { try Editing.apply(command, to: &rolled, context: &context) }
            } catch {
                // A roll the editor won't take: none of them go.
                return waits.map { var wait = $0; wait.roll = nil; wait.commands = []; return wait }
            }
            let fresh = flagged(await CutCheck.run(project: rolled, folder: folder, ranges: ranges(), words: words)).subtracting(before)
            guard !fresh.isEmpty else { return waits }
            var dropped = false
            for index in waits.indices where waits[index].roll != nil {
                let clips = Set(waits[index].commands.flatMap { command -> [String] in
                    if case .roll(let left, let right, _) = command { return [left, right] }
                    return []
                } + waits[index].clipIDs)
                if fresh.contains(where: { clips.contains(String($0.split(separator: "/").first ?? "")) }) {
                    waits[index].roll = nil
                    waits[index].commands = []
                    dropped = true
                }
            }
            // Flagged somewhere none of the rolls touch: leave them be.
            if !dropped { return waits }
        }
        return waits
    }
}
