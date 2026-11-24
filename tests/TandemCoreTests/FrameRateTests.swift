import XCTest
@testable import TandemCore

final class FrameRateTests: XCTestCase {
    func testOrdinaryRatesKeepTheirExactFrameLength() {
        XCTAssertEqual(FrameRate.fps30.flicksPerFrame, 23_520_000)
        XCTAssertEqual(FrameRate(30000, 1001).flicksPerFrame, 23_543_520)
    }

    func testExtremeOrInvalidRatesDoNotTrap() {
        // A 1/20 fps patch crashed the editor mid-batch (24 Nov 2026) before
        // validation could refuse it: 20 s frames overflowed the multiply.
        let slow = FrameRate(Time.flicksPerSecond, Time(seconds: 20).flicks)
        XCTAssertEqual(slow.flicksPerFrame, Time(seconds: 20).flicks)
        XCTAssertEqual(FrameRate(1, Int64.max).flicksPerFrame, Time.flicksPerSecond * 3600, "a frame is at most an hour")
        XCTAssertEqual(FrameRate(0, 1).flicksPerFrame, Time.flicksPerSecond)
        XCTAssertEqual(FrameRate(30, 0).flicksPerFrame, Time.flicksPerSecond)
        XCTAssertEqual(FrameRate(Int64.max, 1).flicksPerFrame, 1)
    }

    func testATinyProjectFrameRateIsRefusedNotACrash() throws {
        let c = ProjectCoordinator(project: Project(name: "Slow clock"))
        let patch = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(0), "denominator": .number(1)])]))
        XCTAssertThrowsError(try c.apply(EditBatch(label: "Zero rate", commands: [patch])))
    }

    func testAnUnusablyFarRateIsRefusedNotACrash() throws {
        // Round-2 review r6: a rate that saturated the frame length still
        // overflowed validation's own time maths.
        let item = MediaItem(id: "med_clip", path: "clip.mov", kind: .video, role: .screen,
                             duration: Time(seconds: 10), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let clip = Clip(id: "clip_one", content: .media(mediaID: item.id), start: .zero, duration: Time(seconds: 5))
        let c = ProjectCoordinator(project: Project(name: "Slow clock", media: [item],
            videoTracks: [Track(id: "trk_v", kind: .video, name: "Screen", clips: [clip])]))
        let tiny = JSONValue.object(["numerator": .number(1), "denominator": .number(1_000_000_000_000)])
        XCTAssertThrowsError(try c.apply(EditBatch(label: "Settings", commands: [.updateSettings(patch: .object(["frameRate": tiny]))])))
        XCTAssertThrowsError(try c.apply(EditBatch(label: "Media", commands: [.updateMedia(mediaID: item.id, patch: .object(["frameRate": tiny]))])))
        XCTAssertEqual(c.project.settings.frameRate, .fps30)
        XCTAssertEqual(c.project.media.first?.frameRate, .fps30)
    }
}
