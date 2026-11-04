import AVFoundation
import XCTest
import TandemCore
@testable import TandemRender

/// The scanner reads every frame of the composed timeline, and what it
/// measures is enough for `QualityCheck` to find planted problems.
final class FrameScannerTests: XCTestCase {
    func testReadsEveryFrameAndFindsAFlashAndAGreenScreen() async throws {
        let media = try TestMedia()
        // Grey, one white frame at 15, then a green screen box for frames
        // 40 to 49 over the grey.
        try await media.movie("planted.mov", seconds: 2, draw: { frame, c in
            TestMedia.fill(c, 0.4, 0.4, 0.4)
            if frame == 15 { TestMedia.fill(c, 1, 1, 1) }
            if (40..<50).contains(frame) {
                c.setFillColor(CGColor(srgbRed: 0.05, green: 0.85, blue: 0.1, alpha: 1))
                c.fill(CGRect(x: 40, y: 30, width: 120, height: 80))
            }
        })
        let clip = Clip(id: "clip_p", content: .media(mediaID: "med_p"), start: .zero, duration: t(2))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_p", "planted.mov", seconds: 2)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: .zero, end: t(2))], width: 192)
        XCTAssertEqual(frames.count, 60, "every frame at 30 fps")
        XCTAssertEqual(frames.first?.thumbnail.count, 32 * 18)

        let problems = QualityCheck.frameProblems(frames, in: project)
        XCTAssertEqual(problems.map(\.kind), [.whiteBlock, .unkeyed], "\(problems.map(\.message))")
        let flash = try XCTUnwrap(problems.first)
        XCTAssertEqual(flash.start.seconds, 0.5, accuracy: 0.001)
        XCTAssertEqual(flash.frames, 1)
        let green = try XCTUnwrap(problems.last)
        XCTAssertEqual(green.start.seconds, 40.0 / 30, accuracy: 0.001)
        XCTAssertEqual(green.frames, 10)
        XCTAssertEqual(green.clipIDs, ["clip_p"])
    }

    /// A reader that starts partway through a held frame could stall forever
    /// (the Convex 1.49 release edit: `tandem check` hung silently on 1:00
    /// to 1:10, where a push went between two clips holding their edges).
    /// Whether it does depends on the exact start, so this tries many.
    func testScanningFromInsideAFreezeFrameDoesntStall() async throws {
        let media = try TestMedia()
        try await media.movie("grey.mov", seconds: 3, draw: { _, c in TestMedia.fill(c, 0.5, 0.5, 0.5) })
        let clip = Clip(id: "clip_f", content: .media(mediaID: "med_g"), start: .zero, duration: t(1.7), sourceStart: t(1), freezeFrame: true)
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_g", "grey.mov", seconds: 3)])
        let context = RenderContext(project: project, folder: media.projectFolder)
        for start in [1.335, 1.343, 1.5, 0.5, 0.75, 1.2] {
            let range = TimeRange(start: t(start), end: t(start + 0.1))
            let frames = try await withDeadline(seconds: 30, "reading from \(start)") {
                try await FrameScanner.scan(context, ranges: [range], width: 64)
            }
            XCTAssertFalse(frames.isEmpty, "from \(start)")
            XCTAssertTrue(frames.allSatisfy { $0.time >= range.start }, "the frames read to get there are dropped")
        }
    }

    func testAHeldFrameIsReadFromItsStart() async throws {
        let media = try TestMedia()
        try await media.movie("grey.mov", seconds: 3, draw: { _, c in TestMedia.fill(c, 0.5, 0.5, 0.5) })
        let clips = [
            Clip(id: "clip_a", content: .media(mediaID: "med_g"), start: .zero, duration: t(1)),
            Clip(id: "clip_f", content: .media(mediaID: "med_g"), start: t(1), duration: t(2), sourceStart: t(1), freezeFrame: true),
            Clip(id: "clip_s", content: .media(mediaID: "med_g"), start: t(3), duration: t(2), sourceStart: t(1), speed: 0.5)
        ]
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: clips)], media: [media.item("med_g", "grey.mov", seconds: 3)])
        let built = try await CompositionAssembler.build(RenderContext(project: project, folder: media.projectFolder))
        func start(_ seconds: Double) -> Double {
            ExportPipeline.readStart(t(seconds), composition: built.composition, instructions: built.videoComposition.instructions).seconds
        }
        XCTAssertEqual(start(0.5), 0.5, accuracy: 0.001, "playing normally, it starts where it's asked")
        XCTAssertEqual(start(2.5), 1, accuracy: 0.001, "partway through the frozen frame")
        XCTAssertEqual(start(1), 1, accuracy: 0.001, "already on its start")
        XCTAssertEqual(start(4), 4, accuracy: 0.001, "a slow clip isn't a held frame")
    }

    /// When AVFoundation stalls anyway, the scan says so instead of waiting
    /// forever. Starting inside a held frame, which the scan no longer does,
    /// is a real stall to try it on.
    func testAStalledReaderFailsWithAClearMessage() async throws {
        let media = try TestMedia()
        try await media.movie("grey.mov", seconds: 3, draw: { _, c in TestMedia.fill(c, 0.5, 0.5, 0.5) })
        let clip = Clip(id: "clip_f", content: .media(mediaID: "med_g"), start: .zero, duration: t(1.7), sourceStart: t(1), freezeFrame: true)
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_g", "grey.mov", seconds: 3)])
        var context = RenderContext(project: project, folder: media.projectFolder)
        context.sizeOverride = CGSize(width: 64, height: 36)
        let built = try await CompositionAssembler.build(context)
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let source = Unchecked((built: built, tracks: tracks))
        var stalls = 0
        for start in [1.335, 1.343, 1.5, 0.5, 0.75, 1.2] {
            let range = TimeRange(start: t(start), end: t(start + 0.1))
            do {
                _ = try await withDeadline(seconds: 20, "the stall watch, from \(start)") {
                    try await FrameScanner.read(source.value.built, tracks: source.value.tracks, range: range, scanlines: false, stallLimit: 2, from: range.start)
                }
            } catch {
                XCTAssertTrue("\(error)".contains("stopped handing over frames"), "\(error)")
                XCTAssertTrue("\(error)".contains("\(range.start)"), "says where: \(error)")
                stalls += 1
            }
        }
        try XCTSkipIf(stalls == 0, "AVFoundation didn't stall from any of these starts on this macOS")
    }

    /// The clock is passed in: real sleeps this short are flaky on a busy Mac.
    func testTheStallWatchLeavesAReadThatKeepsGoing() {
        let fired = LockedCount()
        let watch = StallWatch(limit: 1000) { fired.add() }
        defer { watch.stop() }
        watch.tick(at: Date() + 900)
        watch.noteProgress()
        watch.tick(at: Date() + 900)
        XCTAssertFalse(watch.stalled, "each frame starts the wait again")
        watch.tick(at: Date() + 1001)
        XCTAssertTrue(watch.stalled)
        watch.tick(at: Date() + 2001)
        XCTAssertEqual(fired.count, 1, "once")
    }

    /// `body`'s result, or a failure once `seconds` have gone: a stalled
    /// reader blocks its thread for good, so a task group would wait on it.
    private func withDeadline<T: Sendable>(seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = LockedCount()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            Task.detached {
                do {
                    let value = try await body()
                    if once.add() == 1 { continuation.resume(returning: value) }
                } catch {
                    if once.add() == 1 { continuation.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.add() == 1 { continuation.resume(throwing: DeadlineError(what: what)) }
            }
        }
    }

    func testOnlyTheRangesAskedForAreRead() async throws {
        let media = try TestMedia()
        try await media.movie("grey.mov", seconds: 3, draw: { _, c in TestMedia.fill(c, 0.5, 0.5, 0.5) })
        let clip = Clip(id: "clip_g", content: .media(mediaID: "med_g"), start: .zero, duration: t(3))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_g", "grey.mov", seconds: 3)])
        let ranges = [TimeRange(start: t(0.5), end: t(1)), TimeRange(start: t(2), end: t(2.5))]
        let frames = try await FrameScanner.scan(RenderContext(project: project, folder: media.projectFolder), ranges: ranges, width: 128)
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.first?.time.seconds ?? 0, 0.5, accuracy: 0.001)
        XCTAssertTrue(QualityCheck.frameProblems(frames, in: project).isEmpty, "the jump between the two isn't a flicker")
    }

    func testALongStretchIsReadInPiecesSideBySideWithEveryFrameOnce() async throws {
        let media = try TestMedia()
        // Grey for 24 s, with one white frame at 12 s, across the grid
        // the pieces are cut on.
        try await media.movie("long.mov", seconds: 24, draw: { frame, c in
            TestMedia.fill(c, 0.4, 0.4, 0.4)
            if frame == 360 { TestMedia.fill(c, 1, 1, 1) }
        })
        let clip = Clip(id: "clip_l", content: .media(mediaID: "med_l"), start: .zero, duration: t(24))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_l", "long.mov", seconds: 24)])
        let frames = try await FrameScanner.scan(RenderContext(project: project, folder: media.projectFolder), ranges: [TimeRange(start: t(3), end: t(23))], width: 128)
        XCTAssertEqual(frames.count, 600)
        XCTAssertEqual(frames.first?.time.seconds ?? 0, 3, accuracy: 0.001)
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $1.time > $0.time }, "in order, none twice")
        XCTAssertEqual(QualityCheck.frameProblems(frames, in: project).map(\.start.seconds), [12])
    }

    func testPiecesComeBackInOrderWhateverFinishesFirst() async throws {
        let pieces = (0..<7).map { TimeRange(start: t(Double($0) * 10), end: t(Double($0 + 1) * 10)) }
        let joined = try await FrameScanner.inParallel(pieces, limit: 3) { piece -> [Int] in
            let index = Int(piece.start.seconds / 10)
            try await Task.sleep(nanoseconds: UInt64((7 - index) * 3_000_000))
            return [index * 2, index * 2 + 1]
        }
        XCTAssertEqual(joined, Array(0..<14))
    }
}

private struct DeadlineError: Error, CustomStringConvertible {
    var what: String
    var description: String { "\(what) never finished" }
}

private final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    @discardableResult func add() -> Int { lock.withLock { value += 1; return value } }
}

/// Checks scan at utility priority so they give way to Mike's own work;
/// the viewer and exports keep theirs.
final class ScanPriorityTests: XCTestCase {
    func testScansGiveWayToOtherWork() {
        XCTAssertEqual(TandemScanCompositor().queue.qos, .utility)
        XCTAssertEqual(TandemCompositor().queue.qos, .userInitiated)
        XCTAssertEqual(TandemRGBCompositor().queue.qos, .userInitiated)
        XCTAssertEqual(FrameScanner.readerQoS, .utility)
    }

    /// The scan reads through its own compositor, not the viewer's.
    func testTheScanReadsThroughTheScanCompositor() async throws {
        let media = try TestMedia()
        try await media.movie("a.mov", seconds: 1, draw: { _, context in TestMedia.fill(context, 1, 0, 0) })
        let clip = Clip(id: "clip_a", content: .media(mediaID: "med_a"), start: .zero, duration: t(1))
        let project = Project(name: "Scan", settings: ProjectSettings(width: 320, height: 180, frameRate: .fps30),
                              media: [media.item("med_a", "a.mov", seconds: 1)], videoTracks: [Track(kind: .video, name: "V1", clips: [clip])], audioTracks: [])
        let built = try await CompositionAssembler.build(RenderContext(project: project, folder: media.projectFolder))
        XCTAssertTrue(FrameScanner.scanComposition(built).customVideoCompositorClass == TandemScanCompositor.self)
    }
}
