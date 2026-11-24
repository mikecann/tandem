import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

extension PrivacyAuditRenderTests {
    func testAProbedDroppedFrameCannotExposeTheSameDecodedSampleInAnotherFreeze() async throws {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let (media, c) = try await fixture(video: true)
        let dropped = media.folder.appendingPathComponent("dropped.mov")
        try ffmpeg.run(["-v", "error", "-i", media.folder.appendingPathComponent("dummy.mov").path,
                        "-vf", "select=not(eq(n\\,30))", "-fps_mode", "vfr", "-c:v", "libx264", "-bf", "0", dropped.path])
        let probed = try await MediaScanner.probe(dropped, folder: media.projectFolder)
        XCTAssertFalse(probed.variableFrameRate, "a single dropped frame keeps the probe's regular-rate classification")
        let readSamples = await FrameTimes.read(probed, in: media.projectFolder)
        let samples = try XCTUnwrap(readSamples)
        XCTAssertFalse(samples.contains(t(1)))
        XCTAssertTrue(try apply(c, .updateMedia(mediaID: "med_dummy", patch: .object(["path": .string("dropped.mov")]))))
        XCTAssertTrue(try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["duration": .number(1), "sourceStart": .number(1.01), "freezeFrame": .bool(true)]))))
        try hide(c, range: TimeRange(start: .zero, end: t(1)))
        let reused = Clip(id: "clip_dropped_again", content: .media(mediaID: "med_dummy"), start: t(2), duration: t(1), sourceStart: t(0.98), freezeFrame: true)
        XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_screen", clip: reused)))
        try await panelCovered(c, media, at: 2.5, name: "dropped-frame-reuse", encode: true)
    }

    func testSuccessivePrivacyReadersReturnEveryOutputFrame() async throws {
        try skipSlowPrivacyRenderOnCI()
        let (media, c) = try await fixture(video: true, timed: true)
        let context = RenderContext(project: c.project, folder: media.projectFolder)
        let times = (0..<90).map { Time.frames(Int64($0), at: .fps30) }
        for _ in 0..<8 {
            let reader = FrameTextReader(context: context, width: 1280)
            let frames = try await reader.read(times, sequential: true)
            XCTAssertEqual(frames.map(\.time), times)
            XCTAssertTrue(frames.allSatisfy { $0.recognitionError == nil })
        }
    }

    func testBlurringTransparentGlyphsReplacesTheirSharpSourcePixels() async throws {
        let (media, c) = try await fixture()
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.translateBy(x: 0, y: 720)
        bitmap.scaleBy(x: 1, y: -1)
        text(email, x: 120, y: 260, size: 45, in: bitmap)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(media.folder.appendingPathComponent("dummy.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertTrue(try apply(c, .addTrack(kind: .video, name: "White", index: 0, id: "trk_white")))
        XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_white", clip: Clip(id: "clip_white", content: .solid(color: .white), start: .zero, duration: t(3)))))
        let control = try await image(c, media)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) })
        try hide(c)
        let concealed = Bitmap(try await image(c, media))
        let darkest = (210..<260).map { y in (120..<600).map { concealed.luma($0, y) }.min()! }.min()!
        XCTAssertGreaterThan(darkest, 180, "filtered alpha must replace the original sharp glyphs")
        try await panelCovered(c, media, at: 1.5, name: "transparent-glyphs", encode: true)
    }

    func testVariableRateProtectionConcealsReusedFramesOutsideItsNominalSelection() async throws {
        let (media, c) = try await fixture(video: true)
        let control = try await image(c, media, at: 0.5)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) })
        XCTAssertTrue(try apply(c, .updateMedia(mediaID: "med_dummy", patch: .object(["variableFrameRate": .bool(true)]))))
        try hide(c, range: TimeRange(start: t(1), end: t(2)))
        // Modal VFR metadata cannot identify repeated samples. The fallback
        // deliberately hides this source region outside the nominal span.
        let outside = try await image(c, media, at: 0.5)
        XCTAssertFalse(recognise(outside).contains { $0.contains(email) })
        let reused = Clip(id: "clip_vfr_again", content: .media(mediaID: "med_dummy"), start: t(5), duration: t(0.5), sourceStart: t(0.25))
        XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_screen", clip: reused)))
        try await panelCovered(c, media, at: 5.25, name: "vfr-reused-source")
        var frozen = reused
        frozen.id = "clip_vfr_frozen"
        frozen.start = t(6)
        frozen.freezeFrame = true
        XCTAssertTrue(try apply(c, .insertClip(trackID: "trk_screen", clip: frozen)))
        try await panelCovered(c, media, at: 6.25, name: "vfr-frozen-source")
    }

    func testARoundedHeldFrameCannotEscapeAtTheMasksLastFrame() async throws {
        let (media, c) = try await panelReady()
        let following = c.project.videoTracks[0].clips.first { $0.start == t(3) }!
        let before = c.project
        do {
            _ = try c.apply(EditBatch(label: "Rounded hold", commands: [
                .holdFrame(clipID: following.id, range: TimeRange(start: t(3), end: t(3.5005))),
                .redact(range: TimeRange(start: t(3), end: t(3.5)), rect: region, mediaID: "med_dummy", style: .blur, size: 90)
            ]))
        } catch let error as EditError {
            XCTAssertTrue(String(describing: error).lowercased().contains("privacy") || String(describing: error).lowercased().contains("protected"))
            XCTAssertEqual(c.project, before)
        }
        try await panelCovered(c, media, at: 3.5, name: "rounded-held-frame", encode: true)
    }

    func testAFormerlySmallPrivacyCopyCannotOverwriteSourceProtectionWithAWeakerBlur() async throws {
        let (media, c) = try await fixture()
        let control = try await image(c, media)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) })
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["scale": .number(0.125)])])])))
        try apply(c, .redact(range: TimeRange(start: .zero, end: t(3)), rect: region, mediaID: "med_dummy", style: .blur, size: 6))
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["scale": .number(1)])])])))
        let enlarged = Bitmap(try await image(c, media))
        let darkest = (210..<260).map { y in (120..<600).map { enlarged.luma($0, y) }.min()! }.min()!
        XCTAssertGreaterThan(darkest, 180, "the copy must retain the source blur instead of drawing sharper glyphs over it")
        try await panelCovered(c, media, at: 1.5, name: "zoom-retains-copy-strength", encode: true)
    }

    func testRoundThreePictureOnlyHoldAfterRedactionStillExposesWhenMoved() async throws {
        // This movie has the dummy email in every frame, including the
        // held frame before sourceStart. Redact before adding the hold.
        let (media, c) = try await fixture(video: true)
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["sourceStart": .number(1)])))
        try hide(c)
        let maskID = c.project.videoTracks.first { $0.isPrivacy }!.clips[0].id
        try apply(c, .holdFrame(clipID: "clip_dummy", range: TimeRange(start: .zero, end: t(3))))
        XCTAssertEqual(c.project.clip(maskID)!.holds, c.project.clip("clip_dummy")!.holds)
        XCTAssertEqual(c.project.clip("clip_dummy")!.pictureTime(atTimelineTime: t(1)).seconds, 29.0/30, accuracy: 1e-8)
        let before = try await image(c, media)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        try png(before, "round3-picture-only-hold-before")
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        try await panelCovered(c, media, at: 1.5, name: "round3-picture-only-hold", encode: true)
    }

    func testRoundTwoHeldFrameOutsideNominalSpanRemainsInTheAudit() async throws {
        let (media, c) = try await fixture(video: true)
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["sourceStart": .number(1)])))
        try apply(c, .holdFrame(clipID: "clip_dummy", range: TimeRange(start: .zero, end: t(3))))
        XCTAssertEqual(c.project.clip("clip_dummy")!.pictureTime(atTimelineTime: t(1)).seconds, 29.0/30, accuracy: 1e-8)
        try hide(c)
        let before = try await image(c, media)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        try await panelCovered(c, media, at: 1.5, name: "round2-held-before-source", encode: true)
    }

    func testRoundTwoZeroBlurTransferCanPassThePrivacyScan() async throws {
        try skipSlowPrivacyRenderOnCI()
        let (media, c) = try await panelReady()
        let picture = panelPicture(c)
        try apply(c, .addEffect(clipID: picture.id, effect: Effect(id: "fx_zero", type: "blur", params: ["radius": .number(0)])))
        try apply(c, .addTrack(kind: .video, name: "B-roll", index: nil, id: "trk_upper"))
        try apply(c, .moveClips(clipIDs: [picture.id], delta: .zero, toTrackID: "trk_upper"))
        try await panelCovered(c, media, at: 2, name: "round2-zero-blur-transfer", encode: true)
        let skipped = try await scan(c, media, to: 4)
        print("ROUND2 zero-radius source blur: \(skipped.count) privacy problems despite readable email")
        XCTAssertTrue(skipped.isEmpty)
        try apply(c, .removeEffect(clipID: picture.id, effectID: "fx_zero"))
        let detected = try await scan(c, media, to: 4)
        XCTAssertTrue(detected.isEmpty, "the transfer stays safe with or without the no-op source effect")
    }

    func testRoundTwoContinuousRollThenMoveExposesBothNeighbours() async throws {
        try skipSlowPrivacyRenderOnCI()
        for edge in ["head", "tail"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            let neighbour = c.project.videoTracks[0].clips.first { edge == "head" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .roll(leftClipID: edge == "head" ? neighbour.id : picture.id, rightClipID: edge == "head" ? picture.id : neighbour.id, delta: t(edge == "head" ? 0.2 : -0.2)))
            let immediate = try await scan(c, media, to: 4)
            XCTAssertTrue(immediate.isEmpty)
            try apply(c, .moveClips(clipIDs: [picture.id], delta: t(4)))
            try await panelCovered(c, media, at: edge == "head" ? 1.1 : 2.9, name: "round2-roll-\(edge)-then-move", encode: edge == "head")
        }
    }

    func testRoundTwoRollAndAdjacentSlideThenSpeedExposeTheTail() async throws {
        try skipSlowPrivacyRenderOnCI()
        for setup in ["roll faster", "roll slower", "adjacent slide"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            let left = c.project.videoTracks[0].clips.first { $0.end == t(1) }!
            if setup == "adjacent slide" {
                try apply(c, .slide(clipID: left.id, delta: t(0.2)))
            } else {
                try apply(c, .roll(leftClipID: left.id, rightClipID: picture.id, delta: t(setup == "roll slower" ? -0.2 : 0.2)))
            }
            let immediate = try await scan(c, media, to: 4)
            XCTAssertTrue(immediate.isEmpty)
            try apply(c, .setSpeed(clipID: picture.id, speed: setup == "roll slower" ? 0.5 : 2, ripple: true))
            let name = setup.replacingOccurrences(of: " ", with: "-")
            try await panelCovered(c, media, at: setup == "roll slower" ? 5.1 : 61.0/30, name: "round2-\(name)-then-speed", encode: setup == "roll faster")
        }
    }

    func testRoundTwoNeighbourRippleTrimsExposeProtectedSource() async throws {
        for edge in ["left tail", "right head"] {
            let (media, c) = try await panelReady()
            let neighbour = c.project.videoTracks[0].clips.first { edge == "left tail" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .trim(clipID: neighbour.id, edge: edge == "left tail" ? .end : .start, to: t(edge == "left tail" ? 1.4 : 2.6), ripple: true))
            let name = edge.replacingOccurrences(of: " ", with: "-")
            try await panelCovered(c, media, at: edge == "left tail" ? 1.2 : 3.2, name: "round2-trim-\(name)", encode: edge == "left tail")
        }
    }

    func testRoundTwoNeighbourSlipsExposeProtectedSource() async throws {
        for side in ["left", "right"] {
            let (media, c) = try await panelReady()
            let neighbour = c.project.videoTracks[0].clips.first { side == "left" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .slip(clipID: neighbour.id, delta: t(side == "left" ? 1 : -1)))
            try await panelCovered(c, media, at: side == "left" ? 0.5 : 3.5, name: "round2-slip-\(side)", encode: side == "left")
        }
    }

    func testRoundTwoRawDurationSpeedSourceAndFreezeEachHaveAnExposureCase() async throws {
        for field in ["duration", "speed", "sourceStart", "freezeFrame"] {
            if field == "duration" {
                let (media, c) = try await fixture(video: true, timed: true)
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(1)])))
                try hide(c)
                let before = try await image(c, media, at: 2.5)
                XCTAssertFalse(recognise(before).contains { $0.contains(email) })
                try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["duration": .number(4)])))
                try await panelCovered(c, media, at: 3.5, name: "round2-raw-duration-frozen", encode: true)
            } else {
                let (media, c) = try await panelReady()
                let left = c.project.videoTracks[0].clips.first { $0.end == t(1) }!
                if field == "freezeFrame" {
                    try apply(c, .updateClip(clipID: left.id, patch: .object(["freezeFrame": .bool(true), "sourceStart": .number(0.5)])))
                    let before = try await scan(c, media, to: 4)
                    XCTAssertTrue(before.isEmpty)
                }
                let value: JSONValue = field == "freezeFrame" ? .bool(false) : .number(field == "speed" ? 2 : 1)
                try apply(c, .updateClip(clipID: left.id, patch: .object([field: value])))
                try await panelCovered(c, media, at: field == "freezeFrame" ? 0.75 : 0.5, name: "round2-raw-\(field)-neighbour", encode: field == "speed")
            }
        }
    }

    func testRoundTwoFollowingClipHoldRepeatsPrivateFrameBeyondTheMask() async throws {
        let (media, c) = try await panelReady()
        let right = c.project.videoTracks[0].clips.first { $0.start == t(3) }!
        let before = try await image(c, media, at: 3.2)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        if try apply(c, .holdFrame(clipID: right.id, range: TimeRange(start: t(3), end: t(3.5)))) {
            XCTAssertEqual(c.project.clip(right.id)!.pictureTime(atTimelineTime: t(3.2)).seconds, 89.0/30, accuracy: 1e-8)
        }
        try await panelCovered(c, media, at: 3.2, name: "round2-following-hold", encode: true)
    }
}
