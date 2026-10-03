import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem sync`: how late each file's picture is against its sound.
final class SyncTests: XCTestCase {
    func testItSetsTheCameraTakesAndLeavesTheSoundAlone() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = try h.service.sync(SyncRequest(), context: h.context)
        XCTAssertTrue(before.readableText.contains("med_camera  source/take1-camera.mov  camera  as recorded"), before.readableText)

        let result = try h.service.sync(SyncRequest(delay: t(0.08)), context: h.context)
        XCTAssertEqual(result.applied?.label, "Picture delay 80 ms on 1 file")
        XCTAssertEqual(result.applied?.author, "claude")
        let project = h.service.coordinator.project
        XCTAssertEqual(project.media("med_camera")?.pictureDelay, t(0.08))
        XCTAssertNil(project.media("med_screen")?.pictureDelay, "only camera takes by default")
        XCTAssertEqual(project.allTracks.flatMap(\.clips), APIFixture.project().allTracks.flatMap(\.clips), "no clip moves")
        XCTAssertTrue(result.readableText.contains("camera  80 ms"), result.readableText)
        let media = try await h.service.media(refresh: false).readableText
        XCTAssertTrue(media.contains("picture 80 ms late, shown in sync"), media)

        // The same again changes nothing; 0 puts it back; a file named gets it.
        XCTAssertNil(try h.service.sync(SyncRequest(delay: t(0.08)), context: h.context).applied)
        _ = try h.service.sync(SyncRequest(delay: .zero), context: h.context)
        XCTAssertNil(h.service.coordinator.project.media("med_camera")?.pictureDelay)
        _ = try h.service.sync(SyncRequest(delay: t(0.05), media: ["med_screen"]), context: h.context)
        XCTAssertEqual(h.service.coordinator.project.media("med_screen")?.pictureDelay, t(0.05))

        XCTAssertThrowsError(try h.service.sync(SyncRequest(delay: t(80)), context: h.context)) { error in
            XCTAssertTrue((error as? ServiceError)?.message.contains("80 ms is 0.08") == true, "\(error)")
        }
        XCTAssertThrowsError(try h.service.sync(SyncRequest(delay: t(0.08), media: ["med_music"]), context: h.context))
    }
}

/// `tandem sync` as agents run it.
final class SyncCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentSyncsTheTakeAndSetsTheDefault() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let settings = folder.file("settings.json")
        let env = ["TANDEM_SETTINGS": settings.path]

        let set = try cli.tandem("sync", "80ms", "--default", "--author", "claude", in: folder.url, env: env)
        XCTAssertEqual(set.status, 0, set.stderr)
        XCTAssertTrue(set.stdout.contains("Applied \"Picture delay 80 ms on 1 file\" by claude"), set.stdout)
        XCTAssertTrue(set.stdout.contains("New camera takes get 80 ms"), set.stdout)
        XCTAssertEqual(try ProjectFile.load(from: url).project.media("med_camera")?.pictureDelay, t(0.08))
        XCTAssertEqual(TandemSettings.load(from: settings).cameraPictureDelay, 0.08)

        let bad = try cli.tandem("sync", "soon", in: folder.url, env: env)
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.stderr.contains("isn't a delay"), bad.stderr)
    }
}
