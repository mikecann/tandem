import AppKit
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// Things Mike does in the editor, done the way he does them (keys, clicks,
/// drags and drops in a real window) and checked by what they change.
/// Each one is a feature that has worked at some point; these keep it
/// working as the app grows. `EditorHarness` explains the timeline they
/// start from.
@MainActor
final class EditorBehaviourTests: XCTestCase {
    private var editor: EditorHarness!

    override func setUp() async throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        editor = try EditorHarness()
    }

    override func tearDown() async throws {
        editor?.close()
        editor = nil
    }

    // MARK: - Cutting

    func testTheBladeToolCutsAClipWhereItsClicked() {
        editor.press("c")
        XCTAssertEqual(editor.model.tool, .blade)
        let camera = editor.clip("Camera")
        editor.click(editor.point(of: camera.id, at: 10))
        let starts = editor.clips("Camera").map(\.start.seconds)
        XCTAssertEqual(starts.count, 2, "\(starts)")
        XCTAssertEqual(starts.last ?? 0, 10, accuracy: 0.1)
        editor.press("v")
        XCTAssertEqual(editor.model.tool, .select)
    }

    func testRippleDeleteTakesOutAPieceAndClosesTheGap() throws {
        let camera = editor.clip("Camera").id
        editor.model.apply(EditBatch(label: "Cuts", commands: [.blade(at: t(20), clipIDs: [camera]), .blade(at: t(10), clipIDs: [camera])]))
        editor.settle()
        let middle = editor.clip("Camera", 1)
        XCTAssertEqual(middle.start, t(10))
        editor.click(editor.point(of: middle.id))
        XCTAssertTrue(editor.model.selection.contains(middle.id))
        editor.press("shift+delete")
        let ranges = editor.clips("Camera").map { [$0.start.seconds, $0.end.seconds] }
        XCTAssertEqual(ranges, [[0, 10], [10, 50]], "the ten seconds went and the rest closed up")
    }

    // MARK: - Selecting and moving

    func testSelectForwardPicksEverythingAfterThePlayheadAndADragMovesItAll() {
        editor.model.playback.seek(to: t(15))
        editor.press("cmd+shift+a")
        let broll = editor.clip("B-roll")
        XCTAssertEqual(editor.model.selection, [broll.id], "only the B-roll starts after 15 s")
        let from = editor.point(of: broll.id)
        editor.drag(from, to: CGPoint(x: from.x + 40, y: from.y))
        XCTAssertEqual(editor.clip("B-roll").start.seconds, 22, accuracy: 0.1, "40 points at 20 a second")
    }

    func testUndoAndRedoAMove() {
        let broll = editor.clip("B-roll")
        let from = editor.point(of: broll.id)
        editor.drag(from, to: CGPoint(x: from.x + 60, y: from.y))
        XCTAssertEqual(editor.clip("B-roll").start.seconds, 23, accuracy: 0.1)
        editor.press("cmd+z")
        XCTAssertEqual(editor.clip("B-roll").start.seconds, 20, accuracy: 0.001)
        editor.press("cmd+shift+z")
        XCTAssertEqual(editor.clip("B-roll").start.seconds, 23, accuracy: 0.1)
    }

    func testDraggingAClipAboveTheTopTrackPutsItOnANewOne() throws {
        let tracks = editor.project.videoTracks.count
        let broll = editor.clip("B-roll")
        let from = editor.point(of: broll.id)
        // Up past the top track, onto the ruler.
        editor.drag(from, to: CGPoint(x: from.x, y: from.y - 260))
        XCTAssertEqual(editor.project.videoTracks.count, tracks + 1)
        XCTAssertEqual(editor.project.videoTracks.last?.clips.map(\.id), [broll.id], "on a new top track")
        editor.press("cmd+z")
        XCTAssertEqual(editor.project.videoTracks.count, tracks, "one undo takes the track away too")
        XCTAssertEqual(editor.clip("B-roll").id, broll.id)
    }

    func testDraggingSoundBelowTheBottomTrackPutsItOnANewOne() throws {
        let tracks = editor.project.audioTracks.count
        let music = editor.clip("Music")
        let from = editor.point(of: music.id, at: 10)
        editor.drag(from, to: CGPoint(x: from.x, y: from.y + 120))
        XCTAssertEqual(editor.project.audioTracks.count, tracks + 1)
        XCTAssertEqual(editor.project.audioTracks.last?.clips.map(\.id), [music.id], "on a new bottom track")
    }

    // MARK: - Comments

    private var timeline: TimelineContainerView { editor.view(TimelineContainerView.self)! }

    func testShiftCOpensACommentAtThePlayheadAndReturnKeepsIt() throws {
        editor.model.playback.seek(to: t(12))
        editor.press("shift+c")
        let box = try XCTUnwrap(timeline.commentBox, "the box opens under the ruler")
        XCTAssertEqual(box.request.time, t(12))
        XCTAssertNil(box.request.comment)
        XCTAssertEqual(box.popover?.isShown, true)
        XCTAssertTrue(box.field.window?.firstResponder === box.field.currentEditor(), "ready to type")
        box.field.stringValue = "  Cut the umm "
        box.save()
        XCTAssertEqual(box.popover?.isShown, false)
        XCTAssertEqual(editor.project.comments.map(\.name), ["Cut the umm"])
        XCTAssertEqual(editor.project.comments.first?.time, t(12))
        XCTAssertEqual(editor.model.undoLabel, "Add comment")
        editor.press("cmd+z")
        XCTAssertTrue(editor.project.comments.isEmpty, "one undo takes it away")
    }

    func testClickingAwayKeepsWhatsWrittenAndEscapeDoesnt() throws {
        editor.model.playback.seek(to: t(8))
        editor.press("shift+c")
        let kept = try XCTUnwrap(timeline.commentBox)
        kept.field.stringValue = "Louder here"
        kept.popover?.close()
        XCTAssertEqual(editor.project.comments.map(\.name), ["Louder here"], "a stray click doesn't lose it")

        editor.model.playback.seek(to: t(20))
        editor.press("shift+c")
        let dropped = try XCTUnwrap(timeline.commentBox)
        XCTAssertFalse(dropped === kept)
        dropped.field.stringValue = "Never mind"
        _ = dropped.control(dropped.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(editor.project.comments.map(\.name), ["Louder here"], "Escape drops it")
    }

    func testCommentsHaveAStripOfTheirOwnWhileThereAreAny() throws {
        let comments = timeline.stripView(.comments)
        XCTAssertTrue(comments.isHidden, "no comments, no strip")
        let lanesTop = timeline.lanes.frame.minY
        editor.model.apply(try XCTUnwrap(CommentEdits.add("B-roll here", at: t(25), id: "mk_note")))
        editor.settle()
        XCTAssertFalse(comments.isHidden)
        XCTAssertEqual(comments.frame.minY, timeline.stripView(.markers).frame.maxY, "under the markers' strip")
        XCTAssertEqual(timeline.lanes.frame.minY, lanesTop + Theme.Metrics.markerStripHeight, "the tracks make room")
        editor.model.deleteComment(try XCTUnwrap(editor.project.comments.first))
        editor.settle()
        XCTAssertTrue(comments.isHidden, "gone with the last comment")
        XCTAssertEqual(timeline.lanes.frame.minY, lanesTop)
    }

    func testMarkersAndToDosHaveStripsOfTheirOwnAndTheRulerKeepsItsTimeCode() throws {
        let markers = timeline.stripView(.markers)
        let todos = timeline.stripView(.todos)
        let section = try XCTUnwrap(editor.project.markers.first, "the fixture's section marker")
        XCTAssertFalse(markers.isHidden, "a strip for the section marker")
        XCTAssertEqual(markers.frame.minY, timeline.ruler.frame.maxY, "right under the ruler")
        XCTAssertTrue(todos.isHidden, "no to-dos, no strip")

        // The ruler is all time code: a click on the marker's time moves the playhead.
        editor.click(editor.rulerPoint(at: section.time.seconds))
        XCTAssertEqual(editor.model.playback.time.seconds, section.time.seconds, accuracy: 0.5)
        XCTAssertEqual(editor.project.markers.first?.time, section.time, "the marker didn't move")

        // In its strip, a click goes to it and a drag moves it.
        editor.model.playback.seek(to: t(2))
        editor.click(editor.stripPoint(.markers, at: section.time.seconds + 0.5))
        XCTAssertEqual(editor.model.playback.time, section.time)
        editor.drag(editor.stripPoint(.markers, at: section.time.seconds + 0.5), to: editor.stripPoint(.markers, at: section.time.seconds + 5.5))
        XCTAssertEqual(editor.project.markers.first?.time.seconds ?? 0, section.time.seconds + 5, accuracy: 0.2)
        XCTAssertEqual(editor.model.undoLabel, "Move marker")
        let menu = try editor.menu(at: editor.stripPoint(.markers, at: section.time.seconds + 5.5))
        XCTAssertTrue(menu.contains("Rename marker…") && menu.contains("Delete marker") && menu.contains("Kind"), menu)

        // An agent's to-do gets the to-dos' strip, with its note on hover.
        editor.model.apply(EditBatch(label: "To-do", commands: [.addMarker(marker: Marker(id: "mk_todo", time: t(12), name: "B-roll: the SQLite file (not recorded)", kind: .todo, note: "Open it in TablePlus"))]))
        editor.settle()
        XCTAssertFalse(todos.isHidden)
        XCTAssertEqual(todos.frame.minY, markers.frame.maxY, "under the markers")
        let todo = try XCTUnwrap(editor.project.markers.first { $0.kind == .todo })
        XCTAssertTrue(todos.toolTip(for: todo).contains("Open it in TablePlus"))
        let todoMenu = try editor.menu(at: editor.stripPoint(.todos, at: 12.5))
        XCTAssertTrue(todoMenu.contains("Delete to-do"), todoMenu)
    }

    func testTheRulerStaysFreeForThePlayheadOverAComment() throws {
        let long = "Can you remove the cuts here instead and just show it in real time, so we can see how fast it actually is"
        editor.model.apply(try XCTUnwrap(CommentEdits.add(long, at: t(20), id: "mk_long")))
        editor.settle()
        // Where the comment's words would have run along the ruler.
        editor.click(editor.rulerPoint(at: 24))
        XCTAssertEqual(editor.model.playback.time.seconds, 24, accuracy: 0.5, "the click moved the playhead")
        XCTAssertEqual(editor.project.comments.first?.time, t(20), "and left the comment alone")
        let menu = try editor.menu(at: editor.rulerPoint(at: 20))
        XCTAssertFalse(menu.contains("Change comment"), menu)
    }

    func testACommentInTheStripGoesThereMovesChangesAndDeletes() throws {
        editor.model.apply(try XCTUnwrap(CommentEdits.add("B-roll here", at: t(25), id: "mk_note")))
        editor.settle()
        editor.model.playback.seek(to: t(5))

        // A click goes to it.
        editor.click(editor.commentsPoint(at: 25.5))
        XCTAssertEqual(editor.model.playback.time, t(25))

        // A drag moves it.
        editor.drag(editor.commentsPoint(at: 25.5), to: editor.commentsPoint(at: 32.5))
        let moved = try XCTUnwrap(editor.project.comments.first)
        XCTAssertEqual(moved.time.seconds, 32, accuracy: 0.2)
        XCTAssertEqual(editor.model.undoLabel, "Move comment")

        // A double-click changes it.
        editor.click(editor.commentsPoint(at: moved.time.seconds + 0.5), count: 2)
        let box = try XCTUnwrap(timeline.commentBox, "a double-click opens it")
        XCTAssertEqual(box.request.comment?.id, "mk_note")
        XCTAssertEqual(box.field.stringValue, "B-roll here")
        box.field.stringValue = "The servers B-roll here"
        box.save()
        XCTAssertEqual(editor.project.comments.map(\.name), ["The servers B-roll here"], "changed, not added")

        let menu = try editor.menu(at: editor.commentsPoint(at: moved.time.seconds + 0.5))
        XCTAssertTrue(menu.contains("Change comment…") && menu.contains("Delete comment") && menu.contains("Add comment here…"), menu)

        // Between comments, a click moves the playhead and a double-click adds one.
        editor.click(editor.commentsPoint(at: 10))
        XCTAssertEqual(editor.model.playback.time.seconds, 10, accuracy: 0.2)
        editor.click(editor.commentsPoint(at: 12), count: 2)
        let added = try XCTUnwrap(timeline.commentBox)
        XCTAssertNil(added.request.comment)
        XCTAssertEqual(added.request.time.seconds, 12, accuracy: 0.2)
        added.cancel()
    }

    func testPlayingThroughAnAgentChangeReviewsIt() throws {
        editor.model.apply(EditBatch(label: "B-roll over the demo", author: "claude", commands: [.placeMedia(mediaIDs: [editor.clip("B-roll").mediaID!], at: t(40), duration: t(3))]))
        editor.settle()
        XCTAssertEqual(editor.model.reviewLog.entries.map(\.label), ["B-roll over the demo"])
        editor.model.noteWatched(from: t(30), to: t(41))
        XCTAssertFalse(editor.model.reviewLog.isEmpty, "not watched to the end yet")
        editor.model.noteWatched(from: t(41), to: t(44))
        editor.settle()
        XCTAssertTrue(editor.model.reviewLog.isEmpty, "watched it all: reviewed")
        XCTAssertTrue(editor.model.review.isEmpty, "and the violet's gone")
    }

    func testTheSidebarFollowsWhatsNearThePlayhead() throws {
        editor.model.apply(try XCTUnwrap(CommentEdits.add("Cut the umm", at: t(12), id: "mk_umm")))
        editor.model.apply(EditBatch(label: "To-do", commands: [.addMarker(marker: Marker(id: "mk_todo", time: t(16), name: "B-roll: the SQLite file", kind: .todo, note: "Open it in TablePlus"))]))
        editor.model.selection = []
        editor.model.playback.seek(to: t(5))
        editor.settle()
        XCTAssertEqual(editor.model.nearPlayhead.items.map(\.id).filter { ["mk_umm", "mk_todo"].contains($0) }, ["mk_umm", "mk_todo"], "coming up")
        XCTAssertFalse(editor.model.nearPlayhead.items.contains(where: \.isHere))
        editor.model.playback.seek(to: t(12.5))
        editor.settle()
        XCTAssertEqual(editor.model.nearPlayhead.items.first(where: \.isHere)?.id, "mk_umm", "the playhead's on the comment")
        // A row takes the playhead there.
        let todo = try XCTUnwrap(editor.model.nearPlayhead.items.first { $0.id == "mk_todo" })
        editor.model.goTo(todo.marker)
        XCTAssertEqual(editor.model.playback.time, t(16))
    }

    func testADoubleClickOnAnEmptyStretchOpensACommentThere() throws {
        XCTAssertTrue(editor.clips("Graphics").isEmpty, "the fixture's Graphics track is empty")
        editor.click(editor.point(onTrack: "Graphics", at: 14), count: 2)
        let box = try XCTUnwrap(timeline.commentBox, "a double-click on an empty stretch opens the box")
        XCTAssertEqual(box.request.time.seconds, 14, accuracy: 0.05)
        XCTAssertEqual(editor.model.playback.time.seconds, 14, accuracy: 0.05, "the playhead goes there too")
        XCTAssertEqual(box.popover?.isShown, true)
        box.field.stringValue = "Something on screen here"
        box.save()
        XCTAssertEqual(editor.project.comments.map(\.name), ["Something on screen here"])
        editor.settle()

        // On the ruler, away from the markers, the same.
        editor.click(editor.rulerPoint(at: 40), count: 2)
        let second = try XCTUnwrap(timeline.commentBox)
        XCTAssertFalse(second === box)
        XCTAssertEqual(second.request.time.seconds, 40, accuracy: 0.5, "rulerPoint aims a little right of the time")
        XCTAssertNil(second.request.comment)
        second.cancel()

        // A double-click on a clip still picks it, with no box.
        editor.click(editor.point(of: editor.clip("Camera").id, at: 30), count: 2)
        XCTAssertTrue(timeline.commentBox === second, "no new box")
        XCTAssertTrue(editor.model.selection.contains(editor.clip("Camera").id))
    }

    // MARK: - Transitions

    func testATransitionDroppedOnACutGoesBetweenTheTwoClips() throws {
        let camera = editor.clip("Camera").id
        editor.model.apply(EditBatch(label: "Cut", commands: [.blade(at: t(40), clipIDs: [camera])]))
        editor.settle()
        let left = editor.clip("Camera", 0)
        let right = editor.clip("Camera", 1)
        var at = editor.point(of: left.id)
        at.x = editor.x(at: 40)
        editor.drop("tandem-transition:push", at: at)
        let transitions = try XCTUnwrap(editor.project.track(named: "Camera")).transitions
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions.first?.type, .push)
        XCTAssertEqual(transitions.first?.fromClipID, left.id)
        XCTAssertEqual(transitions.first?.toClipID, right.id)
    }

    // MARK: - The inspector

    func testSelectingASoundEffectTurnsTheInspectorToAudio() {
        let whoosh = MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1.2), hasAudio: true)
        editor.model.apply(EditBatch(label: "Whoosh", commands: [.addMedia(item: whoosh), .placeMedia(mediaIDs: ["med_whoosh"], at: t(12))]))
        editor.settle()
        editor.model.inspectorTab = .video
        let sfx = editor.clip("SFX")
        editor.click(editor.point(of: sfx.id))
        XCTAssertEqual(editor.model.selection, [sfx.id])
        XCTAssertEqual(editor.model.inspectorTab, .audio)
        // A picture turns it back.
        editor.click(editor.point(of: editor.clip("B-roll").id))
        XCTAssertEqual(editor.model.inspectorTab, .video)
    }

    // MARK: - Reviewing an agent's edits

    func testAnAgentsEditsWaitForReviewAndTheKeysStepThroughThem() throws {
        try editor.model.session.coordinator.apply(EditBatch(label: "B-roll over the outro", author: "claude", commands: [
            .placeMedia(mediaIDs: ["med_broll"], at: t(45), sourceStart: t(2), duration: t(4))
        ]))
        editor.settle()
        XCTAssertEqual(editor.model.review.editCount, 1, "waiting for Mike")
        editor.model.playback.seek(to: t(5))
        editor.press("]")
        XCTAssertEqual(editor.model.playback.time.seconds, 45, accuracy: 0.5, "the playhead goes to the change")
        editor.press("option+]")
        XCTAssertTrue(editor.model.review.isEmpty, "marked reviewed")
    }

    func testMikesOwnEditsArentFlaggedForReview() {
        let broll = editor.clip("B-roll")
        let from = editor.point(of: broll.id)
        editor.drag(from, to: CGPoint(x: from.x + 40, y: from.y))
        XCTAssertTrue(editor.model.review.isEmpty)
    }

    // MARK: - Keys on the buttons

    func testHoldingCommandShowsTheButtonsKeys() {
        ShortcutHints.shared.simulatePress(.command, for: 0.8)
        editor.settle(0.3)
        let badges = editor.controller.hintBoard.badges.values
        let symbols = Set(badges.map(\.symbol))
        for expected in ["C", "V", "S", "Space", "⌘E"] {
            XCTAssertTrue(symbols.contains(expected), "\(expected) in \(symbols.sorted())")
        }
        let bounds = editor.window.contentView?.bounds ?? .zero
        for badge in badges {
            XCTAssertTrue(bounds.contains(CGPoint(x: badge.frame.midX, y: badge.frame.midY)), "\(badge.symbol) at \(badge.frame)")
        }
        editor.settle(0.8)
        XCTAssertFalse(ShortcutHints.shared.showing, "gone when ⌘ is let go")
    }

    // MARK: - Holding edge frames

    func testATrimStopsAtTheEndOfTheFileUnlessTheClipHoldsItsEdges() {
        // The B-roll plays its file from 1 s, so the file runs out at 29 s.
        let broll = editor.clip("B-roll")
        let edge = editor.point(of: broll.id, at: 24.95)
        editor.drag(edge, to: CGPoint(x: editor.x(at: 32), y: edge.y))
        XCTAssertEqual(editor.clip("B-roll").end.seconds, 29, accuracy: 0.1, "stopped where the file ends")
        editor.press("cmd+z")
        XCTAssertEqual(editor.clip("B-roll").end.seconds, 25, accuracy: 0.001)

        editor.model.apply(InspectorEdits.holdEdges(editor.clip("B-roll"), true, in: editor.project))
        editor.settle()
        let held = editor.point(of: broll.id, at: 24.95)
        editor.drag(held, to: CGPoint(x: editor.x(at: 32), y: held.y))
        XCTAssertEqual(editor.clip("B-roll").end.seconds, 32, accuracy: 0.1, "held past the end")
        XCTAssertNotNil(editor.project.heldStretches(of: editor.clip("B-roll")).tail)
    }
}
