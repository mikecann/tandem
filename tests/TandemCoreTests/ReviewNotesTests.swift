import XCTest
@testable import TandemCore

/// The things an agent asks Mike to look at when it hands a round back:
/// kept in the review log, moved with the take, cleared by watching.
final class ReviewNotesTests: XCTestCase {
    private func note(_ id: String, _ start: Double, _ end: Double, _ name: String = "Look", by author: String = "claude", question: Bool = false) -> ReviewNote {
        ReviewNote(id: id, author: author, date: Date(timeIntervalSince1970: 1_790_000_000), revision: 7, start: t(start), end: t(end), name: name, question: question)
    }

    /// Runs a batch and carries the log along the way the recorder does.
    private func run(_ c: ProjectCoordinator, _ log: inout ReviewLog, _ commands: [EditCommand], by author: String = "user") throws {
        let before = c.project
        let result = try c.apply(EditBatch(label: "Edit", author: author, commands: commands))
        log.follow(from: before, to: c.project)
        log.record(label: "Edit", author: author, revision: result.revision, before: before, after: c.project)
        log.prune(in: c.project, reverts: false)
    }

    func testAHandbackReplacesTheSameAgentsNotesAndKeepsTimelineOrder() {
        var log = ReviewLog()
        XCTAssertTrue(log.isEmpty)
        log.handBack([note("look_b", 40, 44, "Second"), note("look_a", 10, 12, "First")], by: "claude")
        XCTAssertFalse(log.isEmpty, "something to look at counts as waiting for Mike")
        XCTAssertEqual(log.notes.map(\.id), ["look_a", "look_b"], "timeline order, whatever order they were given in")
        log.handBack([note("look_c", 20, 21, "Codex's", by: "codex")], by: "codex")
        XCTAssertEqual(log.notes.map(\.id), ["look_a", "look_c", "look_b"])
        // Claude hands back again: its old notes go, Codex's stay.
        log.handBack([note("look_d", 5, 6, "New round")], by: "claude")
        XCTAssertEqual(log.notes.map(\.id), ["look_d", "look_c"])
        log.handBack([], by: "codex")
        XCTAssertEqual(log.notes.map(\.id), ["look_d"], "handing back nothing withdraws them")
    }

    func testAnEndBeforeItsStartIsTheStart() {
        let point = ReviewNote(author: "claude", revision: 1, start: t(10), end: t(4), name: "A moment")
        XCTAssertEqual(point.end, t(10))
        XCTAssertEqual(point.range, TimeRange(start: t(10), end: t(10)))
    }

    /// Mike tightens the take while the notes wait: one after the cut
    /// comes up with the take, one across it shrinks to what's left, and
    /// one inside the cut closes to the join.
    func testNotesMoveWithTheTake() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        log.handBack([note("look_after", 40, 44), note("look_across", 9, 12), note("look_inside", 10.2, 10.8)], by: "claude")
        try run(c, &log, [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(11)))])
        let moved = Dictionary(uniqueKeysWithValues: log.notes.map { ($0.id, $0) })
        XCTAssertEqual(moved["look_after"]?.start, t(39))
        XCTAssertEqual(moved["look_after"]?.end, t(43))
        XCTAssertEqual(moved["look_across"]?.start, t(9))
        XCTAssertEqual(moved["look_across"]?.end, t(11))
        XCTAssertEqual(moved["look_inside"]?.start, t(10))
        XCTAssertEqual(moved["look_inside"]?.end, t(10), "closed to the join")
        XCTAssertEqual(log.notes.map(\.id), ["look_across", "look_inside", "look_after"], "still in timeline order")

        // Undo puts the take back, and the notes with it.
        let before = c.project
        _ = c.undo()
        log.follow(from: before, to: c.project, reverts: true)
        let back = Dictionary(uniqueKeysWithValues: log.notes.map { ($0.id, $0) })
        XCTAssertEqual(back["look_after"]?.start, t(40))
        XCTAssertEqual(back["look_after"]?.end, t(44))
        XCTAssertEqual(back["look_across"]?.end, t(12))
    }

    /// A change that doesn't move the take (B-roll placed) leaves them be.
    func testAnEditOffTheTakeLeavesThemBe() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        log.handBack([note("look_a", 40, 44)], by: "claude")
        try run(c, &log, [.placeMedia(mediaIDs: ["med_broll"], at: t(30), duration: t(3))], by: "claude")
        XCTAssertEqual(log.notes.first?.start, t(40))
        XCTAssertEqual(log.notes.first?.end, t(44))
        XCTAssertEqual(log.entries.count, 1, "the agent's edit still waits beside it")
    }

    /// Watching a note's stretch (give or take half a second at its ends)
    /// clears it, like a highlighted clip. Half of it doesn't.
    func testWatchingAStretchClearsItsNote() throws {
        let (_, c) = try Fixture.edited()
        var log = ReviewLog()
        log.handBack([note("look_a", 10, 14), note("look_b", 30, 34), note("look_point", 50, 50)], by: "claude")
        XCTAssertTrue(log.markWatched([TimeRange(start: t(10.4), end: t(13.7))], in: c.project))
        XCTAssertEqual(log.notes.map(\.id), ["look_b", "look_point"])
        XCTAssertFalse(log.markWatched([TimeRange(start: t(30), end: t(32))], in: c.project), "half watched: still there")
        XCTAssertEqual(log.notes.map(\.id), ["look_b", "look_point"])
        // A moment is watched when play went across it.
        XCTAssertTrue(log.markWatched([TimeRange(start: t(49), end: t(51))], in: c.project))
        XCTAssertEqual(log.notes.map(\.id), ["look_b"])
        XCTAssertFalse(log.isEmpty)
    }

    func testTheLogReadsBackWithAndWithoutNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Test.review.json")

        // A log from before notes existed.
        try Data(#"{"version": 1, "entries": []}"#.utf8).write(to: url)
        XCTAssertEqual(ReviewLog.load(from: url), ReviewLog())

        var log = ReviewLog()
        var asked = note("look_q", 20, 25, "Keep this line?", question: true)
        asked.note = "Pro is $25, not $20."
        log.handBack([asked, note("look_a", 2, 4, "Angles")], by: "claude")
        try log.save(to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "notes alone are worth keeping")
        let loaded = ReviewLog.load(from: url)
        XCTAssertEqual(loaded, log)
        XCTAssertEqual(loaded.notes.map(\.name), ["Angles", "Keep this line?"])
        XCTAssertEqual(loaded.notes.last?.note, "Pro is $25, not $20.")
        XCTAssertEqual(loaded.notes.last?.question, true)

        try ReviewLog().save(to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "nothing waiting: no file")
    }

    /// The recorder keeps them beside the edits: saved for the next open,
    /// heard by the app, cleared by Mark reviewed.
    func testTheRecorderKeepsThemUntilMarkReviewed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".tandem"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = ProjectFile.reviewURL(for: folder.appendingPathComponent("Test.tandem"))
        let (_, c) = try Fixture.edited()
        let recorder = ReviewRecorder(coordinator: c, url: url)
        var heard: [ReviewLog] = []
        recorder.observe { heard.append($0) }
        recorder.handBack([note("look_a", 40, 44)], by: "claude")
        XCTAssertEqual(recorder.log.notes.map(\.id), ["look_a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        recorder.handBack([note("look_a", 40, 44)], by: "claude")
        XCTAssertEqual(heard.count, 1, "the same again isn't news")
        recorder.close()

        let reopened = ReviewRecorder(coordinator: c, url: url)
        XCTAssertEqual(reopened.log.notes.map(\.id), ["look_a"])
        reopened.markReviewed()
        XCTAssertTrue(reopened.log.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        reopened.close()
    }
}
