import XCTest
@testable import TandemCore
@testable import TandemRender

final class SourcePrivacyTimingTests: XCTestCase {
    let media = MediaItem(id: "med_timing", path: "timing.mov", kind: .video, role: .screen, duration: t(4), frameRate: .fps30)

    func testDroppedSamplesExtendProtectionToTheActualDisplayedFrame() {
        let timing = SourcePrivacyTiming.samples([t(29.0 / 30), t(31.0 / 30), t(32.0 / 30)])
        let ranges = timing.expanding([TimeRange(start: t(1), end: t(1.04))], media: media, frame: FrameRate.fps30.frameDuration)
        XCTAssertEqual(timing.source(at: t(1.01), delay: .zero), t(29.0 / 30))
        XCTAssertEqual(timing.source(at: t(0.98), delay: .zero), t(29.0 / 30))
        XCTAssertTrue(ranges.contains { $0.contains(t(29.0 / 30)) })
    }

    func testReadsOutsideTheFilesSamplesStillProtectItsHeldBoundaryFrame() {
        let timing = SourcePrivacyTiming.samples([t(0.77), t(1), t(1.2)])
        for range in [TimeRange(start: .zero, end: t(0.01)), TimeRange(start: t(5), end: t(5.1))] {
            let expanded = timing.expanding([range], media: media, frame: FrameRate.fps30.frameDuration)
            let shown = timing.source(at: range.start, delay: .zero)!
            XCTAssertTrue(expanded.contains { $0.contains(shown) })
        }
    }

    func testAnExactSampleBoundaryDoesNotIncludeTheFollowingFrame() {
        let timing = SourcePrivacyTiming.samples((0..<120).map { Time.frames(Int64($0), at: .fps30) })
        let range = TimeRange(start: t(1), end: t(2))
        XCTAssertEqual(timing.expanding([range], media: media, frame: FrameRate.fps30.frameDuration), [range])
        XCTAssertFalse(range.contains(timing.source(at: t(2), delay: .zero)!))
    }

    func testDuplicateInitialTimestampsCannotExcludeAHeldBoundaryFrame() {
        let timing = SourcePrivacyTiming.samples([t(0.77), t(0.77), t(1)])
        let ranges = timing.expanding([TimeRange(start: .zero, end: t(0.01))], media: media, frame: FrameRate.fps30.frameDuration)
        let shown = timing.source(at: t(0.9), delay: .zero)!
        XCTAssertTrue(ranges.contains { $0.contains(shown) })
    }
}
