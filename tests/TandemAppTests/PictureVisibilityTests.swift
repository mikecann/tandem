import Observation
import XCTest
@testable import TandemAPI
@testable import TandemApp
@testable import TandemCore

/// The James interview's mistake: the close-up angle turned off above the
/// wide, linked to it, and the inspector on the close-up. Here the camera is
/// the angle on top and the screen is the one under it.
@MainActor
final class PictureVisibilityTests: XCTestCase {
    private var folder: URL!
    private var model: EditorModel!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try ProjectSession.create(at: folder.appendingPathComponent("Angles.tandem"), name: "Angles", owner: .app)
        model = EditorModel(session: session)
        func item(_ id: String, role: MediaRole, take: String? = "take1", alpha: Bool = false) -> MediaItem {
            MediaItem(
                id: id, path: "source/\(id).mov", kind: .video, role: role,
                takeID: take, takeOffset: .zero, duration: t(60), frameRate: .fps30,
                width: 1920, height: 1080, hasVideo: true, hasAudio: false, hasAlpha: alpha
            )
        }
        model.apply(EditBatch(label: "Build", commands: [
            .addMedia(item: item("med_camera", role: .camera)),
            .addMedia(item: item("med_screen", role: .screen)),
            .addMedia(item: item("med_broll", role: .other, take: nil)),
            .addMedia(item: item("med_sticker", role: .other, take: nil, alpha: true)),
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(60))
        ]))
        // Both angles fill the frame, as the wide and the close-up do.
        for name in ["Camera", "Screen"] {
            model.apply(EditBatch(label: "Fill", commands: [.updateClip(clipID: clip(name).id, patch: .object(["video": .object(["transform": .object(["scale": .number(1), "position": .object(["x": .number(0.5), "y": .number(0.5)])])])]))]))
        }
    }

    override func tearDown() async throws {
        model.tearDown()
        _ = model.session.close()
        try? FileManager.default.removeItem(at: folder)
        settleMainThread()
    }

    private func clip(_ track: String) -> Clip { model.project.track(named: track)!.clips[0] }

    private func turnOffCamera() {
        model.apply(EditBatch(label: "Angle off", commands: [.updateClip(clipID: clip("Camera").id, patch: .object(["enabled": .bool(false)]))]))
    }

    private func selectGroup(focus: String? = nil) {
        model.selection = Set(model.project.linkedClipIDs(of: clip("Camera").id))
        model.focusedClipID = focus
    }

    // MARK: - Which clip the inspector lands on

    func testTheInspectorPrefersTheAngleThatsOn() {
        turnOffCamera()
        selectGroup()
        XCTAssertEqual(model.primaryClipID, clip("Screen").id)
    }

    func testClickingATurnedOffAngleOfAGroupStillShowsTheOneThatsOn() {
        turnOffCamera()
        selectGroup(focus: clip("Camera").id)
        XCTAssertEqual(model.primaryClipID, clip("Screen").id)
    }

    func testAnUnrelatedClipSelectedAlongsideIsntAnAngle() throws {
        turnOffCamera()
        model.apply(EditBatch(label: "B-roll", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(20), duration: t(5))]))
        let broll = try XCTUnwrap(model.project.track(named: "B-roll")?.clips.first)
        model.selection = [clip("Camera").id, broll.id]
        model.focusedClipID = clip("Camera").id
        XCTAssertEqual(model.primaryClipID, clip("Camera").id)
    }

    func testTheNoticeDoesntNameALinkedAngleThatsCovered() throws {
        // The turned-off angle's partner is under full-frame B-roll: what you
        // can see, and what you'd edit, is the B-roll.
        turnOffCamera()
        model.apply(EditBatch(label: "B-roll", commands: [.placeMedia(mediaIDs: ["med_broll"], at: t(20), duration: t(5))]))
        let broll = try XCTUnwrap(model.project.track(named: "B-roll")?.clips.first)
        model.apply(EditBatch(label: "Fill", commands: [.updateClip(clipID: broll.id, patch: .object(["video": .object(["transform": .object(["scale": .number(1), "position": .object(["x": .number(0.5), "y": .number(0.5)])])])]))]))
        let notice = try XCTUnwrap(PictureVisibility.notice(for: clip("Camera"), editingLook: false, playhead: t(21), in: model.project))
        XCTAssertEqual(notice.instead, broll.id)
    }

    func testATurnedOffClipSelectedAloneStaysSelected() {
        // Option-click: how to get at a turned-off clip on purpose.
        turnOffCamera()
        model.selection = [clip("Camera").id]
        model.focusedClipID = clip("Camera").id
        XCTAssertEqual(model.primaryClipID, clip("Camera").id)
    }

    func testAClipThatsOnStaysInFocusEvenWhenCovered() {
        selectGroup(focus: clip("Screen").id)
        XCTAssertEqual(model.primaryClipID, clip("Screen").id, "the screen under the camera was clicked on purpose")
    }

    func testAHiddenTrackCountsAsOff() throws {
        let camera = try XCTUnwrap(model.project.track(named: "Camera"))
        model.apply(EditBatch(label: "Hide", commands: [.updateTrack(trackID: camera.id, patch: .object(["hidden": .bool(true)]))]))
        selectGroup(focus: clip("Camera").id)
        XCTAssertEqual(model.primaryClipID, clip("Screen").id)
    }

    func testPickingAHiddenAngleFromTheMenuHoldsUntilTheNextClick() {
        turnOffCamera()
        selectGroup(focus: clip("Screen").id)
        model.chosenPictureID = clip("Camera").id
        XCTAssertEqual(model.primaryClipID, clip("Camera").id, "asked for by name, so it wins even turned off")
        XCTAssertEqual(PictureVisibility.pictures(in: model.selection, of: model.project).map(\.id), [clip("Camera").id, clip("Screen").id], "top track first, no sound")
        XCTAssertFalse(PictureVisibility.isShowing(clip("Camera"), playhead: t(1), in: model.project))
        XCTAssertTrue(PictureVisibility.isShowing(clip("Screen"), playhead: t(1), in: model.project))
        model.focusedClipID = clip("Screen").id
        XCTAssertEqual(model.primaryClipID, clip("Screen").id, "the same clip clicked again still clears it")
        XCTAssertNil(model.chosenPictureID)
    }

    func testAChosenPictureGoesWithTheSelection() {
        selectGroup()
        model.chosenPictureID = clip("Screen").id
        model.selection = [clip("Camera").id]
        XCTAssertNil(model.chosenPictureID)
    }

    func testTheTimelineMarksTheInspectedClipAndRedrawsWhenItMoves() {
        selectGroup(focus: clip("Camera").id)
        let before = TimelineDrawState(model: model)
        XCTAssertEqual(before.inspectedClipID, clip("Camera").id)
        model.focusedClipID = clip("Screen").id
        let after = TimelineDrawState(model: model)
        XCTAssertEqual(after.inspectedClipID, clip("Screen").id)
        let layout = TimelineLayout.make(project: model.project, showTranscript: false, heightOverrides: model.timeline.trackHeights)
        XCTAssertEqual(TimelineDamage.selectionRects(from: before, to: after, layout: layout).count, 2, "only the two clips that swapped")
        model.selection = [clip("Screen").id]
        XCTAssertNil(TimelineDrawState(model: model).inspectedClipID, "one clip selected has nothing to pick out")
    }

    func testTheTimelinesDrawStateDoesntFollowThePlayhead() {
        // No clip clicked, the one case where the inspector goes by the
        // playhead. The draw state redraws the timeline whenever what it read
        // changes, so reading the playhead would mean 60 times a second.
        selectGroup()
        var changed = false
        withObservationTracking {
            _ = TimelineDrawState(model: model)
        } onChange: {
            changed = true
        }
        model.playback.seek(to: t(9))
        XCTAssertEqual(model.playback.timeUnobserved, model.playback.time)
        XCTAssertEqual(model.playback.time, t(9), "the seek has to move the playhead for this to prove anything")
        XCTAssertFalse(changed)
    }

    // MARK: - What covers what

    func testOnlyAFullFrameOpaquePictureCovers() {
        let camera = clip("Camera")
        XCTAssertTrue(PictureVisibility.covers(camera, at: t(1), in: model.project))
        var pip = camera
        pip.video?.transform.scale = 0.5
        XCTAssertFalse(PictureVisibility.covers(pip, at: t(1), in: model.project), "a picture in picture")
        var faded = camera
        faded.video?.opacity = 0.5
        XCTAssertFalse(PictureVisibility.covers(faded, at: t(1), in: model.project))
        var cropped = camera
        cropped.video?.crop.left = 0.2
        XCTAssertFalse(PictureVisibility.covers(cropped, at: t(1), in: model.project))
        var rounded = camera
        rounded.video?.effects = [Effect(id: "fx_r", type: "roundedCorners")]
        XCTAssertFalse(PictureVisibility.covers(rounded, at: t(1), in: model.project))
        var graded = camera
        graded.video?.effects = [Effect(id: "fx_c", type: "colorAdjust")]
        XCTAssertTrue(PictureVisibility.covers(graded, at: t(1), in: model.project), "a grade leaves no holes")
        var sticker = camera
        sticker.content = .media(mediaID: "med_sticker")
        XCTAssertFalse(PictureVisibility.covers(sticker, at: t(1), in: model.project), "alpha can show through")
    }

    // MARK: - What the Colour tab says

    func testNoNoticeForTheClipOnScreen() {
        XCTAssertNil(PictureVisibility.notice(for: clip("Camera"), editingLook: false, playhead: t(1), in: model.project))
    }

    func testATurnedOffClipNamesWhatsOnScreen() throws {
        turnOffCamera()
        let notice = try XCTUnwrap(PictureVisibility.notice(for: clip("Camera"), editingLook: true, playhead: t(1), in: model.project))
        XCTAssertEqual(notice.instead, clip("Screen").id)
        XCTAssertTrue(notice.text.contains("it's turned off"), notice.text)
        XCTAssertTrue(notice.text.contains("You're seeing"), notice.text)
    }

    func testACoveredClipSaysWhatsOnTop() throws {
        let notice = try XCTUnwrap(PictureVisibility.notice(for: clip("Screen"), editingLook: false, playhead: t(1), in: model.project))
        XCTAssertEqual(notice.instead, clip("Camera").id)
        XCTAssertTrue(notice.text.contains("is on top of it"), notice.text)
    }

    func testAWholeTakeEditIsFineWhenTheSameFileIsOnScreen() {
        // Two clips of one file, the top one hiding the other. The look
        // reaches both, so there's nothing to warn about; a clip's own grade
        // wouldn't show.
        let top = clip("Camera")
        model.apply(EditBatch(label: "Same file", commands: [.updateClip(clipID: clip("Screen").id, patch: .object(["content": .object(["media": .object(["mediaID": .string("med_camera")])])]))]))
        XCTAssertEqual(clip("Screen").mediaID, top.mediaID)
        XCTAssertNil(PictureVisibility.notice(for: clip("Screen"), editingLook: true, playhead: t(1), in: model.project))
        XCTAssertNotNil(PictureVisibility.notice(for: clip("Screen"), editingLook: false, playhead: t(1), in: model.project))
    }

    func testAClipAwayFromThePlayheadIsJudgedAtItsOwnStart() throws {
        let screen = clip("Screen")
        let notice = try XCTUnwrap(PictureVisibility.notice(for: screen, editingLook: false, playhead: t(120), in: model.project))
        XCTAssertEqual(notice.time, screen.start)
    }

    func testEditThatInsteadMovesTheInspector() throws {
        turnOffCamera()
        model.selection = [clip("Camera").id]
        model.focusedClipID = clip("Camera").id
        let notice = try XCTUnwrap(PictureVisibility.notice(for: clip("Camera"), editingLook: true, playhead: t(1), in: model.project))
        model.editInstead(try XCTUnwrap(notice.instead), at: notice.time)
        XCTAssertEqual(model.primaryClipID, clip("Screen").id)
        XCTAssertTrue(model.selection.contains(clip("Screen").id))
    }
}
