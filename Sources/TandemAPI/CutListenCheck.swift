import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// One join heard by `tandem check --cuts --listen`.
public struct HeardJoin: Codable, Equatable, Sendable {
    /// Where the join is on the timeline.
    public var time: Time
    /// The take's kept words across it (the transcript as the clips play
    /// it), " | " at the join.
    public var said: String
    /// What the engine heard across it.
    public var heard: String
    /// What doesn't match near the join. A `slip` finding is as likely the
    /// engine's mistake: a note, not a problem.
    public var findings: [CutListen.Finding]
    /// The clips either side.
    public var clipIDs: [String]
    /// Heard on an earlier check: the sound there hasn't changed since.
    public var cached: Bool
    /// Why what's heard wasn't compared with the take, when it wasn't: "no
    /// transcript" (the take's words there aren't known yet), "nothing
    /// heard" (the engine heard nothing where the take has words, twice)
    /// or "couldn't listen" (the engine failed).
    public var skipped: String?
    /// The take's words cut beside the join, by the transcript: the first
    /// two cut past the clip before it, then the last two cut before the
    /// clip after it. Heard whole, one is kept after all (`CutEvidence`).
    public var cut: [String]?

    public init(
        time: Time, said: String, heard: String, findings: [CutListen.Finding], clipIDs: [String], cached: Bool, skipped: String? = nil, cut: [String]? = nil
    ) {
        self.time = time
        self.said = said
        self.heard = heard
        self.findings = findings
        self.clipIDs = clipIDs
        self.cached = cached
        self.skipped = skipped
        self.cut = cut
    }

    /// A finding that isn't slip-prone.
    public var clipped: Bool { findings.contains { !$0.slip } }
}

/// What `--listen` heard.
public struct ListenSummary: Codable, Equatable, Sendable {
    /// The engine that heard them: Bark 3.0 Pro, or SpeechAnalyzer when
    /// Bark's model isn't there ("Bark 3.0 Pro, then SpeechAnalyzer" when
    /// Bark kept failing part way).
    public var engine: String
    /// Every join checked, in timeline order.
    public var joins: [HeardJoin]
    /// How many were heard this time, and how many came from the cache.
    public var heard: Int
    public var cached: Int
    /// Seconds each join heard this time took, rendering and listening.
    public var secondsPerJoin: Double?

    public init(engine: String, joins: [HeardJoin], heard: Int, cached: Int, secondsPerJoin: Double?) {
        self.engine = engine
        self.joins = joins
        self.heard = heard
        self.cached = cached
        self.secondsPerJoin = secondsPerJoin
    }
}

extension CutCheck {
    /// What `--listen` hears with: an engine's name, its model (for the
    /// cache) and a call that hears 16 kHz mono samples. Tests swap in
    /// their own.
    struct Ear: Sendable {
        var engine: String
        var model: String
        var listen: @Sendable ([Float]) async throws -> [CutListen.Word]
        /// How it fell back while listening, when it did, after the engine's
        /// name in a warning ("listened on the CPU: ..."): Bark's encoder
        /// on the CPU when the Neural Engine can't compile it. Asked only
        /// of an engine that listened this check.
        var fellBack: @Sendable () async -> String?

        init(
            engine: String, model: String = "", fellBack: @escaping @Sendable () async -> String? = { nil },
            listen: @escaping @Sendable ([Float]) async throws -> [CutListen.Word]
        ) {
            self.engine = engine
            self.model = model
            self.fellBack = fellBack
            self.listen = listen
        }

        /// Bark 3.0 Pro when its model is ready, as transcripts use, then
        /// SpeechAnalyzer (macOS 26) to fall back on; empty with neither.
        static func standard() -> [Ear] {
            var ears: [Ear] = []
            let bark = BarkListener.standard
            if bark.isReady {
                ears.append(Ear(engine: BarkListener.engine, model: BarkListener.model, fellBack: { await BarkRuntime.shared.encoderFallback() }) {
                    try await bark.listen($0)
                })
            }
            if #available(macOS 26, *) {
                let speech = SpeechAnalyzerListener()
                ears.append(Ear(engine: SpeechAnalyzerListener.engine, model: SpeechAnalyzerListener.model) { try await speech.listen($0) })
            }
            return ears
        }
    }

    /// How the voice is rendered for listening: mono at `rate`, timeline
    /// seconds from and to. Tests swap in their own.
    struct Mix: Sendable {
        var rate: Double
        var render: @Sendable (_ from: Double, _ to: Double) async throws -> [Float]

        /// The speech tracks as export plays them (`playedSpeechTracks`),
        /// every other audio track muted, so music and sound effects don't
        /// get in the engine's way.
        static func speech(_ project: Project, folder: ProjectFolder, analysis: MediaAnalysis?) async throws -> Mix {
            let speech = Set(playedSpeechTracks(project).map(\.id))
            let context = RenderContext(project: AudioLevels.soloing(project, audioTrackIDs: speech), folder: folder, analysis: analysis)
            let reader = try await MixReader(context)
            return Mix(rate: MixReader.sampleRate) { try await reader.mono(from: $0, to: $1) }
        }
    }

    /// The speech tracks export plays: with a track soloed, only soloed
    /// ones, as `RenderPlan` mixes them. Empty when what's soloed isn't
    /// speech.
    static func playedSpeechTracks(_ project: Project) -> [Track] {
        let soloing = project.audioTracks.contains { $0.solo && !$0.muted }
        return TranscriptTools.speechTracks(project).filter { !soloing || $0.solo }
    }

    struct Listened: Sendable {
        var summary: ListenSummary
        var warnings: [String] = []
    }

    /// The take's words as the played speech tracks play them, and where
    /// they aren't known.
    struct Said: Sendable {
        var words: [CutListen.Word] = []
        /// Timeline seconds of speech clips whose transcript isn't ready.
        var unknown: [ClosedRange<Double>] = []
        /// Those clips' files, by name.
        var untranscribed: [String] = []
    }

    /// An engine fails this many joins in a row, and the next takes over.
    static let failuresBeforeFallback = 2

    /// Renders the voice `CutListen.span` either side of each join among
    /// `edges`, hears it (from the cache where that sound was heard before)
    /// and compares it with the take's words there.
    ///
    /// Each join is heard on its own: an engine that fails at one still
    /// hears the rest, and what the cache has comes from it whatever the
    /// engine does now. One that fails `failuresBeforeFallback` joins in a
    /// row hands over to the next of `ears`, which hears the joins it
    /// missed too. Nothing heard where the take has words is the engine's
    /// failure, not a cut-off: it's asked once more, then the next engine,
    /// and it's never cached.
    ///
    /// - Parameters:
    ///   - said: the transcript's words as the speech clips play them
    ///     (timeline time), and where they aren't known.
    ///   - words: each file's transcript words (media time), by media ID:
    ///     for the cut words beside each join.
    static func listen(
        project: Project, edges: [Edge], said: Said, words: [String: [CutAudit.Word]], mix: Mix, ears: [Ear], cache: CutListenCache
    ) async -> Listened {
        let tolerance = project.settings.frameRate.flicksPerFrame / 2
        var groups: [[Edge]] = []
        for edge in edges.sorted(by: { $0.time < $1.time }) {
            if let last = groups.last?.first, abs((last.time - edge.time).flicks) <= tolerance {
                groups[groups.count - 1].append(edge)
            } else {
                groups.append([edge])
            }
        }
        let times = groups.map { $0[0].time.seconds }
        var joins: [HeardJoin?] = Array(repeating: nil, count: groups.count)
        var warnings: [String] = []
        var fresh = 0, cached = 0
        var seconds = 0.0
        var active = 0, failuresInARow = 0
        var engines = ears.isEmpty ? [] : [ears[0].engine]
        /// Names an engine past the first that heard a join, once.
        func heardBy(_ ear: Int) {
            if ear < ears.count, !engines.contains(ears[ear].engine) { engines.append(ears[ear].engine) }
        }
        var failed: [(index: Int, input: [Float], error: String)] = []
        var unheard: [Time] = []
        var reported = Set<String>()
        // The engines that listened this check, for what they fell back on.
        var listened = Set<Int>()

        /// What's heard at one join, and by which engine; nil when nothing
        /// is: the engine failed, or heard nothing where there's speech.
        /// `from` starts past the active engine, for a join it missed.
        func hear(_ input: [Float], speech: Bool, from start: Int? = nil) async -> (words: [CutListen.Word]?, ear: Int, error: String?) {
            var error: String?
            var index = start ?? active
            while index < ears.count {
                let ear = ears[index]
                listened.insert(index)
                do {
                    var heard = try await ear.listen(input)
                    if heard.isEmpty, speech { heard = try await ear.listen(input) }
                    if index == active { failuresInARow = 0 }
                    if heard.isEmpty, speech {
                        index += 1
                        continue
                    }
                    cache.store(heard, for: CutListenCache.key(input, engine: ear.engine, model: ear.model))
                    return (heard, index, nil)
                } catch let failure {
                    error = (failure as? LocalizedError)?.errorDescription ?? "\(failure)"
                    guard index == active else { break }
                    failuresInARow += 1
                    guard failuresInARow >= failuresBeforeFallback, index + 1 < ears.count else { break }
                    active += 1
                    failuresInARow = 0
                    engines.append(ears[active].engine)
                    warnings.append("\(ear.engine) failed \(failuresBeforeFallback) joins in a row, so I'm listening with \(ears[active].engine) from here: \(error!)")
                    index = active
                }
            }
            return (nil, index, error)
        }

        func compared(_ index: Int, input: [Float], heard: [CutListen.Word]?, wasCached: Bool, skipped: String?) -> HeardJoin {
            let group = groups[index]
            let time = group[0].time
            let join = time.seconds
            let from = join - CutListen.span
            let offset = from - CutListen.padding
            let heardWords = (heard ?? []).map { CutListen.Word(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
            let window = (join - CutListen.span)...(join + CutListen.span)
            let kept = said.words.filter { $0.end > window.lowerBound && $0.start < window.upperBound }
            let (past, before) = cutWords(beside: group, words: words)
            let nearby = times.filter { $0 != join && abs($0 - join) < 2 * CutListen.span }
            var result = CutListen.compare(said: kept, heard: heardWords, at: join, cutPast: past, cutBefore: before, otherJoins: nearby)
            if skipped != nil { result.findings = [] }
            // A word two joins could both see is said once, at the first.
            result.findings = result.findings.filter { finding in
                reported.insert("\(finding.kind)|\(finding.said ?? "")|\(finding.heard ?? "")|\(Int((finding.time * 1000).rounded()))").inserted
            }
            var clipIDs: [String] = []
            for edge in group.sorted(by: { ($0.edge == .end ? 0 : 1) < ($1.edge == .end ? 0 : 1) }) where !clipIDs.contains(edge.clip.id) {
                clipIDs.append(edge.clip.id)
            }
            return HeardJoin(
                time: time, said: result.said, heard: result.heard, findings: result.findings, clipIDs: clipIDs, cached: wasCached, skipped: skipped,
                cut: past.isEmpty && before.isEmpty ? nil : past + before
            )
        }

        var untranscribed = 0
        for (index, group) in groups.enumerated() {
            let time = group[0].time
            let join = time.seconds
            let started = Date()
            let input: [Float]
            do {
                input = try CutListen.prepare(try await mix.render(join - CutListen.span, join + CutListen.span), rate: mix.rate)
            } catch {
                warnings.append("Couldn't render the voice at \(time) to listen to it: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                continue
            }
            let window = (join - CutListen.span)...(join + CutListen.span)
            // Without the take's words, everything heard would read as a
            // word the take doesn't keep: it's heard, to read, not compared.
            let known = !said.unknown.contains { $0.overlaps(window) }
            if !known { untranscribed += 1 }
            let speech = known && said.words.contains { $0.end > window.lowerBound && $0.start < window.upperBound }
            var heard: [CutListen.Word]?
            for (index, ear) in ears.enumerated() where heard == nil {
                heard = cache.heard(CutListenCache.key(input, engine: ear.engine, model: ear.model))
                if let heard, !heard.isEmpty || !speech { heardBy(index) }
            }
            // Nothing cached where there's speech came from an older check.
            if heard?.isEmpty == true, speech { heard = nil }
            let wasCached = heard != nil
            var skipped: String? = known ? nil : "no transcript"
            if heard == nil {
                let (words, ear, error) = await hear(input, speech: speech)
                if words != nil { heardBy(ear) }
                heard = words
                if words == nil {
                    if error != nil {
                        failed.append((index, input, error!))
                        skipped = "couldn't listen"
                    } else {
                        unheard.append(time)
                        skipped = "nothing heard"
                    }
                } else {
                    fresh += 1
                    seconds += Date().timeIntervalSince(started)
                }
            } else {
                cached += 1
            }
            joins[index] = compared(index, input: input, heard: heard, wasCached: wasCached, skipped: skipped)
        }
        // The joins an engine failed before the next took over: heard again
        // with it. When none took over (it failed now and then, or at the
        // only join there was, too few in a row to give up on it), the next
        // engine hears just those: a join heard by SpeechAnalyzer beats one
        // not heard at all, and Bark stays the engine for the rest.
        var stillFailed: [(index: Int, error: String)] = []
        let firstFailures = active == 0 ? failed.count : 0
        var rescued = 0
        let rescuer = active == 0 && ears.count > 1 ? 1 : nil
        let firstError = failed.first?.error
        for miss in failed {
            guard active > 0 || rescuer != nil else {
                stillFailed.append((miss.index, miss.error))
                continue
            }
            let started = Date()
            let window = (times[miss.index] - CutListen.span)...(times[miss.index] + CutListen.span)
            let known = !said.unknown.contains { $0.overlaps(window) }
            let speech = known && said.words.contains { $0.end > window.lowerBound && $0.start < window.upperBound }
            let (words, ear, error) = await hear(miss.input, speech: speech, from: active > 0 ? nil : rescuer)
            if words != nil {
                heardBy(ear)
                if active == 0 { rescued += 1 }
            }
            if let words {
                fresh += 1
                seconds += Date().timeIntervalSince(started)
                joins[miss.index] = compared(miss.index, input: miss.input, heard: words, wasCached: false, skipped: known ? nil : "no transcript")
            } else if let error {
                // Bark's own error when the rescue failed too: it's the one
                // the warning names.
                stillFailed.append((miss.index, active == 0 ? miss.error : error))
            } else {
                unheard.append(groups[miss.index][0].time)
                joins[miss.index]?.skipped = "nothing heard"
            }
        }
        if untranscribed > 0, !said.untranscribed.isEmpty {
            let what = untranscribed == 1 ? "1 join wasn't" : "\(untranscribed) joins weren't"
            warnings.append("No transcript yet for \(said.untranscribed.joined(separator: ", ")), so what's heard at \(what) compared with the take.")
        }
        if rescued > 0, let rescuer, let firstError {
            let what = firstFailures == 1 ? "1 join" : "\(firstFailures) joins"
            warnings.append("\(ears[0].engine) couldn't listen at \(what), so \(rescued == firstFailures ? (rescued == 1 ? "it was" : "they were") : rescued == 1 ? "1 was" : "\(rescued) were") heard with \(ears[rescuer].engine): \(firstError)")
        }
        for index in listened.sorted() {
            if let how = await ears[index].fellBack() { warnings.append("\(ears[index].engine) \(how)") }
        }
        if let first = stillFailed.first {
            let what = stillFailed.count == 1 ? "1 join" : "\(stillFailed.count) joins"
            warnings.append("\(ears[active].engine) couldn't listen at \(what) (first at \(groups[first.index][0].time)), so they weren't heard: \(first.error)")
        }
        if !unheard.isEmpty {
            let list = unheard.sorted().prefix(5).map { "\($0)" }.joined(separator: ", ") + (unheard.count > 5 ? " and \(unheard.count - 5) more" : "")
            warnings.append("Nothing was heard at \(list), where the take has words: the engine's failure, not a cut-off, so \(unheard.count == 1 ? "it wasn't" : "they weren't") compared. Listen with tandem clip.")
        }
        let summary = ListenSummary(
            engine: engines.joined(separator: ", then "), joins: joins.compactMap { $0 }, heard: fresh, cached: cached,
            secondsPerJoin: fresh > 0 ? seconds / Double(fresh) : nil
        )
        return Listened(summary: summary, warnings: warnings)
    }

    /// The take's words cut beside a join, by the transcript: the first two
    /// cut past the end of the clip before it, and the last two cut before
    /// the start of the clip after it. A word the edge runs through counts,
    /// whichever side most of it is on: the transcript's times are a tenth
    /// of a second or two out either way, and on the Tandem video the words
    /// heard whole at joins ("see", "mistakes,") were ones the edge ran
    /// through.
    ///
    /// A join can be on several tracks at once (the mic and a screen
    /// recording's sound, cut together): the first edge with cut words on
    /// each side gives them, so a track with no transcript there doesn't
    /// blank out the mic's.
    static func cutWords(beside group: [Edge], words: [String: [CutAudit.Word]]) -> (past: [String], before: [String]) {
        var past: [String] = [], before: [String] = []
        for edge in group {
            let said = (words[edge.media.id] ?? []).sorted { $0.start < $1.start }
            if edge.edge == .end, past.isEmpty {
                let gone = edge.cutAway ?? edge.mediaTime...(edge.mediaTime + CutListen.span)
                past = said.filter { $0.end > edge.mediaTime && $0.start < gone.upperBound }.prefix(2).map(\.text)
            } else if edge.edge == .start, before.isEmpty {
                let gone = edge.removed ?? max(0, edge.mediaTime - CutListen.span)...edge.mediaTime
                before = said.filter { $0.start < edge.mediaTime && $0.end > gone.lowerBound }.suffix(2).map(\.text)
            }
        }
        return (past, before)
    }

    /// The transcript's words as the speech tracks export plays play them
    /// (`playedSpeechTracks`), in timeline seconds, and where they aren't
    /// known yet. Where two tracks play the same voice (a camera's sound
    /// and a mic), a word is said once.
    static func said(in project: Project, analysis: AnalysisSource) -> Said {
        let played = Set(playedSpeechTracks(project).flatMap(\.clips).map(\.id))
        var soloed = project
        soloed.audioTracks = project.audioTracks.filter { track in track.clips.contains { played.contains($0.id) } }
        let map = TranscriptTools.speechMap(soloed, analysis: analysis)
        var result = Said()
        for word in map.words.sorted(by: { $0.start < $1.start }) where played.contains(word.clipID) {
            let candidate = CutListen.Word(text: word.text, start: word.start.seconds, end: word.end.seconds)
            let twice = result.words.suffix(4).contains { earlier in
                let overlap = min(earlier.end, candidate.end) - max(earlier.start, candidate.start)
                return overlap > 0.5 * min(earlier.end - earlier.start, candidate.end - candidate.start)
                    && earlier.text.lowercased().filter(\.isLetter) == candidate.text.lowercased().filter(\.isLetter)
            }
            if !twice { result.words.append(candidate) }
        }
        result.unknown = map.unknown.map { $0.start.seconds...$0.end.seconds }
        result.untranscribed = map.missing.compactMap { project.media($0).map { URL(fileURLWithPath: $0.path).lastPathComponent } }
        return result
    }

    /// What `check --cuts` found, weighed against what `--listen` heard
    /// (`CutEvidence`), with the fixes for what's still a problem.
    struct Combined: Sendable {
        var problems: [CheckProblem] = []
        var notes: [CheckProblem] = []
        /// Latest first, as `Outcome.commands`.
        var commands: [EditCommand] = []
        /// Every join heard, with each finding the take's transcript explains
        /// marked slip-prone and saying why.
        var joins: [HeardJoin] = []
    }

    /// At each join heard, a `clippedWord` problem whose words are heard
    /// whole becomes a `heardWhole` note, a listening finding the take's
    /// transcript explains becomes a note, and a join with both a flag and a
    /// finding is one problem that says both. Joins not heard (skipped, or
    /// outside what was listened to) keep what the levels found.
    ///
    /// - Parameters:
    ///   - problems: `check --cuts`' problems (`clippedWord`), in order.
    ///   - notes: its notes (`marginalJoin`).
    static func combine(problems: [CheckProblem], notes: [CheckProblem], summary: ListenSummary) -> Combined {
        var result = Combined()
        var levels = problems
        var dismissed = Set<Int>()
        var folded: [Int: String] = [:]
        result.joins = summary.joins
        for (place, join) in summary.joins.enumerated() where join.skipped == nil {
            // The level problems at this join, by their edge's clip.
            let here = levels.indices.filter { index in
                guard let cut = levels[index].cut, join.clipIDs.contains(cut.clipID) else { return false }
                return abs((levels[index].start - join.time).seconds) < 0.0005
            }
            let flags = here.map { index -> CutEvidence.Flag in
                let cut = levels[index].cut!
                return CutEvidence.Flag(
                    keeps: cut.edge == .end ? .before : .after, margin: cut.margin.map(Float.init), lastWordCut: cut.lastWordCut,
                    firstWordCut: cut.firstWordCut, fragment: cut.fragment, beforeFiller: cut.beforeFiller
                )
            }
            let heard = CutListen.Join(time: join.time.seconds, said: join.said, heard: join.heard, findings: join.findings)
            let verdict = CutEvidence.judge(heard, flags: flags, cut: join.cut ?? [])
            for (index, why) in verdict.explained {
                result.joins[place].findings[index].slip = true
                result.joins[place].findings[index].why = why
            }
            let words = "Take: \"\(join.said)\". Heard: \"\(join.heard)\"."
            for (flag, why) in verdict.dismissed {
                dismissed.insert(here[flag])
                var note = levels[here[flag]]
                note.kind = .heardWhole
                note.message = "Heard whole at the join, so not clipped: \(why). The check said: \(note.message) \(words)"
                result.notes.append(note)
            }
            let kept = here.filter { !dismissed.contains($0) }
            func said(_ index: Int) -> String {
                let finding = join.findings[index]
                return "\(finding.summary) (\(verdict.explained[index] ?? finding.why))"
            }
            let standing = join.findings.indices.filter { verdict.explained[$0] == nil && (!join.findings[$0].slip || verdict.confirming.contains($0)) }
            if let first = kept.first, !verdict.confirming.isEmpty {
                // Both say so: one problem, with the fix the levels found.
                folded[first] = verdict.confirming.map(said).joined(separator: "; ")
                let rest = join.findings.indices.filter { !verdict.confirming.contains($0) }
                if !rest.isEmpty {
                    result.notes.append(CheckProblem(
                        kind: .heardDifferently, start: join.time, end: join.time,
                        message: "Heard differently at the join, besides the cut-off: \(rest.map(said).joined(separator: "; ")). \(words)", clipIDs: join.clipIDs
                    ))
                }
            } else if verdict.heardCutOff {
                result.problems.append(CheckProblem(
                    kind: .heardCutOff, start: join.time, end: join.time,
                    message: "Heard cut off at the join: \(standing.map(said).joined(separator: "; ")). \(words) Listen with tandem clip and recut it.", clipIDs: join.clipIDs
                ))
                let rest = join.findings.indices.filter { !standing.contains($0) }
                if !rest.isEmpty {
                    result.notes.append(CheckProblem(
                        kind: .heardDifferently, start: join.time, end: join.time,
                        message: "Heard differently at the join, besides the cut-off: \(rest.map(said).joined(separator: "; ")). \(words)", clipIDs: join.clipIDs
                    ))
                }
            } else if !join.findings.isEmpty {
                let explained = !verdict.explained.isEmpty
                let why = explained && verdict.explained.count == join.findings.count
                    ? "which the take's transcript explains" : explained ? "which the take's transcript explains or is likely \(summary.engine)'s slip" : "likely \(summary.engine)'s slip"
                result.notes.append(CheckProblem(
                    kind: .heardDifferently, start: join.time, end: join.time,
                    message: "Heard differently at the join, \(why): \(join.findings.indices.map(said).joined(separator: "; ")). \(words)", clipIDs: join.clipIDs
                ))
            }
        }
        for (index, heard) in folded {
            let message = levels[index].message
            // "Clipped word at the end of clip_x: ..." says it's heard too.
            if let colon = message.range(of: ": ") {
                levels[index].message = String(message[..<colon.lowerBound]) + ", and heard cut off (\(heard))" + String(message[colon.lowerBound...])
            }
        }
        let standing = levels.indices.filter { !dismissed.contains($0) }.map { levels[$0] }
        result.problems = (standing + result.problems).sorted { $0.start < $1.start }
        result.notes = (notes + result.notes).sorted { $0.start < $1.start }
        for fix in standing.reversed().compactMap(\.cut?.fix) where !result.commands.contains(fix) {
            result.commands.append(fix)
        }
        return result
    }
}
