import XCTest
@testable import TandemAPI
@testable import TandemCore

/// Telling a Tandem app from a build installed since it started (25 Nov
/// 2026: a five-day-old app refused a project the new build had saved, and
/// `tandem status` only said "open in: nothing else").
final class AppBuildTests: XCTestCase {
    func testAProcessIsStaleWhenItsFileIsNoLongerTheInstalledOne() {
        let old = AppBuild.FileID(device: 1, inode: 10)
        let new = AppBuild.FileID(device: 1, inode: 11)
        XCTAssertTrue(AppBuild.isStale(running: old, installed: new))
        XCTAssertFalse(AppBuild.isStale(running: new, installed: new))
        XCTAssertFalse(AppBuild.isStale(running: nil, installed: new), "unknown proves nothing")
        XCTAssertFalse(AppBuild.isStale(running: old, installed: nil), "nothing installed")
        // This test process runs the file at its own path.
        let own = Bundle.main.executableURL
        XCTAssertNotNil(AppBuild.ownExecutable())
        XCTAssertEqual(AppBuild.ownExecutable(), own.flatMap(AppBuild.fileID))
        XCTAssertEqual(AppBuild.runningExecutable(pid: getpid(), named: own?.lastPathComponent ?? ""), own.flatMap(AppBuild.fileID))
        XCTAssertFalse(AppBuild.isOutdated())
    }

    /// A real process started from a file called tandem-app, which is then
    /// replaced the way build-app.sh does (written anew, then renamed into
    /// place), is found from its path and reads as stale; before, it doesn't.
    func testFindsAnAppProcessAndSeesWhenItsBuildIsReplaced() throws {
        let folder = TempFolder("app-build")
        let executable = folder.file("tandem-app")
        try Self.copySleep(to: executable)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }

        let running = AppBuild.runningApps(executable: executable)
        XCTAssertEqual(running.map(\.pid), [process.processIdentifier])
        let started = try XCTUnwrap(running.first?.started)
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 10)
        XCTAssertEqual(AppBuild.stale(running, installed: AppBuild.fileID(of: executable)), [], "it runs the build that's there")
        XCTAssertNil(AppBuild.staleAppWarning(holder: nil, executable: executable))

        // The new build: a fresh copy renamed over the old path, the way
        // build-app.sh swaps bundles. Its date is set older than the
        // process, as a copy that keeps dates would be: the file is what counts.
        let staged = folder.file(".tandem-app.staging")
        try Self.copySleep(to: staged)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: staged.path)
        XCTAssertEqual(rename(staged.path, executable.path), 0)

        XCTAssertEqual(AppBuild.runningApps(executable: executable).map(\.pid), [process.processIdentifier], "found by the path it was started from")
        let warning = try XCTUnwrap(AppBuild.staleAppWarning(holder: nil, executable: executable))
        XCTAssertTrue(warning.contains("pid \(process.processIdentifier)"), warning)
        XCTAssertTrue(warning.contains("is an older build than the one installed"), warning)
        XCTAssertTrue(warning.contains("saved by a newer Tandem"), warning)
        XCTAssertTrue(warning.contains("`tandem quit-app`"), warning)
        let holding = try XCTUnwrap(AppBuild.staleAppWarning(holder: process.processIdentifier, executable: executable))
        XCTAssertTrue(holding.contains("It has this project open"), holding)

        XCTAssertEqual(AppBuild.runningApps(executable: folder.file("elsewhere/tandem-app")), [], "another install's app isn't this one's")
    }

    /// A stand-in app: /bin/sleep, signed again, since macOS kills a copy
    /// of a system binary that still carries Apple's signature.
    static func copySleep(to url: URL) throws {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: url)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "codesign")
    }

    func testStatusSaysWhenTheAppIsStale() throws {
        let h = try ServiceHarness(mode: .headless)
        defer { h.close() }
        let status = h.service.status()
        let stale = AppBuild.noting(status, route: .headless, projectURL: h.url) { _ in "The Tandem app running now is an older build." }
        XCTAssertEqual(stale.warnings?.last, "The Tandem app running now is an older build.")
        XCTAssertTrue(stale.readableText.contains("open in: nothing else"), stale.readableText)
        XCTAssertTrue(stale.readableText.contains("Warning: The Tandem app running now is an older build."), stale.readableText)

        let fine = AppBuild.noting(status, route: .headless, projectURL: h.url) { _ in nil }
        XCTAssertEqual(fine.warnings, status.warnings, "nothing added when the app is current")

        var held = status
        held.openIn = OwnerInfo(owner: "app", pid: 4242, started: Date(), port: 1)
        var holder: pid_t?
        _ = AppBuild.noting(held, route: .headless, projectURL: h.url) { holder = $0; return nil }
        XCTAssertEqual(holder, 4242, "the app holding the project when status answered is named, so the warning can say it's the one")
    }

    func testAHandbackNothingWillShowSaysSo() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.handback(HandbackRequest(notes: [HandbackNote(at: t(2), name: "The new shot")]), context: h.context)
        let unseen = AppBuild.noting(result, route: .headless, projectURL: h.url) { _ in nil }
        XCTAssertTrue(unseen.readableText.contains("Warning: Nothing has Decision Models.tandem open in the Tandem app"), unseen.readableText)
        XCTAssertTrue(unseen.readableText.contains("If it still says \"nothing else\""), unseen.readableText)

        let seen = AppBuild.noting(result, route: .remote(port: 1, owner: "app", pid: 4242), projectURL: h.url) { _ in nil }
        XCTAssertNil(seen.warnings, "the app has it, and it's current")

        let stale = AppBuild.noting(result, route: .remote(port: 1, owner: "app", pid: 4242), projectURL: h.url) { _ in "older build" }
        XCTAssertEqual(stale.warnings, ["older build"])

        let withdrawn = try h.service.handback(HandbackRequest(notes: []), context: h.context)
        XCTAssertNil(AppBuild.noting(withdrawn, route: .headless, projectURL: h.url) { _ in nil }.warnings, "taking it all back needs no one to see it")

        let listed = try h.service.handback(HandbackRequest(), context: h.context)
        XCTAssertNil(AppBuild.noting(listed, route: .headless, projectURL: h.url) { _ in nil }.warnings, "only handing back needs Mike to see it")
    }

    func testOtherResultsPassThrough() {
        XCTAssertEqual(AppBuild.noting(7, route: .headless, projectURL: URL(fileURLWithPath: "/tmp/x.tandem")) { _ in "older build" }, 7)
    }

    /// What the app does with a project it couldn't open.
    func testTheAppReopensOnlyForAFileFromTheNewerBuild() {
        func choice(newer: Bool = true, outdated: Bool = true, bundle: Bool = true, open: Int = 0, rendering: Bool = false) -> AppBuild.AfterFailedOpen {
            AppBuild.afterFailedOpen(fileIsNewer: newer, outdated: outdated, canReopen: bundle, openProjects: open, rendering: rendering)
        }
        XCTAssertEqual(choice(), .reopen, "nothing else open: just reopen on the new build with it")
        XCTAssertEqual(choice(open: 1), .askToReopen, "his other projects would close and open again")
        XCTAssertEqual(choice(rendering: true), .askToReopen)
        XCTAssertEqual(choice(outdated: false), .explain, "a file from a build that isn't installed: today's message")
        XCTAssertEqual(choice(newer: false), .explain, "some other reason it won't open")
        XCTAssertEqual(choice(bundle: false), .explain, "swift run has no bundle to reopen")
    }

    func testTheAppReopensByItselfOnlyWhenNobodyWouldNotice() {
        func idle(outdated: Bool = true, open: Int = 0, opening: Bool = false, active: Bool = false, upFor: TimeInterval = 600) -> Bool {
            AppBuild.reopensWhileIdle(outdated: outdated, canReopen: true, openProjects: open, opening: opening, active: active, upFor: upFor)
        }
        XCTAssertTrue(idle())
        XCTAssertFalse(idle(outdated: false))
        XCTAssertFalse(idle(open: 1), "a project open: the status bar offers it instead")
        XCTAssertFalse(idle(opening: true))
        XCTAssertFalse(idle(active: true), "Mike is using it")
        XCTAssertFalse(idle(upFor: 5), "just started, so it can never reopen in a loop")
    }

    func testReadsTheSchemaAFileWasSavedIn() throws {
        let folder = TempFolder("app-build-schema")
        let current = try APIFixture.write(to: folder.url)
        XCTAssertEqual(ProjectFile.savedSchemaVersion(at: current), Project.currentSchemaVersion)
        XCTAssertFalse(ProjectFile.isFromNewerTandem(current))

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: current)) as? [String: Any])
        var project = try XCTUnwrap(json["project"] as? [String: Any])
        project["schemaVersion"] = Project.currentSchemaVersion + 1
        json["project"] = project
        let newer = folder.file("Newer.tandem")
        try JSONSerialization.data(withJSONObject: json).write(to: newer)
        XCTAssertEqual(ProjectFile.savedSchemaVersion(at: newer), Project.currentSchemaVersion + 1)
        XCTAssertTrue(ProjectFile.isFromNewerTandem(newer))

        XCTAssertNil(ProjectFile.savedSchemaVersion(at: folder.file("missing.tandem")))
        XCTAssertFalse(ProjectFile.isFromNewerTandem(folder.file("missing.tandem")))
    }
}
