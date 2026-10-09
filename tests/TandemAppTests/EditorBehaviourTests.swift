import AppKit
import AVFoundation
import IOKit.pwr_mgt
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore
@testable import TandemRender

/// Things Mike does in the editor, done the way he does them (keys, clicks,
/// drags and drops in a real window) and checked by what they change.
/// Each one is a feature that has worked at some point; these keep it
/// working as the app grows. `EditorHarness` explains the timeline they
/// start from.
@MainActor
final class EditorBehaviourTests: XCTestCase {
    private var editor: EditorHarness!
    private var realSpeedPrompt: (@MainActor (String, String?) -> String?)?

    override func setUp() async throws {
        guard NSScreen.screens.first != nil else { throw XCTSkip("no screen") }
        editor = try EditorHarness()
    }

    override func tearDown() async throws {
        if let realSpeedPrompt { ClipSpeed.ask = realSpeedPrompt }
        realSpeedPrompt = nil
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

    func testTheBladePicksOutThePieceBeforeTheCutSoDeleteTakesIt() {
        editor.press("c")
        let camera = editor.clip("Camera")
        editor.click(editor.point(of: camera.id, at: 10))
        XCTAssertEqual(editor.model.tool, .blade, "still the blade")
        let before = Set(editor.model.project.linkedClipIDs(of: camera.id))
        XCTAssertTrue(before.count > 1, "the camera has its sound with it")
        XCTAssertEqual(editor.model.selection, before, "the piece before the cut, with its sound")
        XCTAssertTrue(before.allSatisfy { editor.model.project.clip($0)?.end == t(10) })
        editor.press("delete")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [10], "the piece before the cut went")
        XCTAssertEqual(editor.model.tool, .blade)

        // Shift cuts every track and picks out every piece before the cut.
        editor.click(editor.point(of: editor.clip("Camera").id, at: 30), modifiers: .shift)
        let ending = Set(editor.model.project.allTracks.flatMap(\.clips).filter { $0.end == t(30) }.map(\.id))
        XCTAssertTrue(ending.count > 2, "\(ending)")
        XCTAssertEqual(editor.model.selection, ending)
    }

    func testBladeAtThePlayheadPicksOutThePiecesBeforeTheCutForDelete() {
        editor.model.playback.seek(to: t(10))
        editor.press("cmd+b")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 10], "cut in place")
        let pieces = Set(editor.model.project.allTracks.flatMap(\.clips).filter { $0.end == t(10) }.map(\.id))
        XCTAssertTrue(pieces.count > 2, "\(pieces)")
        XCTAssertEqual(editor.model.selection, pieces, "every piece before the cut, as the scissors and the blade tool do")
        editor.press("delete")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [10], "Delete took the piece before the cut")
    }

    func testThePlayheadsScissorsCutThereAndDragThePlayhead() throws {
        timeline.cutButton.store = try scissorsStore()
        editor.model.playback.seek(to: t(10))
        editor.settle()
        let button = timeline.cutButton
        XCTAssertFalse(button.isHidden)
        let transcript = try XCTUnwrap(timeline.layoutCache.lanes.first(where: \.isTranscript))
        XCTAssertGreaterThanOrEqual(button.frame.minY, timeline.lanes.frame.minY + transcript.maxY, "under the transcript, not over its words")
        let centre = editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        editor.click(centre)
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 10], "cut at the playhead")
        XCTAssertEqual(editor.clips("Voice").map(\.start.seconds), [0, 10], "every clip under it")
        let pieces = Set(editor.model.project.allTracks.flatMap(\.clips).filter { $0.end == t(10) }.map(\.id))
        XCTAssertTrue(pieces.count > 2, "\(pieces)")
        XCTAssertEqual(editor.model.selection, pieces, "every piece before the cut, ready for Delete, as the blade tool does")

        // A drag moves the playhead and cuts nothing.
        let after = editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        editor.drag(after, to: CGPoint(x: after.x + editor.x(at: 20) - editor.x(at: 10), y: after.y))
        XCTAssertEqual(editor.model.playback.time.seconds, 20, accuracy: 0.3)
        XCTAssertEqual(editor.clips("Camera").count, 2)
        XCTAssertEqual(timeline.cutButton.frame.midX, timeline.lanes.frame.minX + CGFloat(editor.model.timeline.scale.x(editor.model.playback.time)), accuracy: 1.5, "the scissors follow the playhead")
    }

    func testThePlayheadsScissorsCutTheSelectedClipAndPickOutThePieceBefore() throws {
        timeline.cutButton.store = try scissorsStore()
        let camera = editor.clip("Camera")
        editor.click(editor.point(of: camera.id, at: 40))
        let selected = editor.model.selection
        XCTAssertTrue(selected.contains(camera.id) && selected.count > 1, "the camera and its sound")
        editor.model.playback.seek(to: t(30))
        editor.settle()
        let button = timeline.cutButton
        editor.click(editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button))
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 30])
        XCTAssertEqual(editor.clips("Music").count, 1, "only the selected clips are cut")
        XCTAssertEqual(editor.model.selection, selected, "the selected clips' pieces before the cut")
        XCTAssertTrue(selected.allSatisfy { editor.model.project.clip($0)?.end == t(30) })
        editor.press("delete")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [30], "Delete took the piece before the cut")
    }

    func testThePlayheadsScissorsSlideUpAndDownTheLineAndSayWhatTheyDo() throws {
        let store = try scissorsStore()
        let button = timeline.cutButton
        button.store = store
        editor.model.playback.seek(to: t(10))
        editor.settle()
        let centre = editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)

        // Hovering shows arrows either side and says what a click and a drag do.
        editor.hover(centre)
        XCTAssertTrue(button.showsArrows)
        let tip = try XCTUnwrap(button.toolTip)
        XCTAssertTrue(tip.hasPrefix("Click to cut"), tip)
        XCTAssertTrue(tip.hasSuffix("\nDrag to move the playhead"), tip)

        // Down onto the camera: the pill follows the pointer, the playhead
        // stays put and nothing is cut.
        let camera = editor.point(onTrack: "Camera", at: 10)
        editor.drag(centre, to: CGPoint(x: centre.x, y: camera.y))
        let moved = editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        XCTAssertEqual(moved.y, camera.y, accuracy: 1, "the pill came down with the pointer")
        XCTAssertEqual(editor.model.playback.time.seconds, 10, accuracy: 0.05)
        XCTAssertEqual(editor.clips("Camera").count, 1, "a drag never cuts")
        XCTAssertFalse(button.dragging)
        let kept = try XCTUnwrap(PlayheadCutButton.restingY(in: store), "kept for next time")
        XCTAssertEqual(kept, button.frame.minY - timeline.lanes.frame.minY, accuracy: 0.5)

        // The clip under the pill keeps its tooltip to itself, but not beside it.
        timeline.lanes.mouseMoved(with: try mouseMoved(at: moved))
        XCTAssertNil(timeline.lanes.toolTip)
        timeline.lanes.mouseMoved(with: try mouseMoved(at: editor.point(onTrack: "Camera", at: 14)))
        XCTAssertTrue(timeline.lanes.toolTip?.hasPrefix("Camera") == true, timeline.lanes.toolTip ?? "no tooltip")

        // It stays there as the playhead moves on, and a click still cuts.
        editor.model.playback.seek(to: t(20))
        editor.settle()
        let later = editor.windowPoint(CGPoint(x: button.bounds.midX, y: button.bounds.midY), in: button)
        XCTAssertEqual(later.y, camera.y, accuracy: 1)
        editor.click(later)
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 20])
    }

    /// A preferences store of the scissors' own, so they start in their
    /// usual place and leave Mike's alone.
    private func scissorsStore() throws -> UserDefaults {
        let suite = "tandem-tests-scissors"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// The pointer moving over `point` (window points from the top left).
    private func mouseMoved(at point: CGPoint) throws -> NSEvent {
        let height = (editor.window.contentView?.superview ?? editor.window.contentView)?.bounds.height ?? 0
        return try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: point.x, y: height - point.y), modifierFlags: [], timestamp: 0,
                                                windowNumber: editor.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
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

    // MARK: - Freeze frames

    func testOptionFFreezesThePictureAtThePlayheadAndPicksItOutToTrim() {
        editor.model.playback.seek(to: t(10))
        editor.press("option+f")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 10, 15], "cut, held for five seconds, then the rest")
        XCTAssertEqual(editor.clips("Screen").map(\.start.seconds), [0, 10, 15], "the screen under the camera holds too")
        let freezes = [editor.clip("Camera", 1), editor.clip("Screen", 1)]
        XCTAssertTrue(freezes.allSatisfy(\.freezeFrame))
        XCTAssertEqual(freezes.map(\.duration), [t(5), t(5)])
        XCTAssertEqual(freezes.map(\.sourceStart), [t(10), t(10.5)], "each holds its own frame")
        XCTAssertEqual(editor.clips("Voice").map(\.start.seconds), [0, 15], "the sound waits for it")
        XCTAssertEqual(editor.clip("B-roll").start.seconds, 25, "everything later moved too")
        XCTAssertEqual(editor.model.selection, Set(freezes.map(\.id)), "picked out together, ready to trim")
        XCTAssertEqual(editor.model.undoLabel, "Freeze frame")

        // Trimmed straight away: W at 12 ripple trims the freezes together.
        editor.model.playback.seek(to: t(12))
        editor.press("w")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 10, 12], "two seconds of freeze, and the rest closed up")
        XCTAssertEqual(editor.clips("Screen").map(\.start.seconds), [0, 10, 12], "the screen's freeze with it")
        XCTAssertEqual(editor.clips("Voice").map(\.start.seconds), [0, 12])

        editor.press("cmd+z")
        editor.press("cmd+z")
        XCTAssertEqual(editor.clips("Camera").count, 1, "one undo for the freeze")
        XCTAssertEqual(editor.clips("Screen").count, 1)
        XCTAssertEqual(editor.clips("Voice").count, 1)
    }

    func testDraggingAFreezesEdgeMovesTheOthersWithIt() {
        editor.model.playback.seek(to: t(10))
        editor.press("option+f")
        let camera = editor.clip("Camera", 1)
        // The ripple trim tool, on the camera freeze's end, back to 13.
        editor.press("b")
        let edge = editor.point(of: camera.id, at: 14.95)
        editor.drag(edge, to: CGPoint(x: editor.x(at: 13), y: edge.y))
        XCTAssertEqual(editor.clip("Camera", 1).end.seconds, 13, accuracy: 0.1)
        XCTAssertEqual(editor.clip("Screen", 1).end, editor.clip("Camera", 1).end, "the screen's freeze moved with it")
        XCTAssertEqual(editor.clip("Camera", 2).start, editor.clip("Camera", 1).end, "the rest closed up")
        XCTAssertEqual(editor.clip("Screen", 2).start, editor.clip("Camera", 1).end)
        XCTAssertEqual(editor.clips("Voice").last?.start, editor.clip("Camera", 1).end, "and the sound with it")
        editor.press("v")
    }

    func testFreezeFrameSaysSoWhenTheresNoVideoUnderThePlayhead() {
        editor.model.playback.seek(to: editor.project.duration)
        editor.press("option+f")
        XCTAssertEqual(editor.model.status?.text, "No video clip under the playhead to freeze.")
        XCTAssertEqual(editor.model.undoLabel, "Build", "nothing changed")
    }

    func testFreezeFrameOnAClipsMenuFreezesThatClipAtThePlayhead() throws {
        editor.model.playback.seek(to: t(22))
        let broll = editor.clip("B-roll")
        // Right-clicked halfway along, at 22.5: it freezes at the playhead.
        let at = editor.point(of: broll.id)
        let menu = try editor.menu(at: at)
        XCTAssertTrue(menu.components(separatedBy: "\n").contains("Freeze frame"), menu)
        editor.choose("Freeze frame", at: at)
        XCTAssertEqual(editor.clips("B-roll").map(\.start.seconds), [20, 22, 27])
        let freeze = editor.clip("B-roll", 1)
        XCTAssertTrue(freeze.freezeFrame)
        XCTAssertEqual(freeze.sourceStart, t(3), "the frame at the playhead, 2 s in from 1 s into its file")
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 22, 27], "the take under it holds too")
        XCTAssertEqual(editor.clips("Screen").map(\.start.seconds), [0, 22, 27])
        XCTAssertEqual(editor.clips("Voice").map(\.start.seconds), [0, 27], "and its sound waits")
        XCTAssertEqual(editor.model.selection, Set(["B-roll", "Camera", "Screen"].map { editor.clip($0, 1).id }))

        // Off the playhead it's there but off; sound has no picture to freeze.
        let later = try editor.menu(at: editor.point(of: editor.clip("B-roll", 2).id))
        XCTAssertTrue(later.components(separatedBy: "\n").contains("Freeze frame (off)"), later)
        let voice = try editor.menu(at: editor.point(of: editor.clip("Voice").id, at: 5))
        XCTAssertFalse(voice.contains("Freeze frame"), voice)
    }

    // MARK: - Speed

    /// A modal alert can't be clicked here, so the test answers Custom…'s
    /// question itself, the way Mike types into the box. `tearDown` puts
    /// the real box back.
    private func answerSpeedPrompt(with answers: [String?]) -> () -> [(typed: String, problem: String?)] {
        var answers = answers
        var asked: [(typed: String, problem: String?)] = []
        if realSpeedPrompt == nil { realSpeedPrompt = ClipSpeed.ask }
        ClipSpeed.ask = { typed, problem in
            asked.append((typed, problem))
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        return { asked }
    }

    func testCustomSpeedAsksForAPercentageAndSetsIt() throws {
        let broll = editor.clip("B-roll") // 5 s at 20
        let asked = answerSpeedPrompt(with: ["fast", "250%"])
        let at = editor.point(of: broll.id)
        let menu = try editor.menu(at: at)
        XCTAssertTrue(menu.components(separatedBy: "\n").contains("  Custom…"), "in the Speed submenu: \(menu)")
        editor.choose("Custom…", at: at)
        XCTAssertEqual(asked().map(\.typed), ["100", "fast"], "it starts at the clip's speed, then keeps what was typed")
        XCTAssertEqual(asked().map(\.problem), [nil, ClipSpeed.Problem.notANumber.message], "asked again, saying why")
        XCTAssertEqual(editor.clip("B-roll").speed, 2.5)
        XCTAssertEqual(editor.clip("B-roll").duration, t(2), "five seconds of B-roll at 250%")
        XCTAssertEqual(editor.model.undoLabel, "Speed 250%")
        let after = try editor.menu(at: editor.point(of: broll.id))
        XCTAssertTrue(after.components(separatedBy: "\n").contains("  ✓ Custom…"), "not a preset: \(after)")
    }

    func testCustomSpeedSaysWhenItsOutOfRangeAndCancelLeavesTheClip() throws {
        let broll = editor.clip("B-roll")
        let asked = answerSpeedPrompt(with: ["20000%", nil])
        editor.choose("Custom…", at: editor.point(of: broll.id))
        XCTAssertEqual(asked().map(\.problem), [nil, ClipSpeed.Problem.outOfRange.message])
        XCTAssertEqual(editor.clip("B-roll").speed, 1, "cancelled")
        XCTAssertEqual(editor.model.undoLabel, "Build")
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

    func testHoveringAGapOffersAnXThatClosesIt() throws {
        let camera = editor.clip("Camera").id
        editor.model.apply(EditBatch(label: "Cuts", commands: [.blade(at: t(20), clipIDs: [camera]), .blade(at: t(10), clipIDs: [camera])]))
        let middle = editor.clips("Camera")[1].id
        editor.model.apply(EditBatch(label: "Lift", commands: [.removeClips(clipIDs: [middle], ripple: false, includeLinked: true)]))
        editor.settle()
        let lanes = try XCTUnwrap(editor.view(TimelineLanesView.self))

        editor.hover(editor.point(onTrack: "Screen", at: 15))
        let gap = try XCTUnwrap(lanes.gap, "a box over the gap")
        XCTAssertEqual(gap.range, TimeRange(start: t(10), end: t(20)))
        XCTAssertEqual(gap.trackIDs.count, 3, "across camera, screen and voice")
        XCTAssertFalse(lanes.gapView.isHidden)
        XCTAssertEqual(lanes.gapView.boxes.count, 3)
        XCTAssertEqual(lanes.gapView.buttons.count, 3, "an × on each, since any of them closes all three")

        // The voice's × closes it on all three.
        let button = try XCTUnwrap(lanes.gapView.buttons.max { $0.midY < $1.midY })
        editor.click(editor.windowPoint(CGPoint(x: button.midX, y: button.midY), in: lanes))
        XCTAssertEqual(editor.clips("Camera").map(\.start.seconds), [0, 10], "closed: what was after it moved up")
        XCTAssertEqual(editor.clips("Voice").map(\.start.seconds), [0, 10])
        XCTAssertEqual(editor.model.undoLabel, "Close gap")
        XCTAssertNil(lanes.gap, "the box goes with it")

        // Over a clip there's no box.
        editor.hover(editor.point(onTrack: "Screen", at: 5))
        XCTAssertNil(lanes.gap)
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

    // MARK: - Playing

    func testPlayingKeepsTheScreenAwakeAndPausingLetsItSleep() {
        XCTAssertFalse(displaySleepHeld(), "nothing held before playing")
        editor.press("space")
        XCTAssertTrue(editor.model.playback.isPlaying)
        XCTAssertTrue(displaySleepHeld(), "no screen saver or lock screen while it plays")
        editor.press("space")
        XCTAssertFalse(editor.model.playback.isPlaying)
        XCTAssertFalse(displaySleepHeld(), "paused, the Mac can sleep again")
        editor.press("l")
        XCTAssertTrue(displaySleepHeld(), "J K L count as playing too")
        editor.press("k")
        XCTAssertFalse(displaySleepHeld())
    }

    /// Whether this process holds a power assertion keeping the display
    /// awake, as macOS sees it.
    private func displaySleepHeld() -> Bool {
        assertionHeld(kIOPMAssertionTypePreventUserIdleDisplaySleep)
    }

    /// Whether this process holds one keeping the Mac itself awake (the
    /// display may still sleep).
    private func systemSleepHeld() -> Bool {
        assertionHeld(kIOPMAssertionTypePreventUserIdleSystemSleep)
    }

    private func assertionHeld(_ type: String) -> Bool {
        var assertions: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
              let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        let mine = byProcess[NSNumber(value: getpid())] ?? []
        return mine.contains { ($0[kIOPMAssertionTypeKey] as? String) == type }
    }

    // MARK: - Playing with sound

    /// Swaps the fixture for an editor whose project has real picture and
    /// sound (`SoundTakes`), and waits for its first composition. These
    /// scenarios aren't async: an async test runs as a job on the main
    /// queue, and spinning the run loop from inside one runs nothing else
    /// queued there, the viewer's builds included.
    private func soundEditor(seconds: Double = 30) throws -> EditorHarness {
        editor.close()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-behaviour-\(UUID().uuidString)", isDirectory: true)
        final class Box: @unchecked Sendable { var result: Result<SoundTakes, Error>? }
        let box = Box()
        let written = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await SoundTakes.write(in: folder, seconds: seconds)) } catch { box.result = .failure(error) }
            written.signal()
        }
        written.wait()
        let takes = try XCTUnwrap(box.result).get()
        editor = try EditorHarness(sound: takes)
        editor.wait(for: "the viewer's first composition", timeout: 10) { editor.model.playback.hasComposition }
        return editor
    }

    /// What the viewer's renderer is given, recorded as it goes.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [(frame: Int, samples: [Float])] = []

        func add(_ buffer: CMSampleBuffer) {
            let frame = ViewerMix.frame(of: buffer)
            var samples: [Float] = []
            if let block = CMSampleBufferGetDataBuffer(buffer) {
                let length = CMBlockBufferGetDataLength(block)
                samples = [Float](repeating: 0, count: length / 4)
                samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            }
            lock.withLock { buffers.append((frame, samples)) }
        }

        /// The left channel of `frames` frames queued from `frame`, from
        /// the latest run of buffers that starts there.
        func left(from frame: Int, frames: Int) -> ArraySlice<Float>? {
            let all = lock.withLock { buffers }
            guard let first = all.lastIndex(where: { $0.frame == frame }) else { return nil }
            var left: [Float] = []
            var next = frame
            for buffer in all[first...] where left.count < frames {
                guard buffer.frame == next else { break }
                left += stride(from: 0, to: buffer.samples.count, by: 2).map { buffer.samples[$0] }
                next += buffer.samples.count / 2
            }
            return left.count >= frames ? left[0..<frames] : nil
        }

        /// The left channel of the latest buffer starting after `frame`.
        func latest(after frame: Int) -> [Float]? {
            let all = lock.withLock { buffers }
            return all.last { $0.frame > frame }.map { buffer in stride(from: 0, to: buffer.samples.count, by: 2).map { buffer.samples[$0] } }
        }
    }

    private func listen(_ editor: EditorHarness) -> Heard {
        let heard = Heard()
        editor.model.playback.audio.observeEnqueues(heard.add)
        addTeardownBlock { @MainActor in editor.model.playback.audio.observeEnqueues(nil) }
        return heard
    }

    /// Each take's level in dBFS as placed: its -20 dBFS tone plus the
    /// clip's gain (music and sound effects go in lower than the voice).
    private func levels(_ editor: EditorHarness) -> [String: Double] {
        var levels: [String: Double] = [:]
        for clip in editor.project.audioTracks.flatMap(\.clips) {
            if let id = clip.mediaID { levels[id] = -20 + (clip.audio?.gainDB ?? 0) }
        }
        return levels
    }

    /// Asserts each take's tone is in `samples` (whole cycles of each) at
    /// its level.
    private func assertEveryTrack(_ samples: ArraySlice<Float>, _ levels: [String: Double], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        for (id, hz) in SoundTakes.toneHz {
            let heard = 20 * log10(max(SoundTakes.amplitude(samples, hz: hz), 1e-12))
            XCTAssertEqual(heard, levels[id] ?? 0, accuracy: 0.5, "\(id) (\(Int(hz)) Hz), \(message)", file: file, line: line)
        }
    }

    private func assertInStep(_ playback: PlaybackController, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let times = playback.pictureAndSoundTimes() else { return XCTFail("nothing on screen", file: file, line: line) }
        XCTAssertEqual(times.picture.seconds, times.sound.seconds, accuracy: 0.002, "picture and sound \(message)", file: file, line: line)
    }

    /// After a seek (a click on the ruler) and a pause to look, play starts
    /// as quickly as it did before the gain taps: the playhead and the sound
    /// move within 0.2 s of the key (with the taps the playhead took about
    /// 0.5 s and tracks after the first came in 0.1 s late), together, and
    /// every track's sound is there from the first sample.
    func testPlayStartsQuicklyAfterASeekWithEveryTrackSounding() throws {
        try skipTimingSensitiveTestOnCI()
        let editor = try soundEditor()
        let playback = editor.model.playback
        let heard = listen(editor)
        let levels = levels(editor)
        XCTAssertTrue(playback.audio.muted, "tests make no sound")
        var starts: [TimeInterval] = []
        for at in [4.0, 11.5, 17.25] {
            editor.click(editor.rulerPoint(at: at))
            editor.settle(0.6)
            let from = playback.time
            XCTAssertEqual(from.seconds, at, accuracy: 0.5)
            XCTAssertTrue(playback.audio.isReady(at: from, reverse: false), "the sound from the playhead is queued while it rests")
            let first = try XCTUnwrap(heard.left(from: ViewerAudio.frame(of: from), frames: 480), "queued from the playhead, to the sample")
            assertEveryTrack(first, levels, "in the first 10 ms from \(from.seconds) s")

            let pressed = ProcessInfo.processInfo.systemUptime
            editor.press("space", settling: 0)
            // Moving, not just a time reported as play begins; each from
            // the key.
            editor.wait(for: "the playhead to move") { playback.time > from + Time(seconds: 0.005) }
            let picture = ProcessInfo.processInfo.systemUptime - pressed
            editor.wait(for: "the sound to move") { playback.audio.time > from + Time(seconds: 0.005) }
            let sound = ProcessInfo.processInfo.systemUptime - pressed
            starts.append(max(picture, sound))
            XCTAssertTrue(playback.audio.isPlaying)
            editor.settle(0.3)
            assertInStep(playback, "after starting at \(from.seconds) s")
            editor.press("space")
            XCTAssertFalse(playback.isPlaying)
            XCTAssertFalse(playback.audio.isPlaying)
        }
        XCTAssertLessThan(starts.max() ?? .infinity, 0.2, "seconds from space to the picture and sound moving: \(starts)")
    }

    /// Play, pause, play again, a click on a clip that takes the playhead
    /// to it while playing, and an edit landing while playing: the picture
    /// and the sound stay together through all of it, a pause queues the
    /// sound from where it stopped, and after the edit the sound is the
    /// new mix.
    func testPlayPauseSeekAndAnEditWhilePlayingKeepPictureAndSoundTogether() throws {
        try skipTimingSensitiveTestOnCI()
        let editor = try soundEditor()
        let playback = editor.model.playback
        // Everything cut at 15 s, so a click on a piece after it is a seek.
        let cuts = DrawTiming.samples("new cut on screen").count
        editor.model.apply(EditBatch(label: "Cut", commands: [.blade(at: t(15), clipIDs: editor.project.allTracks.flatMap(\.clips).map(\.id))]))
        editor.wait(for: "the cut on screen", timeout: 5) { DrawTiming.samples("new cut on screen").count > cuts }
        editor.wait(for: "its sound queued", timeout: 5) { playback.audio.readyAt != nil }
        let heard = listen(editor)
        var levels = levels(editor)
        editor.click(editor.rulerPoint(at: 3))
        editor.settle(0.4)
        editor.press("space")
        editor.settle(0.4)
        XCTAssertTrue(playback.isPlaying)
        assertInStep(playback, "playing")

        // Pause: the picture stops and the sound is queued from there.
        editor.press("space", settling: 0)
        let stopped = playback.time
        editor.wait(for: "the sound queued from where it stopped") { playback.audio.isReady(at: stopped, reverse: false) }
        XCTAssertFalse(playback.audio.isPlaying)
        editor.settle(0.3)
        XCTAssertEqual(playback.time, stopped, "the playhead stays put")
        assertEveryTrack(try XCTUnwrap(heard.left(from: ViewerAudio.frame(of: stopped), frames: 480)), levels, "after the pause")

        // Play on: quick, from there, together.
        editor.press("space", settling: 0)
        let resumed = editor.wait(for: "playing on") { playback.time > stopped + Time(seconds: 0.005) }
        XCTAssertLessThan(resumed, 0.2)
        editor.settle(0.3)
        assertInStep(playback, "after playing on")

        // A click on the take's second piece while playing: the playhead
        // goes to its start and plays on from there, together.
        let piece = editor.clip("Camera", 1)
        XCTAssertEqual(piece.start, t(15))
        editor.click(editor.point(of: piece.id, at: 20), count: 1)
        XCTAssertTrue(playback.isPlaying, "still playing")
        editor.settle(0.4)
        XCTAssertEqual(playback.time.seconds, 15.3, accuracy: 0.3, "playing on from the clip's start")
        assertInStep(playback, "after the click")
        assertEveryTrack(try XCTUnwrap(heard.left(from: ViewerAudio.frame(of: t(15)), frames: 480), "the sound from the clip's start"), levels, "from the clip's start")

        // An edit lands while playing: the music playing now, up 20 dB.
        let before = playback.time
        let music = try XCTUnwrap(editor.project.track(named: "Music")?.clips.first { $0.start <= before && before < $0.end })
        editor.model.apply(InspectorEdits.audio([music.id], ["gainDB": .number((music.audio?.gainDB ?? 0) + 20)], label: "Gain"))
        levels["med_tune"]! += 20
        editor.settle(1.2)
        XCTAssertTrue(playback.isPlaying, "still playing after the edit")
        XCTAssertGreaterThan(playback.time, before + Time(seconds: 0.8), "the playhead kept going")
        assertInStep(playback, "after the edit")
        let latest = try XCTUnwrap(heard.latest(after: ViewerAudio.frame(of: before)), "sound queued after the edit")
        assertEveryTrack(latest[0..<480], levels, "the new mix after the edit")
        editor.press("space")
        XCTAssertFalse(playback.isPlaying)
    }

    /// J K L: L doubles the speed with the sound keeping its pitch and
    /// staying with the picture; J plays backwards, the sound reversed, and
    /// stops at the start; K stops. Scrubbing the ruler makes no sound.
    func testShuttleSpeedsAndReverseKeepTheSoundWithThePicture() throws {
        try skipTimingSensitiveTestOnCI()
        let editor = try soundEditor()
        let playback = editor.model.playback
        editor.click(editor.rulerPoint(at: 2))
        editor.settle(0.4)
        var restarts = 0
        for speed in [1.0, 2, 4, 8] {
            editor.press("l")
            XCTAssertEqual(playback.rate, speed)
            editor.settle(0.35)
            XCTAssertTrue(playback.audio.isPlaying, "sound at \(speed)x")
            XCTAssertEqual(CMTimebaseGetRate(playback.audio.synchronizer.timebase), speed, accuracy: 0.001)
            assertInStep(playback, "at \(speed)x")
            // Faster changes speed on the fly; it doesn't stop and start.
            if speed == 1 { restarts = DrawTiming.samples("playback starts").count }
        }
        XCTAssertEqual(DrawTiming.samples("playback starts").count, restarts, "a change of speed started playback again")
        editor.press("k")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(playback.audio.isPlaying)

        let from = playback.time
        editor.press("j")
        XCTAssertEqual(playback.rate, -1)
        editor.settle(0.4)
        XCTAssertLessThan(playback.time, from, "backwards")
        XCTAssertTrue(playback.audio.isPlaying, "with sound")
        assertInStep(playback, "backwards")
        editor.press("j")
        editor.settle(0.35)
        XCTAssertEqual(CMTimebaseGetRate(playback.audio.synchronizer.timebase), 2, accuracy: 0.001)
        assertInStep(playback, "backwards at 2x")
        editor.press("k")

        // Backwards into the start: it stops there.
        editor.click(editor.rulerPoint(at: 0.2))
        editor.settle(0.3)
        editor.press("j")
        editor.wait(for: "it stops at the start", timeout: 3) { !playback.isPlaying }
        XCTAssertEqual(playback.time, .zero)
        XCTAssertFalse(playback.audio.isPlaying)

        // Scrubbing: dragging along the ruler moves the playhead silently,
        // and the sound is queued where it comes to rest.
        editor.drag(editor.rulerPoint(at: 5), to: editor.rulerPoint(at: 9))
        XCTAssertFalse(playback.audio.isPlaying)
        editor.settle(0.4)
        XCTAssertTrue(playback.audio.isReady(at: playback.time, reverse: false))
    }

    // MARK: - Exporting

    func testExportingKeepsTheMacAwakeUntilItsDone() {
        XCTAssertFalse(systemSleepHeld(), "nothing held before exporting")
        // A small timeline of its own, through the window's export queue as
        // the Export button sends it: the harness's media are only names.
        let black = Clip(content: .solid(color: .black), start: .zero, duration: t(3))
        let project = Project(name: "Awake", settings: ProjectSettings(width: 320, height: 180), videoTracks: [Track(kind: .video, name: "V1", clips: [black])])
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 2_000_000, loudnessTarget: nil, truePeakCeiling: nil)
        let exports = editor.model.exports
        exports.enqueue(preset: preset, output: editor.folder.appendingPathComponent("exports/Awake.mp4"), context: RenderContext(project: project, folder: editor.model.folder))
        var heldWhileExporting = false
        let deadline = Date().addingTimeInterval(60)
        while exports.jobs.last?.isFinished == false, Date() < deadline {
            if systemSleepHeld() { heldWhileExporting = true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard case .done = exports.jobs.last?.state else {
            return XCTFail("the export didn't finish: \(String(describing: exports.jobs.last?.state))")
        }
        XCTAssertTrue(heldWhileExporting, "the Mac doesn't idle to sleep while it exports")
        XCTAssertFalse(systemSleepHeld(), "done, it can sleep again")
        XCTAssertFalse(displaySleepHeld(), "the display was free to sleep all along")
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
        // A dropped transition goes on once its sound is ready, and the
        // first drop of a run waits for the asset library to open too,
        // which on a fresh CI runner takes longer than a settle.
        editor.wait(for: "the push on the cut") { editor.project.track(named: "Camera")?.transitions.isEmpty == false }
        let transitions = try XCTUnwrap(editor.project.track(named: "Camera")).transitions
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions.first?.type, .push)
        XCTAssertEqual(transitions.first?.fromClipID, left.id)
        XCTAssertEqual(transitions.first?.toClipID, right.id)
    }

    func testATransitionDroppedAtAnOverlaysEndGoesOnItAlone() throws {
        let broll = editor.clip("B-roll")
        editor.drop("tandem-transition:push", at: editor.point(of: broll.id, at: broll.end.seconds - 0.2))
        // As on a cut: it goes on once its sound is ready.
        editor.wait(for: "the push at the B-roll's end") { editor.project.track(named: "B-roll")?.transitions.isEmpty == false }
        let transition = try XCTUnwrap(editor.project.track(named: "B-roll")?.transitions.first)
        XCTAssertEqual(transition.type, .push)
        XCTAssertEqual(transition.fromClipID, broll.id)
        XCTAssertNil(transition.toClipID, "it leaves over what's below")
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

    func testClickingTheReviewCountGoesRoundTheChangesToReview() throws {
        for (label, at) in [("A", 8.0), ("B", 40.0)] {
            try editor.model.session.coordinator.apply(EditBatch(label: label, author: "claude", commands: [
                .placeMedia(mediaIDs: ["med_broll"], at: t(at), duration: t(1))
            ]))
        }
        // The review log hears agent edits on its own queue.
        for _ in 0..<100 where editor.model.review.stops.count < 2 { editor.settle(0.02) }
        XCTAssertEqual(editor.model.review.stops.map(\.time.seconds), [8, 40])
        editor.model.playback.seek(to: t(20))
        editor.settle()
        let count = try XCTUnwrap(editor.point(ofTip: "Click for the next change to review"))
        editor.click(count)
        XCTAssertEqual(editor.model.playhead.seconds, 40, accuracy: 0.001, "the start of the next change")
        editor.click(count)
        XCTAssertEqual(editor.model.playhead.seconds, 8, accuracy: 0.001, "after the last, back to the first")
        editor.click(count)
        XCTAssertEqual(editor.model.playhead.seconds, 40, accuracy: 0.001)
    }

    // MARK: - Keys on the buttons

    func testHoldingCommandShowsTheButtonsKeys() {
        // ⌘ goes down and comes up here, not on `simulatePress`'s timer.
        // On a slow runner the settle can outlast any hold the timer
        // gives, and the keys were gone before they were checked. The
        // mouse is taken as up, since on a Mac in use the real one may
        // not be.
        let hints = ShortcutHints.shared
        let (wasActive, wasMouseDown) = (hints.isAppActive, hints.isMouseDown)
        hints.isAppActive = { true }
        hints.isMouseDown = { false }
        defer {
            hints.reset()
            hints.isAppActive = wasActive
            hints.isMouseDown = wasMouseDown
        }
        hints.reset()
        hints.handle(ShortcutHints.flagsChanged(.command))
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
        hints.handle(ShortcutHints.flagsChanged([]))
        editor.settle()
        XCTAssertFalse(hints.showing, "gone when ⌘ is let go")
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
