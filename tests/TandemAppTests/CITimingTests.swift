import XCTest

final class CITimingTests: XCTestCase {
    func testTimingTestsRunOnAMac() {
        XCTAssertFalse(skipsTimingSensitiveTests(environment: [:]))
        XCTAssertFalse(skipsTimingSensitiveTests(environment: ["CI": "false"]))
    }

    func testTimingTestsSkipOnCI() {
        XCTAssertTrue(skipsTimingSensitiveTests(environment: ["CI": "true"]))
    }

    func testTheOptInRunsThemOnCIToo() {
        XCTAssertFalse(skipsTimingSensitiveTests(environment: ["CI": "true", "TANDEM_TIMING_TESTS": "1"]))
    }
}
