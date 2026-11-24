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
        XCTAssertEqual(FrameRate(1, Int64.max).flicksPerFrame, Int64.max)
        XCTAssertEqual(FrameRate(0, 1).flicksPerFrame, Time.flicksPerSecond)
        XCTAssertEqual(FrameRate(30, 0).flicksPerFrame, Time.flicksPerSecond)
        XCTAssertEqual(FrameRate(Int64.max, 1).flicksPerFrame, 1)
    }

    func testATinyProjectFrameRateIsRefusedNotACrash() throws {
        let c = ProjectCoordinator(project: Project(name: "Slow clock"))
        let patch = EditCommand.updateSettings(patch: .object(["frameRate": .object(["numerator": .number(0), "denominator": .number(1)])]))
        XCTAssertThrowsError(try c.apply(EditBatch(label: "Zero rate", commands: [patch])))
    }
}
