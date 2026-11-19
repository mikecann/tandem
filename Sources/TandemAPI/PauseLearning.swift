import Foundation
import TandemCore
import TandemMedia

/// Where Mike's pause taste is kept: one file for every project, so what
/// he trims on one video holds for the next.
public enum PauseTasteStore {
    /// Moves the file, for tests and for a second person's taste.
    public static let environmentKey = "TANDEM_PAUSE_TASTE"

    public static var url: URL {
        if let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        // Tests check projects of their own: what they "trim" isn't Mike's.
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("pause-taste-\(ProcessInfo.processInfo.processIdentifier).json")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Tandem/pause-taste.json")
    }

    public static func load(from url: URL = url) -> PauseTaste {
        guard let data = try? Data(contentsOf: url) else { return PauseTaste() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PauseTaste.self, from: data)) ?? PauseTaste()
    }

    public static func save(_ taste: PauseTaste, to url: URL = url) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(taste).write(to: url, options: .atomic)
    }
}

extension TandemService {
    /// The pauses Mike trimmed himself in this project's history after
    /// `since` (a revision), each with the silence either side as he hears
    /// it before and after his trim.
    ///
    /// A trim is a run of his edits that ends in one that takes time out of
    /// the take (`ReviewRounds.isTakeTrim`: a delete and close gap, a ripple
    /// trim or delete), with the blades before it. The timeline before and
    /// after is rebuilt from the history (`HistoryChain`), and the pause is
    /// the gap between the same two words in both. A trim that took words
    /// out is a cut, not a pause, and is left out.
    public func learnPauses(since: Int = 0) async throws -> (trims: [PauseTrim], through: Int) {
        let (project, revision) = coordinator.snapshot()
        let records = session.history.records()
        let earliest = max(HistoryChain.earliest(records, currentRevision: revision), since)
        guard earliest < revision else { return ([], revision) }
        let walk = try HistoryChain.walk(records, current: TimelineClips(project), currentRevision: revision, back: earliest)
        let takeTracks = ReviewRounds.takeTracks(project)
        let key = Self.tasteKey(project, url: session.fileURL)
        func person(_ record: HistoryRecord) -> Bool {
            record.kind.changesProject && record.kind != .opened && EditAuthor.isPerson(record.author)
        }
        func blade(_ record: HistoryRecord) -> Bool { record.label.lowercased().hasPrefix("blade") }

        var found: [PauseTrim] = []
        var index = 0
        let chain = walk.records
        while index < chain.count {
            let record = chain[index]
            guard person(record), ReviewRounds.isTakeTrim(record, takeTracks: takeTracks), let place = record.place else {
                index += 1
                continue
            }
            // His blades just before it are part of the trim, and so are
            // his trims and blades just after it, there and then (a delete
            // and its close gap).
            var first = index
            while first > 0, person(chain[first - 1]), blade(chain[first - 1]), ReviewRounds.near(chain[first - 1].place, place) { first -= 1 }
            var last = index
            // A close gap's place runs from the first clip it moved, which
            // can be anywhere on another track, so it only has to come soon
            // after.
            func closesGap(_ record: HistoryRecord) -> Bool { record.label.lowercased().hasPrefix("close gap") }
            while last + 1 < chain.count, person(chain[last + 1]),
                  closesGap(chain[last + 1])
                    || ((ReviewRounds.isTakeTrim(chain[last + 1], takeTracks: takeTracks) || blade(chain[last + 1])) && ReviewRounds.near(chain[last + 1].place, place)),
                  chain[last + 1].date.timeIntervalSince(chain[last].date) <= ReviewRounds.fixGap {
                last += 1
            }
            index = last + 1
            let before = Self.project(project, with: walk.states[first])
            let after = Self.project(project, with: walk.states[last + 1])
            // Where his last cut was (a close gap's place says nothing), in
            // the timeline as it is after the trim.
            let anchor = chain[first...last].last { ReviewRounds.isTakeTrim($0, takeTracks: takeTracks) && !closesGap($0) }?.place?.start ?? place.start
            guard let trim = await pauseTrim(before: before, after: after, at: anchor) else { continue }
            found.append(PauseTrim(
                project: key, name: project.name, revision: chain[last].revision, date: chain[last].date, at: trim.at,
                before: trim.before, after: trim.after, kind: trim.kind, was: trim.was, left: trim.left
            ))
        }
        return (found, revision)
    }

    /// The key a project's trims are kept under: its ID, or its path.
    static func tasteKey(_ project: Project, url: URL) -> String {
        project.id ?? url.standardizedFileURL.path
    }

    /// `base` with the clips of `state` on its tracks. A clip on a track
    /// since deleted is left out.
    static func project(_ base: Project, with state: TimelineClips) -> Project {
        var project = base
        var byTrack: [String: [Clip]] = [:]
        for placed in state.clips.values { byTrack[placed.trackID, default: []].append(placed.clip) }
        for index in project.videoTracks.indices {
            project.videoTracks[index].clips = (byTrack[project.videoTracks[index].id] ?? []).sorted { $0.start < $1.start }
        }
        for index in project.audioTracks.indices {
            project.audioTracks[index].clips = (byTrack[project.audioTracks[index].id] ?? []).sorted { $0.start < $1.start }
        }
        return project
    }

    /// The pause at `at` after a trim, and the same pause before it, each
    /// with its silence as heard. The same pause is the gap between the
    /// same two words of the take (by where they are in the file), with at
    /// most `strays` short words between them before: a mumble or an "um"
    /// he cut with the pause ("Ed" in the eye-shift pause on the Examples
    /// Page), which are left out of it there. Nil when there's no pause at
    /// `at` afterwards, or the trim cut real words.
    func pauseTrim(before: Project, after: Project, at: Time) async -> (at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double)? {
        let reach = Time(seconds: 8)
        let shortest = Time(seconds: 0.01)
        let window = (from: max(.zero, at - reach), to: at + reach + reach)
        // A word the transcript has where the sound has only the room splits
        // a pause in two, so it's left out, as `tandem pauses` leaves it out.
        let mapAfter = await SoundTightening.withoutPhantoms(
            TranscriptTools.speechMap(after, analysis: analysis), from: window.from, to: window.to, project: after, folder: folder
        ).map
        let near = Time(seconds: 0.35)
        let candidates = TranscriptTools.pauses(in: mapAfter, minimum: shortest, from: max(.zero, at - reach), to: at + reach)
            .filter { $0.start - near <= at && at <= $0.end + near }
        // The nearest pause his trim changed.
        for pauseAfter in candidates.sorted(by: { distance($0, at) < distance($1, at) }) {
            if let found = await pauseTrim(pauseAfter, mapAfter: mapAfter, before: before, after: after, window: window) { return found }
        }
        return nil
    }

    /// `pauseTrim(before:after:at:)` for one pause after the trim.
    private func pauseTrim(
        _ pauseAfter: Pause, mapAfter: TranscriptTools.SpeechMap, before: Project, after: Project, window: (from: Time, to: Time)
    ) async -> (at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double)? {
        guard let last = mapAfter.words.lastIndex(where: { $0.end == pauseAfter.start }), last + 1 < mapAfter.words.count else { return nil }
        // The two words, by where they are in their files.
        func place(_ word: TranscriptTools.SpokenWord, in project: Project) -> (media: String, time: Double)? {
            guard let clip = project.clip(word.clipID) else { return nil }
            return (word.mediaID, clip.sourceStart.seconds + (word.start - clip.start).seconds * clip.speed)
        }
        guard let wordBefore = place(mapAfter.words[last], in: after), let wordAfter = place(mapAfter.words[last + 1], in: after) else { return nil }
        var mapBefore = await SoundTightening.withoutPhantoms(
            TranscriptTools.speechMap(before, analysis: analysis), from: window.from, to: window.to, project: before, folder: folder
        ).map
        func index(of word: (media: String, time: Double)) -> Int? {
            mapBefore.words.firstIndex { other in
                guard let found = place(other, in: before) else { return false }
                return found.media == word.media && abs(found.time - word.time) < 0.02
            }
        }
        guard let first = index(of: wordBefore), let next = index(of: wordAfter), next > first else { return nil }
        let between = mapBefore.words[(first + 1)..<next]
        guard between.count <= Self.strays, between.allSatisfy(Self.isStray) else { return nil }
        mapBefore.words.removeSubrange((first + 1)..<next)
        let gap = TimeRange(start: mapBefore.words[first].end, end: mapBefore.words[first + 1].start)
        let pauseBefore = Pause(start: gap.start, end: gap.end, duration: gap.duration, before: pauseAfter.before, after: pauseAfter.after, clipIDs: [])
        let heardAfter = await SoundTightening.listened([pauseAfter], map: mapAfter, project: after, folder: folder).pauses.first
        let heardBefore = await SoundTightening.listened([pauseBefore], map: mapBefore, project: before, folder: folder).pauses.first
        func silence(_ pause: Pause?) -> Double? {
            guard let pause else { return nil }
            guard let sound = pause.sound else { return pause.duration.seconds }
            return sound.silence?.duration.seconds ?? (sound.runsThrough ? 0 : sound.duration.seconds)
        }
        // With a stray word cut too, what it was is the whole gap: Mike
        // heard the mumble as part of the pause he cut.
        let was = between.isEmpty ? silence(heardBefore) : gap.duration.seconds
        guard let was, let left = silence(heardAfter), abs(was - left) >= 0.02 else { return nil }
        return (pauseAfter.start, pauseAfter.before, pauseAfter.after, SpokenPause.kind(before: pauseAfter.before, next: pauseAfter.after), was, left)
    }

    /// At most this many short words cut with a pause still make it a
    /// pause trim, each no longer than `strayLength`.
    static let strays = 1
    static let strayLength = Time(seconds: 0.5)
    /// The transcript wasn't sure of it: "Ed" was 0.68, where a tenth of
    /// the Examples Page take's words were under 0.82.
    static let strayConfidence = 0.75

    /// A short filler, or a short word the transcript wasn't sure of: a
    /// real word ("that" in "few questions that weren't") cut with the
    /// pause makes it a cut.
    static func isStray(_ word: TranscriptTools.SpokenWord) -> Bool {
        guard word.end - word.start <= strayLength else { return false }
        let bare = word.text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return TranscriptTools.fillers.contains(bare) || (word.confidence ?? 1) < strayConfidence
    }

    private func distance(_ pause: Pause, _ time: Time) -> Double {
        if pause.start <= time && time <= pause.end { return 0 }
        return min(abs((pause.start - time).seconds), abs((pause.end - time).seconds))
    }

    /// Reads this project's trims into Mike's pause taste from where it was
    /// last read, and saves it. The taste as it is when the file can't be
    /// written.
    public func updatePauseTaste(at url: URL = PauseTasteStore.url) async throws -> (taste: PauseTaste, found: [PauseTrim]) {
        var taste = PauseTasteStore.load(from: url)
        let (project, _) = coordinator.snapshot()
        let key = Self.tasteKey(project, url: session.fileURL)
        let learned = try await learnPauses(since: taste.learned[key] ?? 0)
        taste.add(learned.trims, project: key, through: learned.through)
        try? PauseTasteStore.save(taste, to: url)
        return (taste, learned.trims)
    }
}
