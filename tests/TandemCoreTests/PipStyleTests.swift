import XCTest
@testable import TandemCore

/// `tandem check`'s note on a picture-in-picture that isn't Mike's usual
/// cutout in the corner. The clips are the Convex Auth v2 video's (12 Nov
/// 2026), where the agent framed his face in a cropped box with the cutout
/// off while the matte wasn't made: "This is not our usual way".
final class PipStyleTests: XCTestCase {
    private let camera = MediaItem(
        id: "med_camera", path: "source/2026-11-12_111045-camera.mov", kind: .video, role: .camera,
        duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true
    )
    private let screen = MediaItem(
        id: "med_screen", path: "source/2026-11-12_111045-screen.mov", kind: .video, role: .screen,
        duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true
    )

    private func layout(_ preset: LayoutPreset) -> VideoProperties {
        preset.apply(to: nil, role: .camera, shadowID: "fx_shadow")
    }

    /// The face box the agent made: pipRight's place, cropped to his face,
    /// cutout off.
    private var faceBox: VideoProperties {
        var video = layout(.pipRight)
        video.crop = Crop(left: 0.2, top: 0.02, right: 0.22, bottom: 0.14)
        video.cutout?.enabled = false
        return video
    }

    private func project(_ cameraClips: [Clip], portrait: Bool = false) -> Project {
        var project = Project.standard(name: "Convex Auth v2")
        project.settings.width = portrait ? 1080 : 3840
        project.settings.height = portrait ? 1920 : 2160
        project.media = [camera, screen]
        project.videoTracks = [
            Track(id: "trk_screen", kind: .video, name: "Screen", clips: [
                Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(60), sourceStart: .zero)
            ], rippleMode: .cut),
            Track(id: "trk_camera", kind: .video, name: "Camera", clips: cameraClips, rippleMode: .cut)
        ]
        return project
    }

    private func cam(_ id: String, _ start: Double, _ end: Double, _ video: VideoProperties?) -> Clip {
        Clip(id: id, content: .media(mediaID: "med_camera"), start: t(start), duration: t(end - start), sourceStart: t(start), video: video)
    }

    private func notes(_ project: Project, ranges: [TimeRange] = [TimeRange(start: .zero, end: t(60))]) -> [CheckProblem] {
        QualityCheck.offStylePip(in: project, ranges: ranges)
    }

    func testMikesUsualPipAndFullFrameArentNoted() {
        XCTAssertEqual(notes(project([
            cam("clip_full", 0, 10, nil), cam("clip_right", 10, 20, layout(.pipRight)), cam("clip_left", 20, 30, layout(.pipLeft)),
            cam("clip_split", 30, 40, layout(.split))
        ])), [])
    }

    func testTheFramedFaceBoxIsNotedWithTheApplyLayoutFix() {
        let found = notes(project([
            cam("clip_right", 0, 10, layout(.pipRight)), cam("clip_box1", 10, 15, faceBox), cam("clip_box2", 15, 22, faceBox),
            cam("clip_right2", 22, 30, layout(.pipRight)), cam("clip_box3", 40, 45, faceBox)
        ]))
        XCTAssertEqual(found.map(\.kind), [.offStylePip, .offStylePip])
        XCTAssertTrue(CheckProblem.Kind.offStylePip.isNote)
        XCTAssertEqual(found[0].clipIDs, ["clip_box1", "clip_box2"], "one note for the run of them")
        XCTAssertEqual(found[0].start, t(10))
        XCTAssertEqual(found[0].end, t(22))
        let message = found[0].message
        XCTAssertTrue(message.contains("2 camera clips"), message)
        XCTAssertTrue(message.contains("cutout off; cropped") || message.contains("cutout off, cropped"), message)
        XCTAssertTrue(message.contains(#"{"applyLayout": {"clipIDs": ["clip_box1", "clip_box2"], "preset": "pipRight"}}"#), message)
        XCTAssertEqual(found[1].clipIDs, ["clip_box3"])
    }

    func testTheFixPutsItBack() throws {
        let edited = project([cam("clip_box", 10, 15, faceBox)])
        XCTAssertEqual(notes(edited).count, 1)
        let coordinator = ProjectCoordinator(project: edited)
        try coordinator.apply(EditBatch(label: "PiP", commands: [.applyLayout(clipIDs: ["clip_box"], preset: .pipRight)]))
        XCTAssertEqual(notes(coordinator.project), [])
    }

    func testCutoutOffOrASizeOfItsOwnIsNoted() {
        var noCutout = layout(.pipLeft)
        noCutout.cutout?.enabled = false
        var big = layout(.pipRight)
        big.transform.scale = 0.7
        big.transform.position = Point(x: 0.8, y: 0.7)
        let found = notes(project([cam("clip_plain", 0, 10, noCutout), cam("clip_full", 10, 12, nil), cam("clip_big", 12, 20, big)]))
        XCTAssertEqual(found.map(\.clipIDs), [["clip_plain"], ["clip_big"]])
        XCTAssertTrue(found[0].message.contains("\"preset\": \"pipLeft\""), "on the left, the fix is pipLeft: \(found[0].message)")
        XCTAssertTrue(found[1].message.contains("70% at (0.80, 0.70)"), found[1].message)
    }

    func testAPipSlidingInIsJudgedWhereItRests() {
        // Threadbear launch, 10:31: pipRight sliding in from off the right.
        var sliding = cam("clip_slide", 0, 4, layout(.pipRight))
        sliding.keyframes["video.transform.position"] = [
            Keyframe(time: t(1.76), value: .point(Point(x: 1.5, y: 0.77)), interpolation: .easeOut),
            Keyframe(time: t(2.21), value: .point(Point(x: 0.87, y: 0.77)), interpolation: .easeInOut)
        ]
        XCTAssertEqual(notes(project([sliding])), [])
        // A short clip that's mostly the slide (Threadbear launch, 10:25).
        var brief = cam("clip_brief", 0, 1.4, layout(.pipRight))
        brief.keyframes["video.transform.position"] = [
            Keyframe(time: .zero, value: .point(Point(x: 1.5, y: 0.77)), interpolation: .easeOut),
            Keyframe(time: t(1.0), value: .point(Point(x: 0.87, y: 0.77)), interpolation: .easeInOut)
        ]
        XCTAssertEqual(notes(project([brief])), [])
        // A check of only the slide still judges where it settles.
        XCTAssertEqual(notes(project([sliding]), ranges: [TimeRange(start: t(1.8), end: t(2.1))]), [])
    }

    func testAPipKeyframedOffSizeIsNotedAndACroppedCutoutIsnt() {
        // From the cross-lab review: keyframes holding it at 70% all along.
        var big = cam("clip_big", 0, 4, layout(.pipRight))
        big.keyframes["video.transform.scale"] = [
            Keyframe(time: .zero, value: .number(0.7)), Keyframe(time: t(4), value: .number(0.7))
        ]
        XCTAssertEqual(notes(project([big])).map(\.clipIDs), [["clip_big"]])
        // In the corner at first, then settling at 70%.
        var settles = cam("clip_settles", 0, 10, layout(.pipRight))
        settles.keyframes["video.transform.scale"] = [
            Keyframe(time: .zero, value: .number(0.5)), Keyframe(time: t(1), value: .number(0.5)),
            Keyframe(time: t(2), value: .number(0.7)), Keyframe(time: t(10), value: .number(0.7))
        ]
        XCTAssertEqual(notes(project([settles])).map(\.clipIDs), [["clip_settles"]])
        // A crop with the cutout on is a repair (an edge of the desk off).
        var trimmed = layout(.pipRight)
        trimmed.crop = Crop(left: 0, top: 0, right: 0.05, bottom: 0)
        XCTAssertEqual(notes(project([cam("clip_trimmed", 0, 4, trimmed)])), [])
    }

    func testAFaceBoxUnderFullFrameBRollIsntNoted() {
        let shot = MediaItem(id: "med_shot", path: "broll/landing.mp4", kind: .video, role: .broll, duration: t(10), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true)
        var covered = project([cam("clip_box", 10, 15, faceBox)])
        covered.media.append(shot)
        covered.videoTracks.append(Track(id: "trk_broll", kind: .video, name: "B-roll", clips: [
            Clip(id: "clip_shot", content: .media(mediaID: "med_shot"), start: t(9), duration: t(7), sourceStart: .zero)
        ], rippleMode: .follow))
        XCTAssertEqual(notes(covered), [])
        // A see-through solid over it doesn't hide it.
        var tinted = covered
        tinted.videoTracks[2].clips[0] = Clip(id: "clip_tint", content: .solid(color: RGBA(r: 0, g: 0, b: 0, a: 0.2)), start: t(9), duration: t(7))
        XCTAssertEqual(notes(tinted).map(\.clipIDs), [["clip_box"]])
        // Shown for part of it, it's noted.
        covered.videoTracks[2].clips[0].duration = t(3)
        XCTAssertEqual(notes(covered).map(\.clipIDs), [["clip_box"]])
    }

    func testFromTheThirdReview() {
        // A pipLeft that slides in from the right is judged in its corner.
        var fromRight = cam("clip_left", 0, 4, layout(.pipLeft))
        fromRight.keyframes["video.transform.position"] = [
            Keyframe(time: .zero, value: .point(Point(x: 1.1, y: 0.77))), Keyframe(time: t(1), value: .point(Point(x: 0.13, y: 0.77)))
        ]
        XCTAssertEqual(notes(project([fromRight])), [])
        // A size that changes all along, never the preset's, is noted.
        var growing = cam("clip_grow", 0, 4, layout(.pipRight))
        growing.keyframes["video.transform.scale"] = [
            Keyframe(time: .zero, value: .number(0.6), interpolation: .linear), Keyframe(time: t(4), value: .number(0.8), interpolation: .linear)
        ]
        XCTAssertEqual(notes(project([growing])).map(\.clipIDs), [["clip_grow"]])
        // A second angle full frame somewhere doesn't switch the check off.
        let angle = MediaItem(id: "med_angle", path: "source/angle2.mov", kind: .video, role: .camera, duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true)
        var withAngle = project([cam("clip_box", 10, 15, faceBox)])
        withAngle.media.append(angle)
        withAngle.videoTracks.append(Track(id: "trk_angle", kind: .video, name: "Angle 2", clips: [
            Clip(id: "clip_angle", content: .media(mediaID: "med_angle"), start: t(30), duration: t(5), sourceStart: .zero)
        ], rippleMode: .cut))
        XCTAssertEqual(notes(withAngle).map(\.clipIDs), [["clip_box"]])
    }

    func testAConversationsCameraBoxesArentNoted() {
        let guest = MediaItem(id: "med_guest", path: "source/guest-camera.mov", kind: .video, role: .camera, duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true)
        var boxes = project([cam("clip_host", 0, 20, faceBox)])
        boxes.media.append(guest)
        var left = faceBox
        left.transform.position = Point(x: 0.25, y: 0.5)
        boxes.videoTracks.append(Track(id: "trk_guest", kind: .video, name: "Guest", clips: [
            Clip(id: "clip_guest", content: .media(mediaID: "med_guest"), start: .zero, duration: t(20), sourceStart: .zero, video: left)
        ], rippleMode: .cut))
        XCTAssertEqual(notes(boxes), [])
    }

    func testHiddenOutsideTheStretchAndShortsArentNoted() {
        var hidden = faceBox
        hidden.opacity = 0
        XCTAssertEqual(notes(project([cam("clip_hidden", 10, 15, hidden)])), [])
        XCTAssertEqual(notes(project([cam("clip_box", 10, 15, faceBox)]), ranges: [TimeRange(start: t(30), end: t(40))]), [])
        // A Short's face box is the layout Mike passed for portrait (Walkies).
        XCTAssertEqual(notes(project([cam("clip_box", 10, 15, faceBox)], portrait: true)), [])
    }
}
