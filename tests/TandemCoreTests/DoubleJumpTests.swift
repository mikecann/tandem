import XCTest
@testable import TandemCore

/// `tandem check`'s double jumps: full-frame B-roll a few frames off a cut
/// in the take, and a flash of camera between two shots. On the Batching
/// Component video 11 B-roll edges sat 1 to 17 frames off a camera cut, and
/// Mike saw the first 5 s in: "it cuts and then like a few frames later it
/// shows the b-roll which makes it quite distracting".
final class DoubleJumpTests: XCTestCase {
    // MARK: - Helpers

    private let camera = MediaItem(
        id: "med_camera", path: "source/take1-camera.mov", kind: .video, role: .camera,
        duration: t(600), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true, hasAudio: true
    )
    private let shot = MediaItem(
        id: "med_shot", path: "broll/w01-youtube-2025.mp4", kind: .video, role: .broll,
        duration: t(10), frameRate: .fps30, width: 3840, height: 2160, hasVideo: true
    )
    private let other = MediaItem(
        id: "med_other", path: "broll/s03c-cursors-smooth.mp4", kind: .video, role: .broll,
        duration: t(10), frameRate: .fps30, width: 1920, height: 1080, hasVideo: true
    )

    /// The take on Camera, cut at 10, 20 and 40, with a through-edit at 30
    /// (the file carries straight on there):
    /// 0-10 (file 0), 10-20 (file 12), 20-30 (file 25), 30-40 (file 35),
    /// 40-60 (file 50). B-roll and Graphics above it, 4K at 30 fps.
    private func project(broll: [Clip] = [], graphics: [Clip] = [], media: [MediaItem] = [], cameraTransitions: [Transition] = []) -> Project {
        var project = Project.standard(name: "Double jumps")
        project.settings.width = 3840
        project.settings.height = 2160
        project.settings.frameRate = .fps30
        project.media = [camera, shot, other] + media
        func take(_ id: String, _ start: Double, _ end: Double, file: Double) -> Clip {
            Clip(id: id, content: .media(mediaID: "med_camera"), start: t(start), duration: t(end - start), sourceStart: t(file))
        }
        project.videoTracks = [
            Track(id: "trk_camera", kind: .video, name: "Camera", clips: [
                take("clip_cam1", 0, 10, file: 0), take("clip_cam2", 10, 20, file: 12), take("clip_cam3", 20, 30, file: 25),
                take("clip_cam4", 30, 40, file: 35), take("clip_cam5", 40, 60, file: 50)
            ], transitions: cameraTransitions, rippleMode: .cut),
            Track(id: "trk_broll", kind: .video, name: "B-roll", clips: broll, rippleMode: .follow),
            Track(id: "trk_graphics", kind: .video, name: "Graphics", clips: graphics, rippleMode: .follow)
        ]
        project.audioTracks = []
        return project
    }

    private func broll(_ id: String, _ start: Double, _ end: Double, file: Double = 2, media: String = "med_shot", video: VideoProperties? = nil) -> Clip {
        Clip(id: id, content: .media(mediaID: media), start: t(start), duration: t(end - start), sourceStart: t(file), video: video)
    }

    private var everything: [TimeRange] { [TimeRange(start: .zero, end: t(60))] }

    private func jumps(_ project: Project, in ranges: [TimeRange]? = nil) -> [CheckProblem] {
        QualityCheck.doubleJumps(in: project, ranges: ranges ?? everything)
    }

    /// The project with `problem`'s fix applied, through the coordinator as
    /// an agent's `tandem apply` would.
    private func fixed(_ project: Project, _ problems: [CheckProblem], file: StaticString = #filePath, line: UInt = #line) throws -> Project {
        let commands = QualityCheck.commands(fixing: problems)
        XCTAssertFalse(commands.isEmpty, "a fix to apply", file: file, line: line)
        let coordinator = ProjectCoordinator(project: project)
        try coordinator.apply(EditBatch(label: QualityCheck.fixLabel(for: problems), commands: commands))
        assertValid(coordinator.project, file: file, line: line)
        return coordinator.project
    }

    // MARK: - A shot just off a cut

    func testAShotStartingJustAfterACutIsADoubleJumpWithTheFixThatMovesItBack() throws {
        let p = project(broll: [broll("clip_w01", 10.066, 15)])
        let found = jumps(p)
        XCTAssertEqual(found.map(\.kind), [.doubleJump])
        let problem = try XCTUnwrap(found.first)
        XCTAssertFalse(problem.kind.isNote, "a problem: it fails the check")
        XCTAssertEqual(problem.start, t(10), "from the cut")
        XCTAssertEqual(problem.end, t(10.066), "to the shot")
        XCTAssertEqual(problem.frames, 2)
        XCTAssertEqual(problem.clipIDs, ["clip_w01"])
        XCTAssertEqual(problem.message, "Double jump: w01-youtube-2025.mp4 starts 2 frames after a camera cut, so the new camera shot flashes for 0.07 s before it. Extend it back to the cut.")
        guard case .updateClip(let clipID, let patch)? = problem.fix else { return XCTFail("an updateClip fix, got \(String(describing: problem.fix))") }
        XCTAssertEqual(clipID, "clip_w01")
        guard case .object(let fields) = patch else { return XCTFail("a patch object") }
        XCTAssertNil(fields["holdEdges"], "the file has 2 s before the shot to run back into")

        let after = try fixed(p, found)
        let moved = try XCTUnwrap(after.clip("clip_w01"))
        XCTAssertEqual(moved.start, t(10), "on the cut")
        XCTAssertEqual(moved.end, t(15), "its end stays")
        XCTAssertFalse(moved.holdEdges)
        XCTAssertEqual(moved.sourceTime(atTimelineTime: t(12)), p.clip("clip_w01")?.sourceTime(atTimelineTime: t(12)), "its content stays where it was")
        XCTAssertTrue(jumps(after).isEmpty, "\(jumps(after).map(\.message))")
    }

    func testAShotEndingJustBeforeACutIsADoubleJump() throws {
        let p = project(broll: [broll("clip_w01", 15, 19.95)])
        let found = jumps(p)
        XCTAssertEqual(found.map(\.kind), [.doubleJump])
        let problem = try XCTUnwrap(found.first)
        XCTAssertEqual(problem.start, t(19.95))
        XCTAssertEqual(problem.end, t(20))
        XCTAssertEqual(problem.frames, 1, "the frame at 19.967 shows the camera")
        XCTAssertEqual(problem.message, "Double jump: w01-youtube-2025.mp4 ends 1 frame before a camera cut, so the old camera shot flashes for 0.05 s after it. Run it on to the cut.")

        let after = try fixed(p, found)
        let moved = try XCTUnwrap(after.clip("clip_w01"))
        XCTAssertEqual(moved.start, t(15))
        XCTAssertEqual(moved.end, t(20))
        XCTAssertEqual(moved.sourceStart, t(2), "a later end plays on into the file")
        XCTAssertTrue(jumps(after).isEmpty)
    }

    func testUnderAFrameOffACutIsStillWorthSnapping() throws {
        let found = jumps(project(broll: [broll("clip_w01", 15, 19.97)]))
        XCTAssertEqual(found.map(\.kind), [.doubleJump], "no frame lands in it at 30 fps, but snapping is free")
        XCTAssertEqual(found.first?.frames, 0)
        XCTAssertTrue(found.first?.message.contains("ends 0.030 s before a camera cut, under a frame at 30 fps") == true, found.first?.message ?? "")
        XCTAssertNotNil(found.first?.fix)
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 15, 19.9995)])).isEmpty, "half a millisecond is the same moment")
    }

    func testAnEdgeOnTheCutOrFurtherThanThreeQuartersOfASecondOffIsFine() {
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 10, 15)])).isEmpty, "exactly on the cut")
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 10.8, 15)])).isEmpty, "0.8 s after it: a beat of the new shot, not a flash")
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 15, 19.2)])).isEmpty, "0.8 s before one")
        XCTAssertEqual(jumps(project(broll: [broll("clip_w01", 10.7, 15)])).count, 1, "0.7 s is within reach")
    }

    func testAThroughEditIsntACut() {
        // The file carries straight on at 30: nothing changes on screen.
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 30.066, 35)])).isEmpty)
        // Nor does a frame held over a flicker (`holdFrame`): left, held,
        // right are one shot on screen.
        var held = project(broll: [broll("clip_w01", 25.05, 28)])
        held.videoTracks[0].clips[2] = Clip(id: "clip_cam3", content: .media(mediaID: "med_camera"), start: t(20), duration: t(5), sourceStart: t(25))
        held.videoTracks[0].clips.insert(Clip(id: "clip_held", content: .media(mediaID: "med_camera"), start: t(25), duration: t(0.1), sourceStart: t(29.9667), freezeFrame: true), at: 3)
        held.videoTracks[0].clips.insert(Clip(id: "clip_cam3b", content: .media(mediaID: "med_camera"), start: t(25.1), duration: t(4.9), sourceStart: t(30.1)), at: 4)
        XCTAssertTrue(jumps(held).isEmpty, "\(jumps(held).map(\.message))")
    }

    func testAnEdgeUnderASectionCardIsLeftAlone() {
        // The card's wipes are made to sit across cuts.
        let card = Clip(id: "clip_card", content: SectionCard.content(SectionCard.Props(title: "Batching")), start: t(7), duration: t(3.2))
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 10.066, 15)], graphics: [card])).isEmpty)
        let cardStartingNearACut = Clip(id: "clip_card", content: SectionCard.content(SectionCard.Props(title: "Batching")), start: t(10.1), duration: t(3.2))
        XCTAssertTrue(jumps(project(graphics: [cardStartingNearACut])).isEmpty, "a card's own edges aren't checked")
    }

    func testPicturesThatDontCoverTheFrameDontCount() {
        let phone = MediaItem(id: "med_phone", path: "broll/phone-tap-sensor.mov", kind: .video, role: .broll, duration: t(10), width: 2160, height: 3840, hasVideo: true, hasAlpha: true)
        let mockup = VideoProperties(transform: Transform(position: Point(x: 0.77, y: 0.5), scale: 1.15))
        XCTAssertTrue(jumps(project(broll: [broll("clip_phone", 10.066, 15, media: "med_phone", video: mockup)], media: [phone])).isEmpty, "a phone mock-up")

        let keyed = MediaItem(id: "med_keyed", path: "broll/keyed.mov", kind: .video, role: .broll, duration: t(10), width: 3840, height: 2160, hasVideo: true, hasAlpha: true)
        XCTAssertTrue(jumps(project(broll: [broll("clip_keyed", 10.066, 15, media: "med_keyed")], media: [keyed])).isEmpty, "a full-size file with alpha shows the camera through it")

        let logo = MediaItem(id: "med_logo", path: "graphics/convex.png", kind: .image, role: .image, width: 1000, height: 1000)
        let small = VideoProperties(transform: Transform(position: Point(x: 0.2, y: 0.65), scale: 0.18))
        XCTAssertTrue(jumps(project(broll: [broll("clip_logo", 10.066, 15, file: 0, media: "med_logo", video: small)], media: [logo])).isEmpty, "a logo")

        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5))
        XCTAssertTrue(jumps(project(broll: [broll("clip_pip", 10.066, 15, video: pip)])).isEmpty, "picture-in-picture")
        XCTAssertTrue(jumps(project(broll: [broll("clip_faded", 10.066, 15, video: VideoProperties(opacity: 0.5))])).isEmpty, "half see-through")
        XCTAssertTrue(jumps(project(broll: [broll("clip_cropped", 10.066, 15, video: VideoProperties(crop: Crop(left: 0.2)))])).isEmpty, "cropped off one side")
        let square = MediaItem(id: "med_square", path: "broll/square.mp4", kind: .video, role: .broll, duration: t(10), width: 1080, height: 1080, hasVideo: true)
        XCTAssertTrue(jumps(project(broll: [broll("clip_square", 10.066, 15, media: "med_square")], media: [square])).isEmpty, "a square shot fitted to the frame leaves the camera either side")
        XCTAssertEqual(jumps(project(broll: [broll("clip_square", 10.066, 15, media: "med_square", video: VideoProperties(transform: Transform(scale: 1.78)))], media: [square])).count, 1, "zoomed to fill the frame, it covers it")

        let title = Clip(id: "clip_title", content: .text(TextContent(text: "Batching")), start: t(10.066), duration: t(3))
        XCTAssertTrue(jumps(project(broll: [title])).isEmpty, "text")
        XCTAssertEqual(jumps(project(broll: [Clip(id: "clip_slug", content: .solid(color: .black), start: t(10.066), duration: t(3))])).count, 1, "a solid fills the frame")

        // Keyframed: a shot that slides in from the side covers the frame
        // only once it's there.
        var sliding = broll("clip_slide", 10.066, 15)
        sliding.keyframes["video.transform.position"] = [
            Keyframe(time: .zero, value: .point(Point(x: 1.5, y: 0.5))), Keyframe(time: t(0.5), value: .point(Point(x: 0.5, y: 0.5)))
        ]
        XCTAssertTrue(jumps(project(broll: [sliding])).isEmpty, "off the frame at its first frame")
    }

    func testShotsBackToBackShowNoCamera() {
        // The cut at 10 is under the first shot, and the second starts as
        // the first ends.
        let p = project(broll: [broll("clip_a", 5, 10.066), broll("clip_b", 10.066, 15, media: "med_other")])
        XCTAssertTrue(jumps(p).isEmpty, "\(jumps(p).map(\.message))")
        // One on a track above another's edge hides it.
        var stacked = project(broll: [broll("clip_a", 10.066, 15)])
        stacked.videoTracks.append(Track(id: "trk_broll2", kind: .video, name: "B-roll 2", clips: [broll("clip_top", 9, 12, media: "med_other")], rippleMode: .follow))
        XCTAssertTrue(jumps(stacked).isEmpty, "\(jumps(stacked).map(\.message))")
    }

    func testOnlyCutsInTheTakeCount() {
        // B-roll cut from one shot to another isn't a camera cut.
        var p = project(broll: [broll("clip_a", 2, 6)])
        p.videoTracks.append(Track(id: "trk_broll2", kind: .video, name: "B-roll 2", clips: [broll("clip_b", 6.05, 9, media: "med_other")], rippleMode: .follow))
        XCTAssertEqual(jumps(p).map(\.message), ["Camera flash: 2 frames of camera between w01-youtube-2025.mp4 and s03c-cursors-smooth.mp4. Run the first on to the second."], "a flash of camera between them, but no camera cut")
        // Nor is a cut in the screen recording under the camera full frame.
        var screen = project(broll: [broll("clip_w01", 25.05, 28)])
        let recording = MediaItem(id: "med_screen", path: "source/take1-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true)
        screen.media.append(recording)
        screen.videoTracks.insert(Track(id: "trk_screen", kind: .video, name: "Screen", clips: [
            Clip(id: "clip_scr1", content: .media(mediaID: "med_screen"), start: t(0), duration: t(25), sourceStart: t(0)),
            Clip(id: "clip_scr2", content: .media(mediaID: "med_screen"), start: t(25), duration: t(35), sourceStart: t(40))
        ], rippleMode: .cut), at: 0)
        XCTAssertTrue(jumps(screen).isEmpty, "the camera hides the screen's cut at 25: \(jumps(screen).map(\.message))")
        // With the camera in the corner it shows.
        screen.videoTracks[1].clips[2].video = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5))
        XCTAssertEqual(jumps(screen).map(\.start), [t(25)], "the screen's cut shows around the corner camera")
        XCTAssertTrue(jumps(screen).first?.message.contains("starts 2 frames after a cut in the screen recording, so its new shot flashes for 0.05 s before it.") == true, jumps(screen).first?.message ?? "")
    }

    func testACutUnderAFadeToBlackDoesntCount() {
        let fade = Transition(id: "tr_fade", type: .fadeFromBlack, duration: t(1), fromClipID: nil, toClipID: "clip_cam2")
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 10.066, 15)], cameraTransitions: [fade])).isEmpty)
    }

    func testTheStartAndEndOfTheTimelineArentCuts() {
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 0.05, 4)])).isEmpty, "the first frame of the video isn't a cut")
        XCTAssertTrue(jumps(project(broll: [broll("clip_w01", 55, 59.95)])).isEmpty, "nor is the last")
    }

    // MARK: - Flashes of camera between shots

    func testUnderASecondAndAHalfOfCameraBetweenShotsIsAFlash() throws {
        let p = project(broll: [broll("clip_a", 2, 5, file: 0, media: "med_shot"), broll("clip_b", 6, 9, file: 0, media: "med_other")])
        let found = jumps(p)
        XCTAssertEqual(found.map(\.kind), [.doubleJump])
        let problem = try XCTUnwrap(found.first)
        XCTAssertEqual(problem.start, t(5))
        XCTAssertEqual(problem.end, t(6))
        XCTAssertEqual(problem.clipIDs, ["clip_a", "clip_b"])
        XCTAssertEqual(problem.message, "Camera flash: 1.0 s of camera between w01-youtube-2025.mp4 and s03c-cursors-smooth.mp4. Run the first on to the second.")

        let after = try fixed(p, found)
        XCTAssertEqual(after.clip("clip_a")?.end, t(6), "run on to the second")
        XCTAssertEqual(after.clip("clip_a")?.start, t(2))
        XCTAssertEqual(after.clip("clip_a")?.holdEdges, false, "the file has 10 s")
        XCTAssertTrue(jumps(after).isEmpty)

        XCTAssertTrue(jumps(project(broll: [broll("clip_a", 2, 5, file: 0), broll("clip_b", 6.6, 9, file: 0, media: "med_other")])).isEmpty, "1.6 s of camera is a beat with him")
    }

    func testAFlashACutFallsInIsReportedOnceAsAFlash() throws {
        // The camera cuts at 10 between the shots: both edges are near it,
        // but it's one flash of camera, and one fix.
        let p = project(broll: [broll("clip_a", 5, 9.7, file: 0), broll("clip_b", 10.3, 15, file: 0, media: "med_other")])
        let found = jumps(p)
        XCTAssertEqual(found.count, 1, "\(found.map(\.message))")
        XCTAssertTrue(found.first?.message.hasPrefix("Camera flash: 0.6 s of camera between w01-youtube-2025.mp4 and s03c-cursors-smooth.mp4.") == true, found.first?.message ?? "")
        let after = try fixed(p, found)
        XCTAssertEqual(after.clip("clip_a")?.end, t(10.3))
        XCTAssertTrue(jumps(after).isEmpty)
    }

    func testAGapWithNothingUnderItIsntACameraFlash() {
        // Black between the shots is the gap check's to report.
        var p = project(broll: [broll("clip_a", 62, 65, file: 0), broll("clip_b", 66, 69, file: 0, media: "med_other")])
        p.videoTracks[0].clips.append(Clip(id: "clip_cam6", content: .media(mediaID: "med_camera"), start: t(70), duration: t(10), sourceStart: t(100)))
        XCTAssertTrue(jumps(p, in: [TimeRange(start: .zero, end: t(80))]).isEmpty)
    }

    // MARK: - The fix

    func testTheFixHoldsAnEdgeFrameOnlyWhenTheFileRunsOut() throws {
        // Starts at the file's first frame: running back to the cut holds it.
        let p = project(broll: [broll("clip_w01", 10.066, 15, file: 0)])
        let found = jumps(p)
        XCTAssertTrue(found.first?.message.hasSuffix("Extend it back to the cut, holding its first frame.") == true, found.first?.message ?? "")
        let after = try fixed(p, found)
        let moved = try XCTUnwrap(after.clip("clip_w01"))
        XCTAssertEqual(moved.start, t(10))
        XCTAssertTrue(moved.holdEdges)
        XCTAssertEqual(moved.sourceStart, t(-0.066), "the file's first frame still lands at 10.066")
        XCTAssertEqual(after.heldStretches(of: moved).head, TimeRange(start: t(10), end: t(10.066)))

        // Ends with the file: running on to the cut holds its last frame.
        let short = MediaItem(id: "med_short", path: "broll/short.mp4", kind: .video, role: .broll, duration: t(4.95), width: 3840, height: 2160, hasVideo: true)
        let q = project(broll: [broll("clip_short", 15, 19.95, file: 0, media: "med_short")], media: [short])
        let ending = jumps(q)
        XCTAssertTrue(ending.first?.message.hasSuffix("Run it on to the cut, holding its last frame.") == true, ending.first?.message ?? "")
        let ran = try XCTUnwrap(try fixed(q, ending).clip("clip_short"))
        XCTAssertEqual(ran.end, t(20))
        XCTAssertTrue(ran.holdEdges)
    }

    func testTheFixKeepsKeyframesWhereTheyWereOnTheTimeline() throws {
        var zooming = broll("clip_w01", 10.066, 15)
        zooming.keyframes["video.transform.scale"] = [Keyframe(time: .zero, value: .number(1)), Keyframe(time: t(4.934), value: .number(1.12))]
        let p = project(broll: [zooming])
        let after = try fixed(p, jumps(p))
        let moved = try XCTUnwrap(after.clip("clip_w01"))
        XCTAssertEqual(moved.keyframes["video.transform.scale"]?.map(\.time), [t(0.066), t(5)], "the zoom still starts at 10.066 and ends at 15")
    }

    func testBothEdgesOfOneShotAreFixedByOneEdit() throws {
        let p = project(broll: [broll("clip_w01", 10.066, 19.95)])
        let found = jumps(p)
        XCTAssertEqual(found.count, 2, "its start and its end")
        XCTAssertEqual(found[0].fix, found[1].fix, "one patch sets both edges")
        XCTAssertEqual(QualityCheck.commands(fixing: found).count, 1)
        let moved = try XCTUnwrap(try fixed(p, found).clip("clip_w01"))
        XCTAssertEqual(moved.range, TimeRange(start: t(10), end: t(20)))
    }

    func testACopyOfTheShotOnAnotherTrackMovesWithIt() throws {
        // A portrait shot: a blurred copy zoomed to fill the frame, and the
        // sharp copy over it in the middle (Convex 1.48). Running only the
        // background out to the cut would leave the sharp copy popping in.
        let portrait = MediaItem(id: "med_portrait", path: "broll/147-callback.mp4", kind: .video, role: .broll, duration: t(10), width: 1080, height: 1920, hasVideo: true)
        let background = broll("clip_bg", 10.066, 15, media: "med_portrait", video: VideoProperties(transform: Transform(scale: 3.2)))
        let sharp = broll("clip_fg", 10.066, 15, media: "med_portrait", video: VideoProperties(transform: Transform(scale: 0.9)))
        let p = project(broll: [background], graphics: [sharp], media: [portrait])
        let found = jumps(p)
        XCTAssertEqual(found.count, 1, "\(found.map(\.message))")
        XCTAssertEqual(found.first?.clipIDs, ["clip_bg"], "the picture that covers the frame")
        XCTAssertTrue(found.first?.message.hasSuffix("Extend it and its copy on \"Graphics\" back to the cut.") == true, found.first?.message ?? "")
        XCTAssertEqual(found.first?.moreFixes?.count, 1)
        XCTAssertEqual(QualityCheck.commands(fixing: found).count, 2)
        let after = try fixed(p, found)
        XCTAssertEqual(after.clip("clip_bg")?.start, t(10))
        XCTAssertEqual(after.clip("clip_fg")?.start, t(10), "the sharp copy comes in with it")
        XCTAssertEqual(after.clip("clip_fg")?.sourceTime(atTimelineTime: t(12)), after.clip("clip_bg")?.sourceTime(atTimelineTime: t(12)), "still in step")
    }

    func testNoFixWhenAnotherClipOnTheTrackIsInTheWay() {
        // A sticker on the B-roll track between the cut and the shot.
        let logo = MediaItem(id: "med_logo", path: "graphics/convex.png", kind: .image, role: .image, width: 1000, height: 1000)
        let sticker = Clip(id: "clip_logo", content: .media(mediaID: "med_logo"), start: t(9.5), duration: t(0.55), video: VideoProperties(transform: Transform(scale: 0.2)))
        let found = jumps(project(broll: [sticker, broll("clip_w01", 10.066, 15)], media: [logo]))
        XCTAssertEqual(found.map(\.kind), [.doubleJump], "still a problem")
        XCTAssertNil(found.first?.fix)
        XCTAssertTrue(found.first?.message.hasSuffix("Extend it back to the cut. convex.png on \"B-roll\" is in the way.") == true, found.first?.message ?? "")
    }

    func testFixesComeBeforeHoldsSoAHoldCantCutTheClipFirst() {
        let hold = CheckProblem(kind: .flicker, start: t(12), end: t(12.033), message: "Flicker", fix: .holdFrame(clipID: "clip_w01", range: TimeRange(start: t(12), end: t(12.033))))
        let found = jumps(project(broll: [broll("clip_w01", 10.066, 15)]))
        let commands = QualityCheck.commands(fixing: found + [hold])
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last, hold.fix, "the double jump's patch sets the clip's edges as checked, so it goes first")
        XCTAssertEqual(QualityCheck.fixLabel(for: [hold]), QualityCheck.holdLabel)
        XCTAssertEqual(QualityCheck.fixLabel(for: found), QualityCheck.doubleJumpLabel)
        XCTAssertTrue(QualityCheck.fixLabel(for: found + [hold]).hasPrefix(QualityCheck.holdLabel))
    }

    // MARK: - Where it looks

    func testItRunsAsAModelCheckOnTheStretchesAsked() {
        let p = project(broll: [broll("clip_w01", 10.066, 15)])
        // A quick or changed check: no frames, only the stretch changed
        // (the shot, half a second either side).
        let changed = [TimeRange(start: t(9.566), end: t(15.5))]
        XCTAssertEqual(QualityCheck.problems(in: p, ranges: changed, frames: nil).map(\.kind), [.doubleJump])
        XCTAssertEqual(QualityCheck.problems(in: p, ranges: [TimeRange(start: t(10.066), end: t(15))], frames: nil).map(\.kind), [.doubleJump], "a stretch that starts at the shot still sees the cut before it")
        XCTAssertTrue(QualityCheck.problems(in: p, ranges: [TimeRange(start: t(40), end: t(50))], frames: nil).isEmpty, "somewhere else")
    }
}
