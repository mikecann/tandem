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

    /// The waits at the take's joins in `ranges`, and the rolls (with their
    /// commands) that take each down to `lead`. A join whose sound can't be
    /// read, or with no word within `LeadIn.reach`, isn't in it.
    /// - Parameter words: each file's transcript words (media time), by
    ///   media ID (`CutCheck.words`), so each join is judged as
    ///   `check --cuts` judges it.
    static func waits(
        project: Project, folder: ProjectFolder, ranges: [TimeRange], lead: Double, map: TranscriptTools.SpeechMap? = nil,
        words: [String: [CutAudit.Word]] = [:]
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
                guard levels.isVoice else { continue }
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
            for pair in join.heard {
                let start = pair.incoming.sourceStart.seconds, end = pair.outgoing.sourceEnd.seconds
                guard let incoming = placer(pair.incoming.mediaID, at: start + LeadIn.reach / 2),
                      let outgoing = placer(pair.outgoing.mediaID, at: end),
                      let onset = LeadIn.speechStart(incoming, after: start) else { continue joinLoop }
                wait = min(wait, onset - start)
                // The words round the join, as check --cuts takes them.
                let near = (end - CutAudit.around)...(start + LeadIn.reach + CutAudit.around)
                let said = (pair.incoming.mediaID.flatMap { words[$0] } ?? []).filter { $0.end >= near.lowerBound && $0.start <= near.upperBound }
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
            // Whole frames, so the cut stays on one.
            let frames = roll.isFinite ? Int64((roll * fps + 1e-6).rounded(.down)) : 0
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
        return (waits, unread)
    }
}
