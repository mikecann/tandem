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
