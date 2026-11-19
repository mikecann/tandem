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

    /// Changes the taste in the file under an exclusive lock on a file
    /// beside it, so two processes' changes don't overwrite each other.
    /// The taste as changed, even when the file can't be written.
    @discardableResult
    public static func update(at url: URL = url, _ change: (inout PauseTaste) -> Void) -> PauseTaste {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        var taste = load(from: url)
        change(&taste)
        try? save(taste, to: url)
        return taste
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
    public func learnPauses(since: Int = 0) async throws -> (trims: [PauseTrim], complaints: [PauseComplaint], undone: Set<Int>, through: Int) {
        let (project, revision) = coordinator.snapshot()
        let records = session.history.records()
        let earliest = max(HistoryChain.earliest(records, currentRevision: revision), since)
        guard earliest < revision else { return ([], [], [], revision) }
        let walk = try HistoryChain.walk(records, current: TimelineClips(project), currentRevision: revision, back: earliest)
        let takeTracks = ReviewRounds.takeTracks(project)
        let key = Self.tasteKey(project, url: session.fileURL)
        func person(_ record: HistoryRecord) -> Bool {
            record.kind.changesProject && record.kind != .opened && EditAuthor.isPerson(record.author)
        }
        func blade(_ record: HistoryRecord) -> Bool { record.label.lowercased().hasPrefix("blade") }

        // The edits undone and not redone, over the whole history (it's
        // only the records, no sound): a trim he undid isn't how he wants
        // it, however long after, and one learned before is taken out.
        let undone = Self.undone(records)

        var found: [PauseTrim] = []
        var unread: Int?
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
            if chain[first...last].contains(where: { undone.contains($0.revision) }) { continue }
            let before = Self.project(project, with: walk.states[first])
            let after = Self.project(project, with: walk.states[last + 1])
            // Where each of his cuts was (a close gap's place says nothing),
            // the last first, as it's in the timeline after the trim: two
            // pauses trimmed a second apart are two trims.
            let anchors = chain[first...last].filter { ReviewRounds.isTakeTrim($0, takeTracks: takeTracks) && !closesGap($0) }
                .compactMap { $0.place?.start }.reversed()
            // With no transcript to go by yet, nothing there can be read:
            // stop the read short of it, so it's read once there is one.
            if !TranscriptTools.speechMap(after, analysis: analysis).missing.isEmpty {
                unread = min(unread ?? chain[first].revision - 1, chain[first].revision - 1)
                continue
            }
            // A later cut earlier on moves an earlier one's place back, by
            // up to what it took out, so every pause from there to the last
            // one is looked at; the ones whose silence didn't change aren't
            // trims.
            let places = anchors.isEmpty ? [place.start] : Array(anchors)
            let reach = Time(seconds: Self.trimReach)
            let span = TimeRange(start: max(.zero, places.min()! - reach), end: places.max()! + Time(seconds: 0.35))
            var pairs = Set<String>()
            for trim in await pauseTrims(before: before, after: after, in: span) {
                guard pairs.insert("\(trim.before)|\(trim.after)").inserted else { continue }
                found.append(PauseTrim(
                    project: key, name: project.name, revision: chain[last].revision, date: chain[last].date, at: trim.at,
                    before: trim.before, after: trim.after, kind: trim.kind, was: trim.was, left: trim.left
                ))
            }
        }
        // His comments on a pause being too long, with the pause he heard,
        // as `tandem rounds` finds them: in the history, or for an older
        // project in its backups and exports' snapshots.
        var heard: [PauseComplaint] = []
        let comments = ((try? ReviewRounds.read(session.fileURL))?.rounds ?? []).flatMap(\.comments)
        var seen = Set<String>()
        for comment in comments {
            guard let text = comment.text, let time = comment.time, Self.isPauseComplaint(text),
                  comment.revision > earliest, comment.revision <= (unread ?? revision) else { continue }
            let id = comment.id ?? "\(comment.revision)@\(time.flicks)"
            guard seen.insert(id).inserted else { continue }
            let state = Self.project(project, with: walk.states[comment.revision - earliest])
            guard let pause = await complainedPause(in: state, at: time) else { continue }
            heard.append(PauseComplaint(
                project: key, name: project.name, revision: comment.revision, comment: id, date: comment.date, at: pause.start,
                text: text, before: pause.before, after: pause.after, kind: SpokenPause.heldKind(before: pause.before, next: pause.after),
                silence: pause.silence
            ))
        }
        return (found, heard, undone, max(earliest, unread ?? revision))
    }

    /// A comment about a pause or silence being too long: not one asking
    /// for a longer pause, or to keep one.
    static func isPauseComplaint(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        let micro = try! NSRegularExpression(pattern: #"\bmicro ?pauses?\b"#, options: .caseInsensitive)
        // It has to name a pause: "too long on this B-roll shot" is the
        // pauses theme by its words, but about a shot.
        let named = try! NSRegularExpression(pattern: #"\b(micro ?)?(pauses?|silences?|silent|gaps?|dead air|beats?)\b"#, options: .caseInsensitive)
        guard named.firstMatch(in: text, range: range) != nil, CommentTheme.classify(text) == .pauses || micro.firstMatch(in: text, range: range) != nil else { return false }
        // Not an ask for more pause, or one he's already made how he wants
        // ("I tighten the pause to how I want it to be, but can you just
        // fix this swipe").
        let longer = try! NSRegularExpression(
            pattern: #"\b(longer(?! than (needed|necessary|it needs))|too (short|quick|fast|tight|abrupt)|rushed|not long enough|more time|extend\w*|keep (it|this|that|the)|put (it |that |the pause )?back|add (a |more )?pause|more (of a )?pause|how i want it|i('ve| have)? (tighten|trimm?)(ed)? (the|this|that) pause)\b"#,
            options: .caseInsensitive
        )
        return longer.firstMatch(in: text, range: range) == nil
    }

    /// The pause a comment at `time` is about: the one with the most
    /// silence from 1.5 s before it to 0.5 s after (he stops a moment after
    /// he hears it), as heard.
    func complainedPause(in project: Project, at time: Time) async -> (start: Time, before: String, after: String, silence: Double)? {
        let from = max(.zero, time - Time(seconds: 1.5)), to = time + Time(seconds: 0.5)
        let map = await SoundTightening.withoutPhantoms(
            TranscriptTools.speechMap(project, analysis: analysis), from: max(.zero, from - Time(seconds: 4)), to: to + Time(seconds: 4), project: project, folder: folder
        ).map
        let candidates = TranscriptTools.pauses(in: map, minimum: Time(seconds: CutAudit.minPause), from: max(.zero, from - Time(seconds: 4)), to: to + Time(seconds: 4))
            .filter { $0.end >= from && $0.start <= to }
        guard !candidates.isEmpty else { return nil }
        let heard = await SoundTightening.listened(candidates, map: map, project: project, folder: folder).pauses
        let measured = heard.compactMap { pause -> (Pause, Double)? in
            guard let silence = pause.sound?.silence else { return nil }
            return (pause, silence.duration.seconds)
        }
        guard let loudest = measured.max(by: { $0.1 < $1.1 }) else { return nil }
        return (loudest.0.start, loudest.0.before, loudest.0.after, loudest.1)
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

    /// One pause after a trim, and the same pause before it, each with its
    /// silence as heard. The same pause is the gap between the same two
    /// words of the take (by where they are in the file), with at most
    /// `strays` short words between them before: a mumble or an "um" he cut
    /// with the pause ("Ed" in the eye-shift pause on the Examples Page),
    /// left out of it there. Nil when the trim didn't change it, or cut
    /// real words.
    func pauseTrim(
        _ pauseAfter: Pause, mapAfter: TranscriptTools.SpeechMap, before: Project, after: Project, window: (from: Time, to: Time)
    ) async -> (at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double)? {
        // Words on two tracks can overlap: only a word that starts after the
        // one before ends is the next one.
        guard let last = mapAfter.words.lastIndex(where: { $0.end == pauseAfter.start }), last + 1 < mapAfter.words.count,
              mapAfter.words[last + 1].start >= mapAfter.words[last].end else { return nil }
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
        guard mapBefore.words[first + 1].start > mapBefore.words[first].end else { return nil }
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
        return (pauseAfter.start, pauseAfter.before, pauseAfter.after, SpokenPause.heldKind(before: pauseAfter.before, next: pauseAfter.after), was, left)
    }

    /// The revisions of edits undone and not redone, replaying the undo
    /// stack through the history: an edit pushes its revision, an undo pops
    /// the top, a redo pushes back the last popped. Opening or reloading
    /// the project clears it.
    static func undone(_ records: [HistoryRecord]) -> Set<Int> {
        var stack: [Int] = [], popped: [Int] = []
        var undone = Set<Int>()
        for record in records where record.kind.changesProject {
            switch record.kind {
            case .edit:
                stack.append(record.revision)
                popped.removeAll()
            case .undo:
                if let top = stack.popLast() {
                    popped.append(top)
                    undone.insert(top)
                }
            case .redo:
                if let back = popped.popLast() {
                    stack.append(back)
                    undone.remove(back)
                }
            case .opened, .reload:
                stack.removeAll()
                popped.removeAll()
            case .check, .handback:
                break
            }
        }
        return undone
    }

    /// How far a trim's place can have moved back by the time the trim is
    /// done: his later cuts in it, earlier on the timeline.
    static let trimReach = 3.0

    /// Every pause in `span` after a trim that it changed.
    func pauseTrims(before: Project, after: Project, in span: TimeRange) async -> [(at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double)] {
        let window = (from: max(.zero, span.start - Time(seconds: 8)), to: span.end + Time(seconds: 8))
        let mapAfter = await SoundTightening.withoutPhantoms(
            TranscriptTools.speechMap(after, analysis: analysis), from: window.from, to: window.to, project: after, folder: folder
        ).map
        let candidates = TranscriptTools.pauses(in: mapAfter, minimum: Time(seconds: 0.01), from: window.from, to: window.to)
            .filter { $0.end >= span.start && $0.start <= span.end }
        var found: [(at: Time, before: String, after: String, kind: SpokenPause.Kind, was: Double, left: Double)] = []
        for pauseAfter in candidates {
            if let trim = await pauseTrim(pauseAfter, mapAfter: mapAfter, before: before, after: after, window: window) { found.append(trim) }
        }
        return found
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

    /// Reads this project's trims into Mike's pause taste from where it was
    /// last read, and saves it. The taste as it is when the file can't be
    /// written.
    public func updatePauseTaste(at url: URL = PauseTasteStore.url) async throws -> (taste: PauseTaste, found: [PauseTrim], complaints: [PauseComplaint]) {
        let (project, _) = coordinator.snapshot()
        let key = Self.tasteKey(project, url: session.fileURL)
        let learned = try await learnPauses(since: PauseTasteStore.load(from: url).learned[key] ?? 0)
        // Read again under the file's lock just before writing, so what
        // another project's check learned meanwhile stays.
        let taste = PauseTasteStore.update(at: url) { taste in
            taste.trims.removeAll { $0.project == key && learned.undone.contains($0.revision) }
            taste.add(learned.trims, complaints: learned.complaints, project: key, through: learned.through)
        }
        return (taste, learned.trims, learned.complaints)
    }
}
