import XCTest
@testable import TandemCrashReports

/// Only the installed release Tandem may report crashes: agents run debug
/// builds, tests and staged copies all day, and none of those should reach
/// Sentry.
final class CrashReportsTests: XCTestCase {
    let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testOnlyTheInstalledAppCounts() {
        XCTAssertTrue(CrashReports.isInstalledApp(bundleURL: URL(fileURLWithPath: "/Users/someone/Applications/Tandem.app"), home: home))
        XCTAssertTrue(CrashReports.isInstalledApp(bundleURL: URL(fileURLWithPath: "/Applications/Tandem.app"), home: home))
        // A copy staged with TANDEM_APP_DIR, and a bare `swift build`
        // binary, whose main bundle is its build folder.
        XCTAssertFalse(CrashReports.isInstalledApp(bundleURL: URL(fileURLWithPath: "/tmp/tandem-test/Tandem.app"), home: home))
        XCTAssertFalse(CrashReports.isInstalledApp(bundleURL: URL(fileURLWithPath: "/Users/someone/dev/tandem/.build/release"), home: home))
        XCTAssertFalse(CrashReports.isInstalledApp(bundleURL: URL(fileURLWithPath: "/Users/someone/Applications/.Tandem.app.staging.123"), home: home))
    }

    func testNeverUnderTestsOrCI() {
        let installed = home.appendingPathComponent("Applications/Tandem.app")
        // This is running under XCTest, so it's off whatever the path.
        XCTAssertFalse(CrashReports.shouldReport(bundleURL: installed, environment: [:]))
        XCTAssertFalse(CrashReports.shouldReport(bundleURL: installed, environment: ["CI": "true"]))
    }

    func testReleaseNameCarriesTheCommit() {
        XCTAssertEqual(
            CrashReports.releaseName(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TandemCommit": "abc1234"]),
            "tandem@0.1.0+abc1234"
        )
        XCTAssertEqual(CrashReports.releaseName(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]), "tandem@0.1.0+1")
    }
}
