import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Records `commands` in `log` as an agent's batch, the way the session's
/// recorder does.
@discardableResult
private func agentEdit(_ f: AppFixture, _ log: inout ReviewLog, _ label: String, by author: String = "claude", _ commands: [EditCommand]) throws -> Int {
    let before = f.project
    let revision = try f.coordinator.apply(EditBatch(label: label, author: author, commands: commands)).revision
    log.follow(from: before, to: f.project)
    log.record(label: label, author: author, revision: revision, date: Date(timeIntervalSince1970: 1_790_000_000 + Double(revision)), before: before, after: f.project)
    log.prune(in: f.project, reverts: false)
    return revision
}

/// The log placed on the timeline: highlights, marks and the stretches the
/// ruler's band covers and the playhead steps through.
@MainActor
final class TimelineReviewTests: XCTestCase {
    func testNothingToReviewIsEmpty() throws {
        let f = try AppFixture()
        XCTAssertEqual(TimelineReview.make(log: ReviewLog(), project: f.project), .empty)
        XCTAssertTrue(TimelineReview.empty.isEmpty)
    }

    /// Changes close together share a band and a stop; one far away has
    /// its own. A removal is a moment at its join.
    func testCloseChangesShareABandAndAStop() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "Whoosh", [.placeMedia(mediaIDs: ["med_broll"], at: t(26), duration: t(1))])
        try agentEdit(f, &log, "Tighten", [.rippleDeleteRange(range: TimeRange(start: t(45), end: t(46)))])
        let review = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(review.editCount, 2)
        XCTAssertEqual(review.chipTitle, "2 agent edits")
        XCTAssertEqual(review.clipIDs.count, 1)
        XCTAssertEqual(Set(review.removals.map(\.time)), [t(45)])
        XCTAssertEqual(review.regions, [TimelineReview.Region(start: t(26), end: t(27)), TimelineReview.Region(start: t(45), end: t(45))])
        XCTAssertEqual(review.stops.map(\.time), [t(26), t(45)])
        XCTAssertEqual(review.stops.map { $0.edits.map(\.label) }, [["Whoosh"], ["Tighten"]], "one stop for the cut on all three take tracks")

        // Another shot a second after the first joins its band and stop.
        try agentEdit(f, &log, "Push", [.placeMedia(mediaIDs: ["med_broll"], at: t(28), duration: t(2))])
        let joined = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(joined.regions.map(\.start), [t(26), t(45)])
        XCTAssertEqual(joined.regions.first?.end, t(30))
        XCTAssertEqual(joined.stops.first?.edits.map(\.label), ["Whoosh", "Push"])
    }

    /// A long change, like a ducked music bed, covers the band from end to
    /// end but is one stop at its start, so stepping still finds the rest.
    func testALongChangeDoesntSwallowTheStops() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "Whoosh", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(1))])
        try agentEdit(f, &log, "Duck the music", [.updateClip(clipID: f.clip("Music").id, patch: .object(["audio": .object(["gainDB": .number(-34)])]))])
        let review = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(review.regions, [TimelineReview.Region(start: .zero, end: t(60))])
        XCTAssertEqual(review.stops.map(\.time), [.zero, t(40)])
        XCTAssertEqual(review.edits(at: t(40.5)).map(\.label), ["Whoosh", "Duck the music"])
        XCTAssertEqual(review.edits(at: t(10)).map(\.label), ["Duck the music"])
    }

    /// The stretches follow their clips when Mike tightens the take.
    func testTheStretchesFollowTheirClips() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "Whoosh", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(1))])
        try agentEdit(f, &log, "Mike's", by: "user", [.rippleDeleteRange(range: TimeRange(start: t(10), end: t(13)))])
        let review = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(review.stops.map(\.time), [t(37)])
    }

    func testStepsThroughTheChangesInOrder() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "A", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(1))])
        try agentEdit(f, &log, "B", [.placeMedia(mediaIDs: ["med_broll"], at: t(5), duration: t(1))])
        try agentEdit(f, &log, "C", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(1))])
        let review = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(review.stops.map(\.time), [t(5), t(40), t(50)], "time order, not the order they were made in")
        XCTAssertEqual(review.stop(after: .zero)?.time, t(5))
        XCTAssertEqual(review.stop(after: t(5))?.time, t(40), "from a stop, on to the next")
        XCTAssertEqual(review.stop(after: t(45))?.time, t(50))
        XCTAssertNil(review.stop(after: t(50)))
        XCTAssertEqual(review.stop(before: t(60))?.time, t(50))
        XCTAssertEqual(review.stop(before: t(50))?.time, t(40))
        XCTAssertEqual(review.stop(before: t(40.5))?.time, t(40), "from inside a change, back to its start")
        XCTAssertNil(review.stop(before: t(5)))
    }

    func testTheTooltipSaysWhoWhatAndWhen() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "Add push", [.placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(1))])
        try agentEdit(f, &log, "Whoosh", by: "codex", [.placeMedia(mediaIDs: ["med_broll"], at: t(41), duration: t(1))])
        let review = TimelineReview.make(log: log, project: f.project)
        let date = log.entries[0].date
        let tip = TimelineReview.tooltip(for: review.edits(at: t(41)), now: date)
        let lines = tip.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Claude · Add push · \(date.formatted(date: .omitted, time: .shortened))")
        XCTAssertTrue(lines[1].hasPrefix("Codex · Whoosh · "))
        XCTAssertEqual(review.edits(at: t(30)), [])
    }

    /// What an agent handed back to look at is placed with the changes,
    /// named on the chip and in the band's tooltip, and counts as
    /// something to review on its own.
    func testThingsToLookAtArePlacedAndNamed() throws {
        let f = try AppFixture()
        var log = ReviewLog()
        try agentEdit(f, &log, "Whoosh", [.placeMedia(mediaIDs: ["med_broll"], at: t(26), duration: t(1))])
        log.handBack([ReviewNote(id: "look_a", author: "claude", revision: 2, start: t(40), end: t(44), name: "The new shot", note: "Listen for the click", question: true)], by: "claude")
        let review = TimelineReview.make(log: log, project: f.project)
        XCTAssertEqual(review.notes.map(\.id), ["look_a"])
        XCTAssertEqual(review.notes.first?.note, "Listen for the click")
        XCTAssertEqual(review.chipTitle, "1 to look at · 1 agent edit")
        XCTAssertEqual(review.stops.map(\.time), [t(26)], "a thing to look at isn't a stop; the walkthrough has it")
        XCTAssertEqual(review.notes(at: t(42)).map(\.name), ["The new shot"])
        XCTAssertEqual(review.notes(at: t(30)), [])
        XCTAssertEqual(TimelineReview.tooltip(for: review.notes(at: t(42)), edits: []), "Question (Claude): The new shot")
        let both = TimelineReview.tooltip(for: review.notes(at: t(42)), edits: review.edits(at: t(26.5)), now: log.entries[0].date)
        XCTAssertTrue(both.hasPrefix("Question (Claude): The new shot\nClaude · Whoosh · "), both)

        let only = TimelineReview.make(log: ReviewLog(notes: log.notes), project: f.project)
        XCTAssertFalse(only.isEmpty)
        XCTAssertEqual(only.chipTitle, "1 to look at")
        XCTAssertEqual(only.stops, [])
    }

    /// Only the chevron keys and Option-] are the review's, and nothing else
    /// already used them.
    func testTheReviewKeys() throws {
        let keymap = try Keymap.load(KeymapTests.bundledKeymapData())
        XCTAssertEqual(keymap.command(for: KeyChord("[")!), .previousAgentChange)
        XCTAssertEqual(keymap.command(for: KeyChord("]")!), .nextAgentChange)
        XCTAssertEqual(keymap.command(for: KeyChord("option+]")!), .markAgentChangesReviewed)
        for command: EditorCommand in [.previousAgentChange, .nextAgentChange, .markAgentChangesReviewed] {
            XCTAssertEqual(keymap.chords(for: command).count, 1, command.rawValue)
            XCTAssertNotNil(Icons.command(command), command.rawValue)
        }
        XCTAssertEqual(Shortcuts.help("Next agent change", .nextAgentChange, in: keymap), "Next agent change (])")
        XCTAssertTrue(KeyboardRouter.repeatable.contains(.nextAgentChange))
    }
}

/// The editor's side: agent edits arrive from the session's recorder, the
/// playhead steps through them, and Mark reviewed clears them.
@MainActor
final class ReviewModelTests: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-review-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Review.tandem"), name: "Review", owner: .app)
        model = EditorModel(session: session)
        let fixture = try AppFixture()
        model.apply(EditBatch(label: "Media", commands: fixture.project.media.map { .addMedia(item: $0) }))
        model.apply(EditBatch(label: "Build", commands: [
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60)),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(60))
        ]))
        model.timeline.lanesWidth = 600
        model.timeline.scale = TimelineScale(pixelsPerSecond: 20, scrollSeconds: 0)
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
    }

    /// An edit through the API, the way an agent's arrives.
    private func agent(_ label: String, _ commands: [EditCommand], author: String = "claude") throws {
        try model.session.coordinator.apply(EditBatch(label: label, author: author, commands: commands))
        settle()
    }

    /// Lets the recorder and the main thread hand the change over.
    private func settle() {
        for _ in 0..<50 {
            let log = model.session.review.log
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            if model.reviewLog == log && model.revision == model.session.coordinator.revision { return }
        }
    }

    func testAgentEditsArriveAndMikesDont() throws {
        try agent("Mike's", [.placeMedia(mediaIDs: ["med_broll"], at: t(10), duration: t(2))], author: "user")
        XCTAssertTrue(model.review.isEmpty)
        try agent("Add push", [.placeMedia(mediaIDs: ["med_broll"], at: t(20), duration: t(2))])
        XCTAssertEqual(model.review.editCount, 1)
        XCTAssertEqual(model.review.regions.map(\.start), [t(20)])
        XCTAssertTrue(EditorActions(model: model).canPerform(.nextAgentChange))
    }

    func testNextAndPreviousMoveThePlayheadAndScrollToTheChange() throws {
        try agent("A", [.placeMedia(mediaIDs: ["med_broll"], at: t(8), duration: t(1))])
        try agent("B", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(1))])
        let actions = EditorActions(model: model)
        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.playhead, t(8))
        XCTAssertEqual(model.timeline.scale.scrollSeconds, 0, "already in view")
        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.playhead, t(50))
        // 600 points at 20 a second show 30 s: 50 s comes into view a
        // quarter of the way in.
        XCTAssertEqual(model.timeline.scale.scrollSeconds, 50 - 7.5, accuracy: 0.001)
        XCTAssertFalse(actions.perform(.nextAgentChange), "nothing after the last")
        XCTAssertTrue(actions.perform(.previousAgentChange))
        XCTAssertEqual(model.playhead, t(8))
    }

    func testTheChipsCountGoesRoundTheChangesToReview() throws {
        try agent("A", [.placeMedia(mediaIDs: ["med_broll"], at: t(8), duration: t(1))])
        try agent("B", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(1))])
        model.playback.seek(to: t(30))
        XCTAssertTrue(model.goToAgentChange(forward: true, wrap: true))
        XCTAssertEqual(model.playhead, t(50), "the start of the next one")
        XCTAssertTrue(model.goToAgentChange(forward: true, wrap: true))
        XCTAssertEqual(model.playhead, t(8), "after the last, back to the first")
        XCTAssertTrue(model.goToAgentChange(forward: true, wrap: true))
        XCTAssertEqual(model.playhead, t(50))
    }

    func testMarkReviewedClearsTheHighlightsAndTheLog() throws {
        try agent("Add push", [.placeMedia(mediaIDs: ["med_broll"], at: t(20), duration: t(2))])
        let url = try XCTUnwrap(model.session.review.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let actions = EditorActions(model: model)
        XCTAssertTrue(actions.canPerform(.markAgentChangesReviewed))
        XCTAssertTrue(actions.perform(.markAgentChangesReviewed))
        XCTAssertTrue(model.review.isEmpty)
        XCTAssertTrue(model.session.review.log.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(actions.canPerform(.markAgentChangesReviewed))
        XCTAssertFalse(actions.canPerform(.nextAgentChange))
    }

    /// An agent hands back with things to look at, the way `tandem
    /// handback` does.
    private func handBack(_ notes: [(start: Double, end: Double, name: String)]) {
        model.session.review.handBack(notes.map { ReviewNote(author: "claude", revision: model.revision, start: t($0.start), end: t($0.end), name: $0.name) }, by: "claude")
        settle()
    }

    /// A handback is announced, and Next agent change walks through its
    /// things first, in timeline order, before the other changes.
    func testAHandbackIsWalkedThroughBeforeTheOtherChanges() throws {
        try agent("A", [.placeMedia(mediaIDs: ["med_broll"], at: t(8), duration: t(1))])
        try agent("B", [.placeMedia(mediaIDs: ["med_broll"], at: t(50), duration: t(1))])
        handBack([(40, 44, "The new shot"), (2, 6, "Angles")])
        XCTAssertEqual(model.review.chipTitle, "2 to look at · 2 agent edits")
        XCTAssertEqual(model.status?.text, "Claude handed back 2 things to look at. Press ] to be walked through them, or review as usual.")
        let actions = EditorActions(model: model)
        XCTAssertTrue(actions.canPerform(.nextAgentChange))

        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.playhead, t(2), "the first thing to look at, not the first change")
        XCTAssertEqual(model.walkthrough?.note.name, "Angles")
        XCTAssertEqual(model.walkthrough?.index, 0)
        XCTAssertEqual(model.walkthrough?.count, 2)
        XCTAssertTrue(model.playback.isPlaying, "its stretch plays")
        model.playback.pause()

        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.playhead, t(40))
        XCTAssertEqual(model.walkthrough?.index, 1)
        model.playback.pause()
        XCTAssertTrue(actions.perform(.previousAgentChange))
        XCTAssertEqual(model.playhead, t(2))
        model.playback.pause()
        XCTAssertTrue(actions.perform(.nextAgentChange))
        model.playback.pause()

        // After the last, the other changes, from the first.
        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertNil(model.walkthrough)
        XCTAssertEqual(model.playhead, t(8))
        XCTAssertEqual(model.status?.text, "That's all 2 things to look at. ] now steps through the other changes, from the first.")
        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.playhead, t(50))
        XCTAssertFalse(model.playback.isPlaying, "ordinary stepping doesn't play")

        // The chip's count starts the walkthrough again.
        XCTAssertTrue(model.goToAgentChange(forward: true, wrap: true))
        XCTAssertEqual(model.playhead, t(2))
        XCTAssertEqual(model.walkthrough?.index, 0)
        model.playback.pause()
    }

    /// Escape skips the walkthrough, watching a stretch clears its thing on
    /// its own, and Mark reviewed clears the rest.
    func testTheWalkthroughIsSkippableAndClears() throws {
        handBack([(10, 14, "The new shot"), (40, 44, "Angles")])
        let actions = EditorActions(model: model)
        XCTAssertFalse(model.skipWalkthrough(), "nothing to skip until a card shows")
        XCTAssertTrue(actions.perform(.nextAgentChange))
        model.playback.pause()
        XCTAssertNotNil(model.walkthrough)
        XCTAssertTrue(actions.perform(.deselectAll), "Escape")
        XCTAssertNil(model.walkthrough)
        XCTAssertEqual(model.status?.text, "Walkthrough skipped. ] steps through every change; click the count on the review chip to start it again.")
        XCTAssertFalse(actions.perform(.nextAgentChange), "no changes besides the things to look at")
        XCTAssertEqual(model.playhead, t(10), "stayed put")

        model.noteWatched(from: t(9), to: t(15))
        settle()
        XCTAssertEqual(model.review.notes.map(\.name), ["Angles"], "watched, so it went")
        XCTAssertEqual(model.review.chipTitle, "1 to look at")

        XCTAssertTrue(actions.canPerform(.markAgentChangesReviewed))
        XCTAssertTrue(actions.perform(.markAgentChangesReviewed))
        XCTAssertTrue(model.review.isEmpty)
        XCTAssertTrue(model.session.review.log.isEmpty)
        XCTAssertEqual(model.status?.text, "Marked 1 thing to look at reviewed.")
        XCTAssertFalse(actions.canPerform(.nextAgentChange))
    }

    /// A new round's handback starts the walkthrough over, even after the
    /// last one was skipped.
    func testANewHandbackStartsTheWalkthroughAgain() throws {
        handBack([(10, 14, "The new shot")])
        let actions = EditorActions(model: model)
        XCTAssertTrue(actions.perform(.nextAgentChange))
        model.playback.pause()
        XCTAssertTrue(model.skipWalkthrough())
        handBack([(30, 34, "Round two")])
        XCTAssertEqual(model.status?.text, "Claude handed back 1 thing to look at. Press ] to be walked through them, or review as usual.")
        XCTAssertTrue(actions.perform(.nextAgentChange))
        XCTAssertEqual(model.walkthrough?.note.name, "Round two")
        XCTAssertEqual(model.walkthrough?.count, 1)
        model.playback.pause()
    }

    /// Undoing the agent's edit in the app takes its highlight with it.
    func testUndoingTheAgentsEditTakesItsHighlight() throws {
        try agent("Add push", [.placeMedia(mediaIDs: ["med_broll"], at: t(20), duration: t(2))])
        XCTAssertFalse(model.review.isEmpty)
        model.undo()
        settle()
        XCTAssertTrue(model.review.isEmpty)
    }
}
