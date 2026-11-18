import XCTest
@testable import TandemCore

/// What changed between two timelines, clip by clip, where each edit was,
/// and the edit history that keeps it across restarts.
final class ClipChangesTests: XCTestCase {
    private func changes(_ before: Project, _ after: Project) -> [ClipChange] {
        ClipChanges.between(TimelineClips(before), TimelineClips(after), names: ClipChanges.mediaNames(after, before))
    }

    func testATrimIsDescribedWithItsEdgeAndWhereItWas() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        try c.run("Trim", .trim(clipID: shot.id, edge: .start, to: t(21)))
        let found = changes(f.project, c.project)
        XCTAssertEqual(found.count, 1)
        let change = try XCTUnwrap(found.first)
        XCTAssertEqual(change.id, shot.id)
        XCTAssertEqual(change.kind, .changed)
        XCTAssertEqual(change.track, "V3 B-roll")
        XCTAssertEqual(change.start, t(21))
        XCTAssertEqual(change.end, t(25))
        XCTAssertEqual(change.wasStart, t(20))
        XCTAssertEqual(change.wasEnd, t(25))
        XCTAssertEqual(change.details, ["start +1.000s"])
        XCTAssertEqual(change.content, "servers.mp4")
        XCTAssertNil(change.shift)
    }

    func testPropertiesAddedRemovedAndMovedClips() throws {
        let (f, c) = try Fixture.edited()
        let shot = f.clips("B-roll")[0]
        let music = f.clips("Music")[0]
        let camera = f.clips("Camera")[0]
        try c.run("Edits",
            .updateClip(clipID: music.id, patch: .object(["audio": .object(["gainDB": .number(-25)])])),
            .updateClip(clipID: camera.id, patch: .object(["video": .object(["transform": .object(["scale": .number(0.5)])])])),
            .setKeyframes(clipID: camera.id, parameter: "video.opacity", keyframes: [Keyframe(time: .zero, value: .number(0)), Keyframe(time: t(1), value: .number(1))]),
            .moveClips(clipIDs: [shot.id], delta: t(10), toTrackID: nil, mode: nil),
            .insertClip(trackID: f.track("Text").id, clip: Clip(id: "clip_title", content: .text(TextContent(text: "HELLO")), start: t(2), duration: t(3)), mode: nil)
        )
        try c.run("Remove", .removeClips(clipIDs: ["clip_title"], ripple: nil, includeLinked: nil))
        let found = Dictionary(uniqueKeysWithValues: changes(f.project, c.project).map { ($0.id, $0) })
        XCTAssertEqual(found[music.id]?.details.first, "gain -31 -> -25 dB")
        let cameraDetails = try XCTUnwrap(found[camera.id]?.details)
        XCTAssertTrue(cameraDetails.contains("scale 1 -> 0.5"), "\(cameraDetails)")
        XCTAssertTrue(cameraDetails.contains("keyframes video.opacity (2)"), "\(cameraDetails)")
        XCTAssertEqual(found[shot.id]?.details, ["moved +10.000s"])
        XCTAssertEqual(found[shot.id]?.shift, t(10))
        XCTAssertNil(found["clip_title"], "added and removed again is no change")

        try c.run("Title", .insertClip(trackID: f.track("Text").id, clip: Clip(id: "clip_title2", content: .text(TextContent(text: "HELLO")), start: t(2), duration: t(3)), mode: nil))
        try c.run("Gone", .removeClips(clipIDs: [music.id], ripple: nil, includeLinked: nil))
        let later = Dictionary(uniqueKeysWithValues: changes(f.project, c.project).map { ($0.id, $0) })
        XCTAssertEqual(later["clip_title2"]?.kind, .added)
        XCTAssertEqual(later["clip_title2"]?.content, "text \"HELLO\"")
        XCTAssertEqual(later[music.id]?.kind, .removed)
        XCTAssertEqual(later[music.id]?.track, "A2 Music")
        XCTAssertEqual(later[music.id]?.content, "bed.m4a")
    }

    /// A ripple trim moves everything after it; the edit was at the trim.
    func testARippleEditIsPlacedWhereItWasNotWhereThingsRodeAlong() throws {
        let (_, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10), trackIDs: nil, clipIDs: nil))
        let cut = c.project
        try c.run("Ripple", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)), trackIDs: nil))
        let found = changes(cut, c.project)
        XCTAssertTrue(found.contains { $0.shift == t(-1) }, "the later pieces rode along")
        XCTAssertTrue(found.contains { $0.details.first == "start trimmed +1.000s, rippled" }, "\(found.map(\.details))")
        let place = try XCTUnwrap(EditPlace.between(cut, c.project))
        XCTAssertEqual(place.start, t(10))
        XCTAssertEqual(place.end, t(11))
        XCTAssertTrue(place.tracks.contains("A1 Voice"), "\(place.tracks)")
        XCTAssertFalse(place.tracks.contains("V3 B-roll"), "the B-roll only moved with its words: \(place.tracks)")
        XCTAssertFalse(place.tracks.contains("A2 Music"), "the bed only lost a second off its end: \(place.tracks)")
    }

    func testABladeIsPlacedAtTheCut() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(12.5), trackIDs: [f.track("Music").id], clipIDs: nil))
        let place = try XCTUnwrap(EditPlace.between(f.project, c.project))
        XCTAssertEqual(place.start, t(12.5))
        XCTAssertEqual(place.end, t(12.5))
        XCTAssertEqual(place.tracks, ["A2 Music"])
        XCTAssertEqual(place.description, "at 00:12.500 on A2 Music")
    }
}

final class EditHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var logURL: URL { folder.appendingPathComponent("Fixture.history.jsonl") }

    func testEveryChangeIsRecordedWithWhereItWas() throws {
        let (f, c) = try Fixture.edited()
        let recorder = HistoryRecorder(coordinator: c, url: logURL)
        let shot = f.clips("B-roll")[0]
        try c.apply(EditBatch(label: "Trim", author: "user", commands: [.trim(clipID: shot.id, edge: .end, to: t(24), ripple: nil, includeLinked: nil)]))
        c.undo()
        let records = recorder.records()
        XCTAssertEqual(records.map(\.kind), [.opened, .edit, .undo])
        XCTAssertEqual(records.map(\.revision), [1, 2, 3])
        XCTAssertEqual(records[1].label, "Trim")
        XCTAssertEqual(records[1].author, "user")
        XCTAssertEqual(records[1].place, EditPlace(start: t(24), end: t(25), tracks: ["V3 B-roll"]))
        XCTAssertEqual(records[2].place, EditPlace(start: t(24), end: t(25), tracks: ["V3 B-roll"]))
        recorder.close()
    }

    /// The timeline at an earlier revision comes back from the history,
    /// in this session or a later one.
    func testTheTimelineAtAnEarlierRevisionComesBack() throws {
        let (f, c) = try Fixture.edited()
        var recorder = HistoryRecorder(coordinator: c, url: logURL)
        var states: [Int: TimelineClips] = [c.revision: TimelineClips(c.project)]
        let shot = f.clips("B-roll")[0]
        try c.run("Cut", .blade(at: t(10), trackIDs: nil, clipIDs: nil))
        states[c.revision] = TimelineClips(c.project)
        try c.run("Ripple", .rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)), trackIDs: nil))
        states[c.revision] = TimelineClips(c.project)
        try c.run("Gain", .updateClip(clipID: shot.id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        states[c.revision] = TimelineClips(c.project)
        c.undo()
        states[c.revision] = TimelineClips(c.project)
        recorder.close()

        // A later session, as the next CLI command or an app restart would be.
        recorder = HistoryRecorder(coordinator: c, url: logURL)
        try c.run("Remove", .removeClips(clipIDs: [shot.id], ripple: nil, includeLinked: nil))
        states[c.revision] = TimelineClips(c.project)
        let records = recorder.records()
        XCTAssertEqual(records.filter { $0.kind == .opened }.count, 1, "the chain carried on, so no new start")

        for (revision, expected) in states {
            let walk = try HistoryChain.walk(records, current: TimelineClips(c.project), currentRevision: c.revision, back: revision)
            XCTAssertTrue(walk.states.first!.matches(expected), "revision \(revision)")
            XCTAssertEqual(walk.records.count, c.revision - revision)
            XCTAssertEqual(walk.states.count, walk.records.count + 1)
        }
        recorder.close()
    }

    func testTheChainStopsWhereTheProjectChangedOutsideTheHistory() throws {
        let (f, c) = try Fixture.edited()
        var recorder = HistoryRecorder(coordinator: c, url: logURL)
        try c.run("Gain", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        recorder.close()
        // Edited by something that kept no history: the revision jumps.
        let elsewhere = ProjectCoordinator(project: c.project, revision: c.revision + 3)
        recorder = HistoryRecorder(coordinator: elsewhere, url: logURL)
        try elsewhere.run("Marker", .addMarker(marker: Marker(time: t(5), name: "M")))
        let records = recorder.records()
        XCTAssertEqual(records.last?.revision, 6)
        XCTAssertNoThrow(try HistoryChain.walk(records, current: TimelineClips(elsewhere.project), currentRevision: 6, back: 5))
        XCTAssertThrowsError(try HistoryChain.walk(records, current: TimelineClips(elsewhere.project), currentRevision: 6, back: 2)) { error in
            XCTAssertEqual((error as? HistoryGap)?.earliest, 5)
        }
        XCTAssertThrowsError(try HistoryChain.walk(records, current: TimelineClips(elsewhere.project), currentRevision: 6, back: 7))
        recorder.close()
    }

    func testEditsTheJournalReplayedAfterACrashAreRecorded() throws {
        let (f, c) = try Fixture.edited()
        let journal = ProjectJournal(url: folder.appendingPathComponent("Fixture.journal.jsonl"))
        let saved = c.project
        let crashed = ProjectCoordinator(project: saved, revision: 1, journal: journal)
        try crashed.run("Gain", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        var replays: [(entry: ProjectJournal.Entry, before: Project, after: Project)] = []
        let recovered = try XCTUnwrap(journal.recover(project: saved, revision: 1) { replays.append(($0, $1, $2)) })
        let reopened = ProjectCoordinator(project: recovered.project, revision: recovered.revision)
        let recorder = HistoryRecorder(coordinator: reopened, url: logURL, replayed: replays)
        let records = recorder.records()
        XCTAssertEqual(records.map(\.label), ["Opened", "Gain"])
        XCTAssertNoThrow(try HistoryChain.walk(records, current: TimelineClips(reopened.project), currentRevision: 2, back: 1))
        recorder.close()
    }
}

/// What the history keeps for `tandem rounds`: the words of Mike's
/// comments, and each time an agent handed a round back.
final class ReviewHistoryTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-review-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var logURL: URL { folder.appendingPathComponent("Fixture.history.jsonl") }

    func testACommentsWordsAndTimeAreKeptWhenItsAddedOrEdited() throws {
        let (f, c) = try Fixture.edited()
        let recorder = HistoryRecorder(coordinator: c, url: logURL)
        try c.apply(XCTUnwrap(CommentEdits.add("Cut the umm here", at: t(12), id: "mk_umm")))
        try c.apply(XCTUnwrap(CommentEdits.edit(XCTUnwrap(c.project.comments.first), to: "Cut the umm and the breath")))
        try c.run("Gain", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        var resolve = CommentEdits.remove(["mk_umm"], label: "Resolve comment")
        resolve.author = "claude"
        try c.apply(resolve)
        recorder.close()

        let records = EditHistoryLog(url: logURL).records()
        XCTAssertEqual(records.map(\.label), ["Opened", "Add comment", "Edit comment", "Gain", "Resolve comment"])
        XCTAssertEqual(records[1].comments, [HistoryComment(id: "mk_umm", time: t(12), text: "Cut the umm here")])
        XCTAssertEqual(records[2].comments, [HistoryComment(id: "mk_umm", time: t(12), text: "Cut the umm and the breath")])
        XCTAssertNil(records[3].comments, "no comment changed")
        XCTAssertNil(records[4].comments, "taking one away keeps no words")
    }

    func testAHandbackIsARowOfItsOwnThatTheChainStepsOver() throws {
        let (f, c) = try Fixture.edited()
        let recorder = HistoryRecorder(coordinator: c, url: logURL)
        try c.run("Gain", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-6)])])))
        let before = TimelineClips(c.project)
        try c.run("Trim", .trim(clipID: f.clips("B-roll")[0].id, edge: .end, to: t(24), ripple: nil, includeLinked: nil))
        recorder.handedBack(by: "claude", count: 3)
        try c.run("Gain again", .updateClip(clipID: f.clips("Music")[0].id, patch: .object(["audio": .object(["gainDB": .number(-9)])])))
        let records = recorder.records()
        recorder.close()

        let handback = try XCTUnwrap(records.first { $0.kind == .handback })
        XCTAssertEqual(handback.author, "claude")
        XCTAssertEqual(handback.revision, 3, "the revision it was handed back at")
        XCTAssertEqual(handback.handedBack, 3)
        XCTAssertEqual(records.map(\.kind), [.opened, .edit, .edit, .handback, .edit])
        let walk = try HistoryChain.walk(records, current: TimelineClips(c.project), currentRevision: c.revision, back: 2)
        XCTAssertEqual(walk.records.map(\.label), ["Trim", "Gain again"], "the handback isn't an edit to undo")
        XCTAssertTrue(walk.states[0].matches(before))
        XCTAssertEqual(HistoryChain.earliest(records, currentRevision: c.revision), 1)
    }

    /// Old files have neither, and a newer Tandem's rows of a kind this one
    /// doesn't know are skipped rather than spoiling the rest.
    func testOldAndNewerHistoryStillReads() throws {
        try Data("""
        {"author":"system","date":"2026-11-12T03:37:05Z","kind":"opened","label":"Opened","revision":0}
        {"author":"user","date":"2026-11-12T04:25:05Z","kind":"edit","label":"Add comment","revision":1,"summary":"markers"}
        {"author":"claude","date":"2026-11-12T04:26:05Z","kind":"somethingNewer","label":"?","revision":1}
        {"author":"claude","date":"2026-11-12T04:27:05Z","handedBack":2,"kind":"handback","label":"Hand back","revision":1}

        """.utf8).write(to: logURL)
        let records = EditHistoryLog(url: logURL).records()
        XCTAssertEqual(records.map(\.kind), [.opened, .edit, .handback])
        XCTAssertNil(records[1].comments)
        XCTAssertEqual(records[2].handedBack, 2)
    }
}
