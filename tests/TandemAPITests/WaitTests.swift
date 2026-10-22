import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem transcribe` and `tandem wait`: transcripts on request, and
/// waiting for background work without a sleep loop.
final class TranscribeTests: XCTestCase {
    static let said = Transcript(language: "en", engine: "fake", words: [
        TranscriptWord(text: "Hello", start: t(0.2), end: t(0.5)),
        TranscriptWord(text: "there.", start: t(0.55), end: t(0.9))
    ])

    func testAskingMarksAFileNothingElseTranscribes() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await h.service.transcribe(TranscribeRequest(media: ["med_music"]), context: h.context)
        XCTAssertEqual(result.applied?.label, "Transcribe bed.m4a")
        XCTAssertEqual(result.applied?.author, "claude")
        XCTAssertEqual(h.service.coordinator.project.media("med_music")?.transcribe, true)
        XCTAssertEqual(h.analysis.requests.map(\.kind), [.transcript])
        XCTAssertEqual(h.analysis.requests.first?.priority, .interactive)
        XCTAssertEqual(result.files.map(\.state), ["waiting"])
        XCTAssertTrue(result.readableText.contains("tandem wait transcript --media med_music"), result.readableText)

        // Asking again changes nothing more.
        let again = try await h.service.transcribe(TranscribeRequest(media: ["med_music"]), context: h.context)
        XCTAssertNil(again.applied)
    }

    func testACameraTakeIsJustQueued() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        let result = try await h.service.transcribe(TranscribeRequest(media: ["med_camera"]), context: h.context)
        XCTAssertNil(result.applied, "camera takes are transcribed anyway")
        XCTAssertNil(h.service.coordinator.project.media("med_camera")?.transcribe)
        XCTAssertEqual(h.analysis.requests.map(\.mediaID), ["med_camera"])
    }

    func testFilesAreFoundByPathOrClipAndASilentOneIsRefused() async throws {
        var project = APIFixture.project()
        project.media.append(MediaItem(id: "med_still", path: "graphics/logo.png", kind: .image, role: .graphic, hasVideo: false))
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let byPath = try await h.service.transcribe(TranscribeRequest(media: ["music/bed.m4a"]), context: h.context)
        XCTAssertEqual(byPath.files.map(\.mediaID), ["med_music"])
        let absolute = h.folder.url.appendingPathComponent("broll/servers.mp4").path
        let byAbsolutePath = try await h.service.transcribe(TranscribeRequest(media: [absolute]), context: h.context)
        XCTAssertEqual(byAbsolutePath.files.map(\.mediaID), ["med_broll"])
        let byClip = try await h.service.transcribe(TranscribeRequest(media: ["clip_mus1"]), context: h.context)
        XCTAssertEqual(byClip.files.map(\.mediaID), ["med_music"])

        do {
            _ = try await h.service.transcribe(TranscribeRequest(media: ["med_still"]), context: h.context)
            XCTFail("a still has no sound")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, ServiceError.Code.invalid.rawValue)
            XCTAssertTrue(error.message.contains("has no sound"), error.message)
        }
        do {
            _ = try await h.service.transcribe(TranscribeRequest(media: ["med_nope"]), context: h.context)
            XCTFail("no such media")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, ServiceError.Code.notFound.rawValue)
        }
    }

    func testWaitingGivesTheTranscriptWhenItsMade() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let analysis = h.analysis
        analysis.onRequest = { kind, item in
            guard kind == .transcript else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                analysis.finishTranscript(item.id, TranscribeTests.said)
            }
        }
        let result = try await h.service.transcribe(TranscribeRequest(media: ["med_music"], wait: true, timeout: 10), context: h.context)
        XCTAssertEqual(result.waited?.done, true)
        XCTAssertEqual(result.files.map(\.state), ["ready"])
        XCTAssertEqual(result.files.first?.words, 2)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.readableText.contains("music/bed.m4a: ready, 2 words"), result.readableText)
    }

    func testNoSpeechIsAnAnswerToo() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.finishTranscript("med_broll", Transcript(language: "en", engine: "fake", words: []))
        let result = try await h.service.transcribe(TranscribeRequest(media: ["med_broll"], wait: true, timeout: 5), context: h.context)
        XCTAssertTrue(result.readableText.contains("broll/servers.mp4: ready, no speech"), result.readableText)
    }

    func testTheHeadlessMissingTranscriptMessageSaysHowToMakeOne() throws {
        let h = try ServiceHarness(mode: .headless)
        defer { h.close() }
        do {
            _ = try h.service.transcript(id: "med_music", from: nil, to: nil)
            XCTFail("no transcript yet")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("tandem transcribe med_music"), error.message)
            XCTAssertFalse(error.message.contains("tandem serve"), error.message)
        }
    }

    func testTheHostedMissingTranscriptMessageSaysWhetherAnythingIsMakingIt() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        func message(_ id: String) -> String {
            do {
                _ = try h.service.transcript(id: id, from: nil, to: nil)
                return ""
            } catch {
                return (error as? ServiceError)?.message ?? "\(error)"
            }
        }
        XCTAssertTrue(message("med_camera").contains("tandem wait transcript --media med_camera"), message("med_camera"))
        XCTAssertTrue(message("med_music").contains("tandem transcribe med_music"), message("med_music"))
    }
}

final class WaitTests: XCTestCase {
    func testWaitingForATranscriptReturnsWhenItsReady() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        h.analysis.emit([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.4)])
        let analysis = h.analysis
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            analysis.finishTranscript("med_camera", APIFixture.cameraTranscript)
        }
        let result = try await h.service.wait(WaitRequest(what: .transcript, media: ["med_camera"], timeout: 10))
        XCTAssertTrue(result.done)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.finished.map(\.mediaID), ["med_camera"])
        XCTAssertEqual(result.finished.first?.words, APIFixture.cameraTranscript.words.count)
        XCTAssertGreaterThanOrEqual(h.analysis.neededRequests, 1, "a wait starts the work it waits for")
        XCTAssertTrue(result.readableText.contains("source/take1-camera.mov: ready"), result.readableText)
    }

    func testAllTranscriptsMeansEveryOneTheProjectMakes() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // The camera's is ready; nothing else in the fixture gets one.
        let result = try await h.service.wait(WaitRequest(what: .transcript, timeout: 5))
        XCTAssertTrue(result.done)
        XCTAssertEqual(result.finished.map(\.mediaID), ["med_camera"])
    }

    func testTimingOutSaysWhatsStillGoing() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        h.analysis.emit([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.4)])
        let result = try await h.service.wait(WaitRequest(what: .transcript, media: ["med_camera"], timeout: 0.3))
        XCTAssertFalse(result.done)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.pending.map(\.state), ["running"])
        XCTAssertEqual(result.pending.first?.progress, 0.4)
        XCTAssertTrue(result.readableText.contains("Still going"), result.readableText)
    }

    func testAFailureEndsTheWait() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        h.analysis.emit([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .failed, message: "SpeechAnalyzer doesn't support xx")])
        let result = try await h.service.wait(WaitRequest(what: .transcript, media: ["med_camera"], timeout: 5))
        XCTAssertTrue(result.done)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.finished.first?.state, "failed")
        XCTAssertTrue(result.readableText.contains("SpeechAnalyzer doesn't support xx"), result.readableText)
    }

    func testWaitingForSomethingNothingMakesSaysHowToAsk() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        do {
            _ = try await h.service.wait(WaitRequest(what: .transcript, media: ["med_music"], timeout: 5))
            XCTFail("nothing makes the music's transcript")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, ServiceError.Code.invalid.rawValue)
            XCTAssertTrue(error.message.contains("tandem transcribe med_music"), error.message)
        }
        do {
            _ = try await h.service.wait(WaitRequest(what: .matte, media: ["med_screen"], timeout: 5))
            XCTFail("the screen has no cutout")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("cutout"), error.message)
        }
    }

    func testWaitingForJobsReturnsWhatFinished() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.emit([
            JobStatus(id: "j1", kind: .proxy, mediaID: "med_screen", state: .running, progress: 0.5),
            JobStatus(id: "j2", kind: .loudness, mediaID: "med_music", state: .queued)
        ])
        let analysis = h.analysis
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            analysis.emit([
                JobStatus(id: "j1", kind: .proxy, mediaID: "med_screen", state: .done, progress: 1),
                JobStatus(id: "j2", kind: .loudness, mediaID: "med_music", state: .done, progress: 1)
            ])
        }
        let result = try await h.service.wait(WaitRequest(timeout: 10))
        XCTAssertEqual(result.what, .jobs)
        XCTAssertTrue(result.done)
        XCTAssertEqual(Set(result.finished.map(\.kind)), ["proxy", "loudness"])
        XCTAssertEqual(result.finished.first { $0.kind == "proxy" }?.path, "source/take1-screen.mov")

        // Just one file's jobs.
        h.analysis.emit([JobStatus(id: "j3", kind: .waveform, mediaID: "med_music", state: .running)])
        let one = try await h.service.wait(WaitRequest(what: .jobs, media: ["med_screen"], timeout: 5))
        XCTAssertTrue(one.done, "the music's job isn't waited for")
    }

    func testNoExportsRunningIsDoneStraightAway() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await h.service.wait(WaitRequest(what: .export, timeout: 5))
        XCTAssertTrue(result.done)
        XCTAssertTrue(result.readableText.contains("No exports running"), result.readableText)
    }

    func testProgressLinesFollowTheWaitedWork() {
        let progress = WaitProgress(WaitRequest(what: .transcript, media: ["med_camera"]))
        func jobs(_ list: [JobStatus]) -> ServiceEvent { ServiceEvent(seq: 1, kind: .jobs, jobs: list) }
        XCTAssertEqual(progress.lines(for: jobs([
            JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.12),
            JobStatus(id: "j2", kind: .proxy, mediaID: "med_camera", state: .running, progress: 0.5),
            JobStatus(id: "j3", kind: .transcript, mediaID: "med_music", state: .running, progress: 0.5)
        ])), ["transcript med_camera running 12%"])
        // Small steps are skipped; the next 10% and the end are printed.
        XCTAssertEqual(progress.lines(for: jobs([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.15)])), [])
        XCTAssertEqual(progress.lines(for: jobs([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: 0.25)])), ["transcript med_camera running 25%"])
        XCTAssertEqual(progress.lines(for: jobs([JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .done, progress: 1)])), ["transcript med_camera done"])
    }

    /// A transcript that waits for Bark's model says so, and says when it
    /// goes back to the start to transcribe.
    func testProgressLinesSayWhatALongStageIsAndWhenTheNextStarts() {
        let progress = WaitProgress(WaitRequest(what: .transcript, media: ["med_camera"]))
        func running(_ fraction: Double, _ message: String) -> ServiceEvent {
            ServiceEvent(seq: 1, kind: .jobs, jobs: [JobStatus(id: "j1", kind: .transcript, mediaID: "med_camera", state: .running, progress: fraction, message: message)])
        }
        let downloading = "Downloading Bark 3.0 Pro (1.23 GB, once only), then transcribing"
        XCTAssertEqual(progress.lines(for: running(0.42, downloading)), ["transcript med_camera running 42%: \(downloading)"])
        XCTAssertEqual(progress.lines(for: running(0, "Transcribing with Bark 3.0 Pro")), ["transcript med_camera running 0%: Transcribing with Bark 3.0 Pro"])
        XCTAssertEqual(progress.lines(for: running(0.05, "Transcribing with Bark 3.0 Pro")), [])
    }
}

/// With nothing holding the project, a wait runs the analysis itself and
/// serves the API meanwhile, the way `tandem serve` does.
final class HeadlessWaitTests: XCTestCase {
    func testAHeadlessWaitServesTheProjectWhileItMakesTheTranscript() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let client = ProjectClient(projectURL: url, author: "claude")
        let analysis = FakeAnalysis()
        client.analysis = analysis
        let seen = Seen()
        analysis.onRequest = { kind, item in
            guard kind == .transcript else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                // Mid-wait, the lock says where the API is.
                seen.port = ProjectSession.readLock(for: url)?.port
                analysis.finishTranscript(item.id, TranscribeTests.said)
            }
        }
        let events = Seen()
        let result = try await client.call(TranscribeRequest(media: ["med_music"], wait: true, timeout: 10)) { event in
            if event.kind == .jobs { events.count += 1 }
        }
        XCTAssertTrue(result.ok, result.readableText)
        XCTAssertEqual(result.files.first?.words, 2)
        XCTAssertNotNil(seen.port, "served while it waited")
        XCTAssertGreaterThan(events.count, 0, "progress came through")
        XCTAssertNil(ProjectSession.liveLock(for: url))
        XCTAssertNil(ProjectSession.readLock(for: url), "let go when done")
        XCTAssertEqual(try ProjectFile.load(from: url).project.media("med_music")?.transcribe, true, "the request is saved")
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _port: Int?
        private var _count = 0
        var port: Int? {
            get { lock.withLock { _port } }
            set { lock.withLock { _port = newValue } }
        }
        var count: Int {
            get { lock.withLock { _count } }
            set { lock.withLock { _count = newValue } }
        }
    }
}

/// `tandem transcribe` and `tandem wait` as agents run them, with the real
/// analysis (the fixture's files don't exist, so nothing is transcribed).
final class WaitCLITests: XCTestCase {
    private let cli = CLITests()

    override func setUpWithError() throws {
        try cli.setUpWithError()
    }

    func testTheCommands() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        // Readable, so it's queued rather than failed (it's never made).
        try FileManager.default.createDirectory(at: folder.file("music"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.file("music/bed.m4a"))

        let queued = try cli.tandem("transcribe", "music/bed.m4a", "--no-wait", "--author", "claude", in: folder.url)
        XCTAssertEqual(queued.status, 0, queued.stderr)
        XCTAssertTrue(queued.stdout.contains("Applied \"Transcribe bed.m4a\" by claude"), queued.stdout)
        XCTAssertTrue(queued.stdout.contains("when the app or `tandem serve` opens it"), queued.stdout)
        XCTAssertEqual(try ProjectFile.load(from: url).project.media("med_music")?.transcribe, true)

        // Headless, it waits by default: the file is missing, so that's the answer.
        let made = try cli.tandem("transcribe", "med_broll", in: folder.url)
        XCTAssertEqual(made.status, 1, made.stdout)
        XCTAssertTrue(made.stdout.contains("broll/servers.mp4: failed"), made.stdout)

        let nothing = try cli.tandem("wait", "export", in: folder.url)
        XCTAssertEqual(nothing.status, 0, nothing.stderr)
        XCTAssertTrue(nothing.stdout.contains("No exports running"), nothing.stdout)

        let notMade = try cli.tandem("wait", "transcript", "--media", "med_screen", "--timeout", "5", in: folder.url)
        XCTAssertEqual(notMade.status, 1)
        XCTAssertTrue(notMade.stderr.contains("tandem transcribe med_screen"), notMade.stderr)

        let bad = try cli.tandem("wait", "soon", in: folder.url)
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.stderr.contains("transcript, matte, proxy, jobs or export"), bad.stderr)

        let missing = try cli.tandem("transcript", "med_screen", in: folder.url)
        XCTAssertTrue(missing.stderr.contains("tandem transcribe med_screen"), missing.stderr)
    }
}
