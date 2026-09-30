import Foundation
import XCTest

// Shared CI runners are too slow and jittery for assertions about frame
// timing or how soon background work starts: a 5 ms run loop wait can come
// back a whole frame late, and Vision takes many times longer than on a Mac.
// Tests that make those assertions still run by default on a Mac. They skip
// on CI (GitHub Actions sets CI=true) unless TANDEM_TIMING_TESTS=1.
// TandemMediaTests and TandemAppTests each keep an identical copy.

func skipsTimingSensitiveTests(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["CI"] == "true" && environment["TANDEM_TIMING_TESTS"] != "1"
}

func skipTimingSensitiveTestOnCI() throws {
    try XCTSkipIf(skipsTimingSensitiveTests(), "shared CI runners are too slow for this timing; set TANDEM_TIMING_TESTS=1 to run it")
}
