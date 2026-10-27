import XCTest
@testable import TandemCore

final class LayoutTests: XCTestCase {
    func testPipRightAddsCutoutAndShadowOnce() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipRight))
        try c.run("PiP again", .applyLayout(clipIDs: [camera], preset: .pipRight))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform.scale, 0.5)
        XCTAssertEqual(video.transform.position, LayoutPreset.pipRightPosition)
        XCTAssertEqual(video.cutout?.enabled, true)
        XCTAssertEqual(video.cutout?.mode, .personAndProps)
        XCTAssertEqual(video.effects.filter { $0.type == "dropShadow" }.count, 1)
        XCTAssertEqual(video.layoutPreset, "pipRight")
    }

    func testFullRemovesThePipLook() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipLeft))
        try c.run("Full", .applyLayout(clipIDs: [camera], preset: .full))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform, Transform())
        XCTAssertEqual(video.cutout?.enabled, false)
        XCTAssertTrue(video.effects.isEmpty)
    }

    /// "When you move me over to the left hand side, can you flip me
    /// horizontally so that it looks like I'm facing the actual app?"
    /// (Batching Component, 2026-10-27.)
    func testPipLeftFlipsTheCameraSoMikeFacesIntoTheFrame() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("PiP left", .applyLayout(clipIDs: [camera], preset: .pipLeft))
        XCTAssertEqual(c.project.clip(camera)?.video?.transform.flipped, true)
        XCTAssertEqual(c.project.clip(camera)?.video?.transform.position, LayoutPreset.pipLeftPosition)
        try c.run("PiP right", .applyLayout(clipIDs: [camera], preset: .pipRight))
        XCTAssertEqual(c.project.clip(camera)?.video?.transform.flipped, false, "back on the right he faces in already")
        try c.run("PiP left", .applyLayout(clipIDs: [camera], preset: .pipLeft))
        try c.run("Full", .applyLayout(clipIDs: [camera], preset: .full))
        XCTAssertEqual(c.project.clip(camera)?.video?.transform.flipped, false, "full frame is the take as filmed")
    }

    func testPipLeftOnlyFlipsTheCamera() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0].id
        try c.run("PiP left", .applyLayout(clipIDs: [screen], preset: .pipLeft))
        XCTAssertEqual(c.project.clip(screen)?.video?.transform.flipped, false, "mirrored text would read backwards")
    }

    func testAZoomOnAFlippedClipShowsTheRegionAsked() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0].id
        try c.run("Flip", .updateClip(clipID: screen, patch: .object(["video": .object(["transform": .object(["flipped": .bool(true)])])])))
        // The right half of the file shows on the left of a flipped clip,
        // so zooming into it moves the picture right.
        try c.run("Zoom", .zoomToRegion(clipID: screen, rect: Rect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), at: nil, duration: nil))
        let transform = try XCTUnwrap(c.project.clip(screen)?.video?.transform)
        XCTAssertTrue(transform.flipped, "a zoom keeps the flip")
        XCTAssertEqual(transform.scale, 2, accuracy: 1e-6)
        XCTAssertEqual(transform.position.x, 1, accuracy: 1e-6)
    }

    func testAFlipIsOnlySavedWhenItsOn() throws {
        let plain = try JSONEncoder().encode(Transform())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("flipped"), "projects with nothing flipped save as before")
        let old = try JSONDecoder().decode(Transform.self, from: Data(#"{"position":{"x":0.13,"y":0.77},"scale":0.5,"rotation":0}"#.utf8))
        XCTAssertFalse(old.flipped)
        let flipped = Transform(position: LayoutPreset.pipLeftPosition, scale: 0.5, flipped: true)
        XCTAssertEqual(try JSONDecoder().decode(Transform.self, from: JSONEncoder().encode(flipped)), flipped)
    }

    func testLayoutSkipsAudioClips() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Voice", .applyLayout(clipIDs: [f.clips("Voice")[0].id], preset: .pipRight)))
    }

    func testShowingARegion() {
        // A 16:9 source on a 16:9 canvas: the right half, middle, is 2x.
        let t = Transform.showing(Rect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 3840, canvasHeight: 2160)
        XCTAssertEqual(t.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(t.position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(t.position.y, 0.5, accuracy: 1e-9)
        // The whole frame is identity.
        let identity = Transform.showing(Rect(x: 0, y: 0, width: 1, height: 1), sourceWidth: 3200, sourceHeight: 1800, canvasWidth: 3840, canvasHeight: 2160)
        XCTAssertEqual(identity.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(identity.position.x, 0.5, accuracy: 1e-9)
    }

    func testAnimatedZoomAddsEasedKeyframes() throws {
        let (f, c) = try Fixture.edited()
        let screen = f.clips("Screen")[0].id
        try c.run("Zoom", .zoomToRegion(clipID: screen, rect: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), at: t(10), duration: t(0.5)))
        let clip = try XCTUnwrap(c.project.clip(screen))
        XCTAssertEqual(clip.resolvedVideo(at: t(5)).transform.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(clip.resolvedVideo(at: t(11)).transform.scale, 2, accuracy: 1e-9)
        let mid = clip.resolvedVideo(at: t(10.25)).transform.scale
        XCTAssertGreaterThan(mid, 1)
        XCTAssertLessThan(mid, 2)
        try c.run("Out", .zoomToRegion(clipID: screen, rect: Rect(x: 0, y: 0, width: 1, height: 1), at: t(20)))
        XCTAssertEqual(c.project.clip(screen)!.resolvedVideo(at: t(21)).transform.scale, 1, accuracy: 1e-9)
    }
}

final class PortraitLayoutTests: XCTestCase {
    func testFillingTheBottomHalfOfAShort() {
        // A 16:9 camera on 1080x1920: fitted it's 1080x607.5, so filling a
        // 960 px tall half needs 960 / 607.5.
        let t = Transform.filling(.bottom, sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(t.scale, 960 / 607.5, accuracy: 1e-9)
        XCTAssertEqual(t.position, Point(x: 0.5, y: 0.75))
        let full = Transform.filling(.full, sourceWidth: 3840, sourceHeight: 2160, canvasWidth: 1080, canvasHeight: 1920)
        XCTAssertEqual(full.scale, 1920 / 607.5, accuracy: 1e-9)
    }

    func testSetFormatLayoutNeedsTheFormatAndKeepsTheMainLayout() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        XCTAssertThrowsError(try c.run("Short", .setFormatLayout(clipIDs: [camera], format: "portrait", slot: .bottom)))
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": .array([try JSONValue.from(OutputFormat.portrait)])])))
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipRight))
        try c.run("Short", .setFormatLayout(clipIDs: [camera], format: "portrait", slot: .bottom, cutout: false))
        let video = try XCTUnwrap(c.project.clip(camera)?.video)
        XCTAssertEqual(video.transform.scale, 0.5, "the landscape layout is untouched")
        let override = try XCTUnwrap(video.formatOverrides["portrait"])
        XCTAssertEqual(override.transform?.position, Point(x: 0.5, y: 0.75))
        XCTAssertEqual(override.cutout, false)
    }
}

/// `adoptFormat`: a project's 9:16 format becomes its canvas, so the app
/// shows the short as it exports (Convex 1.47 Short, 2026-10-16).
final class AdoptFormatTests: XCTestCase {
    /// What the short shows of a clip, as TandemRender's
    /// `resolvedVideo(at:format:)` works it out: the override's transform
    /// and crop replace the animated ones.
    func inShort(_ clip: Clip?, at time: Time) -> VideoProperties? {
        guard let clip else { return nil }
        var video = clip.resolvedVideo(at: time)
        guard let override = clip.video?.formatOverrides["portrait"] else { return video }
        if let transform = override.transform { video.transform = transform }
        if let crop = override.crop { video.crop = crop }
        return video
    }

    /// The edited fixture laid out as a short: camera PiP in the landscape
    /// edit and the bottom half in the short, the screen in the top half.
    func laidOut() throws -> (ProjectCoordinator, camera: String, screen: String) {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        let screen = f.clips("Screen")[0].id
        try c.run("Format", .updateSettings(patch: .object(["alternateFormats": .array([try JSONValue.from(OutputFormat.portrait)])])))
        try c.run("PiP", .applyLayout(clipIDs: [camera], preset: .pipRight))
        try c.run("Short", .setFormatLayout(clipIDs: [camera], format: "portrait", slot: .bottom, cutout: false),
                  .setFormatLayout(clipIDs: [screen], format: "portrait", slot: .top))
        return (c, camera, screen)
    }

    func testTheShortBecomesTheCanvas() throws {
        let (c, camera, screen) = try laidOut()
        let before = c.project
        try c.run("Portrait", .adoptFormat(format: "portrait"))
        let p = c.project
        XCTAssertEqual(p.settings.width, 1080)
        XCTAssertEqual(p.settings.height, 1920)
        XCTAssertTrue(p.settings.alternateFormats.isEmpty, "it's the canvas now")
        for id in [camera, screen] {
            let was = try XCTUnwrap(inShort(before.clip(id), at: t(5)))
            let now = try XCTUnwrap(p.clip(id)?.resolvedVideo(at: t(5)))
            XCTAssertEqual(now.transform, was.transform, "placed where the short had it")
            XCTAssertEqual(now.crop, was.crop)
            XCTAssertNil(p.clip(id)?.video?.formatOverrides["portrait"])
        }
        XCTAssertEqual(p.clip(camera)?.video?.cutout?.enabled, false, "the short's camera keeps its background")
        XCTAssertNil(p.clip(camera)?.video?.layoutPreset, "no longer the PiP")
        assertValid(p)
    }

    func testAStickersPopKeepsItsSizeInTheShort() throws {
        // A sticker at 0.3 in landscape and 0.85 in the short pops in to
        // 0.33 and out to 0.01. Its keyframes are absolute, so moved across
        // as they were it would shrink back to its landscape size.
        let (c, _, screen) = try laidOut()
        try c.run("Sticker", .updateClip(clipID: screen, patch: .object(["video": .object(["transform": .object(["scale": .number(0.3)])])])))
        try c.run("Pop", .setKeyframes(clipID: screen, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: t(0), value: .number(0.3)), Keyframe(time: t(1), value: .number(0.33)), Keyframe(time: t(2), value: .number(0.01))
        ]))
        var video = try XCTUnwrap(c.project.clip(screen)?.video)
        video.formatOverrides["portrait"]?.transform?.scale = 0.85
        try c.run("Short size", .updateClip(clipID: screen, patch: .object(["video": .object(["formatOverrides": try JSONValue.from(video.formatOverrides)])])))
        try c.run("Portrait", .adoptFormat(format: "portrait"))
        let clip = try XCTUnwrap(c.project.clip(screen))
        XCTAssertEqual(clip.video?.transform.scale ?? 0, 0.85, accuracy: 1e-9)
        let values = (clip.keyframes["video.transform.scale"] ?? []).compactMap(\.value.number)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], 0.85, accuracy: 1e-9)
        XCTAssertEqual(values[1], 0.935, accuracy: 1e-9)
        XCTAssertEqual(values[2], 0.85 / 30, accuracy: 1e-9)
    }

    func testAZoomThatMovesIsDroppedWithAWarning() throws {
        // The short never showed it (an override's transform replaces the
        // animated one), and a landscape pan doesn't map onto a half-frame.
        let (c, _, screen) = try laidOut()
        try c.run("Zoom", .zoomToRegion(clipID: screen, rect: Rect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), at: t(10)))
        let shown = try XCTUnwrap(inShort(c.project.clip(screen), at: t(15))?.transform)
        let result = try c.run("Portrait", .adoptFormat(format: "portrait"))
        let clip = try XCTUnwrap(c.project.clip(screen))
        XCTAssertNil(clip.keyframes["video.transform.scale"])
        XCTAssertNil(clip.keyframes["video.transform.position"])
        XCTAssertEqual(clip.resolvedVideo(at: t(15)).transform, shown, "as the short showed it")
        XCTAssertTrue(result.warnings.contains { $0.contains("zoom") }, "\(result.warnings)")
    }

    func testAClipHiddenInTheShortIsSwitchedOff() throws {
        let (c, _, screen) = try laidOut()
        var video = try XCTUnwrap(c.project.clip(screen)?.video)
        video.formatOverrides["portrait"]?.hidden = true
        try c.run("Hide", .updateClip(clipID: screen, patch: .object(["video": .object(["formatOverrides": try JSONValue.from(video.formatOverrides)])])))
        try c.run("Portrait", .adoptFormat(format: "portrait"))
        XCTAssertEqual(c.project.clip(screen)?.enabled, false)
    }

    func testItNeedsTheFormat() throws {
        let (_, c) = try Fixture.edited()
        XCTAssertThrowsError(try c.run("Portrait", .adoptFormat(format: "portrait")))
    }
}

final class StillsTests: XCTestCase {
    /// A landscape photo in a 1080x1920 short.
    func shortWithPhoto() throws -> (ProjectCoordinator, String) {
        var p = Project.standard(name: "Short")
        p.settings.width = 1080
        p.settings.height = 1920
        p.media = [MediaItem(id: "med_photo", path: "photos/bench.jpg", kind: .image, role: .image, width: 4032, height: 3024, hasVideo: false)]
        let c = ProjectCoordinator(project: p)
        try c.run("Place", .placeMedia(mediaIDs: ["med_photo"], at: .zero, duration: Time(seconds: 4)))
        return (c, c.project.track(named: "B-roll")!.clips[0].id)
    }

    func testFillCoversAPortraitFrame() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        // 4032x3024 fitted into 1080x1920 is 1080x810; covering 1920 tall
        // needs 1920 / 810.
        let scale = try XCTUnwrap(c.project.clip(photo)?.video?.transform.scale)
        XCTAssertEqual(scale, 1920 / 810, accuracy: 1e-9)
        XCTAssertEqual(c.project.clip(photo)?.video?.layoutPreset, "fill")
    }

    func testZoomInMovesFromTheFillToABitCloser() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        try c.run("Push", .addMotion(clipIDs: [photo], style: .zoomIn))
        let clip = try XCTUnwrap(c.project.clip(photo))
        let fill = 1920.0 / 810
        XCTAssertEqual(clip.resolvedVideo(at: .zero).transform.scale, fill, accuracy: 1e-6)
        XCTAssertEqual(clip.resolvedVideo(at: clip.duration).transform.scale, fill * 1.12, accuracy: 1e-6)
        XCTAssertEqual(clip.resolvedVideo(at: Time(seconds: 2)).transform.scale, fill * 1.06, accuracy: 1e-6, "linear, not eased")
    }

    func testPanLeftTravelsAcrossTheOverflowWithoutShowingAnEdge() throws {
        let (c, photo) = try shortWithPhoto()
        try c.run("Fill", .applyLayout(clipIDs: [photo], preset: .fill))
        try c.run("Pan", .addMotion(clipIDs: [photo], style: .panLeft))
        let clip = try XCTUnwrap(c.project.clip(photo))
        let start = clip.resolvedVideo(at: .zero).transform.position.x
        let end = clip.resolvedVideo(at: clip.duration).transform.position.x
        XCTAssertGreaterThan(start, 0.5)
        XCTAssertLessThan(end, 0.5)
        // The photo is 1080 * 1920/810 = 2560 px wide on a 1080 px frame:
        // its centre can move 0.685 either way; the pan uses 80% of that.
        let room = (2560.0 / 1080 - 1) / 2
        XCTAssertEqual(start - 0.5, room * 0.8, accuracy: 1e-6)
    }

    func testMotionAmountIsChecked() throws {
        let (c, photo) = try shortWithPhoto()
        XCTAssertThrowsError(try c.run("Too much", .addMotion(clipIDs: [photo], style: .zoomIn, amount: 5)))
    }
}
