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

    func testShiftCOpensACommentAtThePlayheadAndReturnKeepsIt() throws {
        editor.model.playback.seek(to: t(12))
        editor.press("shift+c")
        let ruler = try XCTUnwrap(editor.view(TimelineRulerView.self))
        let box = try XCTUnwrap(ruler.commentBox, "the box opens on the ruler")
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
        let ruler = try XCTUnwrap(editor.view(TimelineRulerView.self))
        let kept = try XCTUnwrap(ruler.commentBox)
        kept.field.stringValue = "Louder here"
        kept.popover?.close()
        XCTAssertEqual(editor.project.comments.map(\.name), ["Louder here"], "a stray click doesn't lose it")

        editor.model.playback.seek(to: t(20))
        editor.press("shift+c")
        let dropped = try XCTUnwrap(ruler.commentBox)
        XCTAssertFalse(dropped === kept)
        dropped.field.stringValue = "Never mind"
        _ = dropped.control(dropped.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(editor.project.comments.map(\.name), ["Louder here"], "Escape drops it")
    }

    func testADoubleClickOnAnEmptyStretchOpensACommentThere() throws {
        XCTAssertTrue(editor.clips("Graphics").isEmpty, "the fixture's Graphics track is empty")
        let ruler = try XCTUnwrap(editor.view(TimelineRulerView.self))
        editor.click(editor.point(onTrack: "Graphics", at: 14), count: 2)
        let box = try XCTUnwrap(ruler.commentBox, "a double-click on an empty stretch opens the box")
        XCTAssertEqual(box.request.time.seconds, 14, accuracy: 0.05)
        XCTAssertEqual(editor.model.playback.time.seconds, 14, accuracy: 0.05, "the playhead goes there too")
        XCTAssertEqual(box.popover?.isShown, true)
        box.field.stringValue = "Something on screen here"
        box.save()
        XCTAssertEqual(editor.project.comments.map(\.name), ["Something on screen here"])

        // On the ruler, away from the markers, the same.
        editor.click(editor.rulerPoint(at: 40), count: 2)
        let second = try XCTUnwrap(ruler.commentBox)
        XCTAssertFalse(second === box)
        XCTAssertEqual(second.request.time.seconds, 40, accuracy: 0.5, "rulerPoint aims a little right of the time")
        XCTAssertNil(second.request.comment)
        second.cancel()

        // A double-click on a clip still picks it, with no box.
        editor.click(editor.point(of: editor.clip("Camera").id, at: 30), count: 2)
        XCTAssertTrue(ruler.commentBox === second, "no new box")
        XCTAssertTrue(editor.model.selection.contains(editor.clip("Camera").id))
    }

    func testACommentOnTheRulerCanBeChangedAndDeleted() throws {
        editor.model.apply(try XCTUnwrap(CommentEdits.add("B-roll here", at: t(25), id: "mk_note")))
        editor.settle()
        let point = editor.rulerPoint(at: 25)
        editor.click(point, count: 2)
        let ruler = try XCTUnwrap(editor.view(TimelineRulerView.self))
        let box = try XCTUnwrap(ruler.commentBox, "a double-click opens it")
        XCTAssertEqual(box.request.comment?.id, "mk_note")
        XCTAssertEqual(box.field.stringValue, "B-roll here")
        box.field.stringValue = "The servers B-roll here"
        box.save()
        XCTAssertEqual(editor.project.comments.map(\.name), ["The servers B-roll here"])
        XCTAssertEqual(editor.project.comments.count, 1, "changed, not added")

        let menu = try editor.menu(at: point)
        XCTAssertTrue(menu.contains("Change comment…") && menu.contains("Delete comment"), menu)
        XCTAssertFalse(menu.contains("Rename marker"), menu)
        editor.model.deleteComment(try XCTUnwrap(editor.project.comments.first))
        XCTAssertTrue(editor.project.comments.isEmpty)
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
