import AVFoundation
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

extension PrivacyAuditRenderTests {
    func testRoundThreePictureOnlyHoldAfterRedactionStillExposesWhenMoved() async throws {
        // This movie has the dummy email in every frame, including the
        // held frame before sourceStart. Redact before adding the hold.
        let (media, c) = try await fixture(video: true)
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["sourceStart": .number(1)])))
        try hide(c)
        let maskID = c.project.videoTracks.first { $0.isPrivacy }!.clips[0].id
        try apply(c, .holdFrame(clipID: "clip_dummy", range: TimeRange(start: .zero, end: t(3))))
        XCTAssertTrue(c.project.clip(maskID)!.holds.isEmpty)
        XCTAssertEqual(c.project.clip("clip_dummy")!.pictureTime(atTimelineTime: t(1)).seconds, 29.0/30, accuracy: 1e-8)
        let before = try await image(c, media)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        try png(before, "round3-picture-only-hold-before")
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
        try await panelExposure(c, media, at: 1.5, name: "round3-picture-only-hold", encode: true)
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
        try await panelExposure(c, media, at: 1.5, name: "round2-held-before-source", encode: true)
    }

    func testRoundTwoZeroBlurTransferCanPassThePrivacyScan() async throws {
        let (media, c) = try await panelReady()
        let picture = panelPicture(c)
        try apply(c, .addEffect(clipID: picture.id, effect: Effect(id: "fx_zero", type: "blur", params: ["radius": .number(0)])))
        try apply(c, .addTrack(kind: .video, name: "B-roll", index: nil, id: "trk_upper"))
        try apply(c, .moveClips(clipIDs: [picture.id], delta: .zero, toTrackID: "trk_upper"))
        try await panelExposure(c, media, at: 2, name: "round2-zero-blur-transfer", encode: true)
        let skipped = try await scan(c, media, to: 4)
        print("ROUND2 zero-radius source blur: \(skipped.count) privacy problems despite readable email")
        XCTAssertTrue(skipped.isEmpty)
        try apply(c, .removeEffect(clipID: picture.id, effectID: "fx_zero"))
        let detected = try await scan(c, media, to: 4)
        XCTAssertTrue(detected.contains { $0.kind == .privateText }, "removing a no-op effect must reveal the scanner classification bug")
    }

    func testRoundTwoContinuousRollThenMoveExposesBothNeighbours() async throws {
        for edge in ["head", "tail"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            let neighbour = c.project.videoTracks[0].clips.first { edge == "head" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .roll(leftClipID: edge == "head" ? neighbour.id : picture.id, rightClipID: edge == "head" ? picture.id : neighbour.id, delta: t(edge == "head" ? 0.2 : -0.2)))
            let immediate = try await scan(c, media, to: 4)
            XCTAssertTrue(immediate.isEmpty)
            try apply(c, .moveClips(clipIDs: [picture.id], delta: t(4)))
            try await panelExposure(c, media, at: edge == "head" ? 1.1 : 2.9, name: "round2-roll-\(edge)-then-move", encode: edge == "head")
        }
    }

    func testRoundTwoRollAndAdjacentSlideThenSpeedExposeTheTail() async throws {
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
            try await panelExposure(c, media, at: setup == "roll slower" ? 5.1 : 61.0/30, name: "round2-\(name)-then-speed", encode: setup == "roll faster")
        }
    }

    func testRoundTwoNeighbourRippleTrimsExposeProtectedSource() async throws {
        for edge in ["left tail", "right head"] {
            let (media, c) = try await panelReady()
            let neighbour = c.project.videoTracks[0].clips.first { edge == "left tail" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .trim(clipID: neighbour.id, edge: edge == "left tail" ? .end : .start, to: t(edge == "left tail" ? 1.4 : 2.6), ripple: true))
            let name = edge.replacingOccurrences(of: " ", with: "-")
            try await panelExposure(c, media, at: edge == "left tail" ? 1.2 : 3.2, name: "round2-trim-\(name)", encode: edge == "left tail")
        }
    }

    func testRoundTwoNeighbourSlipsExposeProtectedSource() async throws {
        for side in ["left", "right"] {
            let (media, c) = try await panelReady()
            let neighbour = c.project.videoTracks[0].clips.first { side == "left" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .slip(clipID: neighbour.id, delta: t(side == "left" ? 1 : -1)))
            try await panelExposure(c, media, at: side == "left" ? 0.5 : 3.5, name: "round2-slip-\(side)", encode: side == "left")
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
                try await panelExposure(c, media, at: 3.5, name: "round2-raw-duration-frozen", encode: true)
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
                try await panelExposure(c, media, at: field == "freezeFrame" ? 0.75 : 0.5, name: "round2-raw-\(field)-neighbour", encode: field == "speed")
            }
        }
    }

    func testRoundTwoFollowingClipHoldRepeatsPrivateFrameBeyondTheMask() async throws {
        let (media, c) = try await panelReady()
        let right = c.project.videoTracks[0].clips.first { $0.start == t(3) }!
        let before = try await image(c, media, at: 3.2)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        try apply(c, .holdFrame(clipID: right.id, range: TimeRange(start: t(3), end: t(3.5))))
        XCTAssertEqual(c.project.clip(right.id)!.pictureTime(atTimelineTime: t(3.2)).seconds, 89.0/30, accuracy: 1e-8)
        try await panelExposure(c, media, at: 3.2, name: "round2-following-hold", encode: true)
    }
}
