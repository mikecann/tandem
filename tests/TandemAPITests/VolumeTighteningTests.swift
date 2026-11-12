import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tighten --filmora`: cutting by volume the way Mike's old Filmora silence
/// detection did, which he picked by ear over the transcript's rules.
final class VolumeTighteningTests: XCTestCase {
    private static func t(_ seconds: Double) -> Time { Time(seconds: seconds) }
    private let rate = FrameRate(30, 1)

    func testASilenceIsEveryFrameUnderTheThresholdForTheMinimum() {
        // 5 ms frames: loud, 0.6 s quiet, loud, 0.3 s quiet, loud, nothing playing.
        let frames: [Float?] = Array(repeating: -10, count: 10) + Array(repeating: -50, count: 120)
            + Array(repeating: -10, count: 10) + Array(repeating: -50, count: 60)
            + Array(repeating: -10, count: 10) + Array(repeating: nil, count: 200)
        let found = VolumeTightening.silences(frames, start: 1, frame: 0.005, threshold: -35, minimum: 0.5)
        XCTAssertEqual(found.count, 1, "the 0.3 s one is under the minimum, and where nothing plays isn't silent")
        XCTAssertEqual(found[0].lowerBound, 1.05, accuracy: 1e-9)
        XCTAssertEqual(found[0].upperBound, 1.65, accuracy: 1e-9)
    }

    func testTheCutKeepsTheBufferAtEachEndOnWholeFrames() throws {
        let end = Self.t(60)
        let cut = try XCTUnwrap(VolumeTightening.cut(in: 3.0...4.0, buffer: 0.4, timelineEnd: end, rate: rate))
        XCTAssertEqual(cut.start.seconds, 3.4, accuracy: 1e-6)
        XCTAssertEqual(cut.end.seconds, 3.6, accuracy: 1e-6)
        // Off a frame, it rounds inwards: more of the silence kept, never less.
        let off = try XCTUnwrap(VolumeTightening.cut(in: 3.01...4.01, buffer: 0.4, timelineEnd: end, rate: rate))
        XCTAssertGreaterThanOrEqual(off.start.seconds, 3.41 - 1e-9)
        XCTAssertLessThanOrEqual(off.end.seconds, 3.61 + 1e-9)
        // Under 0.8 s nothing's left to cut; the timeline's own ends go to the edge.
        XCTAssertNil(VolumeTightening.cut(in: 3.0...3.8, buffer: 0.4, timelineEnd: end, rate: rate))
        XCTAssertEqual(VolumeTightening.cut(in: 0...1.0, buffer: 0.4, timelineEnd: end, rate: rate)?.start, .zero)
        XCTAssertEqual(VolumeTightening.cut(in: 58...60, buffer: 0.4, timelineEnd: end, rate: rate)?.end, end)
        // A 29.97 fps timeline ending off the 5 ms grid: the levels stop at
        // the last whole frame, and that still counts as the end.
        let ntsc = FrameRate(30000, 1001)
        let ntscEnd = Time.frames(1000, at: ntsc)
        XCTAssertEqual(VolumeTightening.cut(in: 30...33.365, buffer: 0.4, timelineEnd: ntscEnd, rate: ntsc)?.end, ntscEnd)
    }

    /// The fixture's voice track plays file 0-30 at 0-30 and file 32-62 at
    /// 30-60. Tones (loud) and a quiet noise (-40 dB) in file time.
    private func harness() throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.write(to: h.folder.file("source/take1-camera.wav"), length: 64, loud: [
            (1.0, 3.0), (4.0, 6.0), (6.6, 8.0), (8.3, 9.0), (12.0, 29.0), (40.0, 50.0)
        ], quiet: [(10.0, 10.5)])
        return h
    }

    func testCutsEverySilenceOverTheMinimumDownToTheBufferEachSide() async throws {
        let h = try harness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(filmora: true), context: h.context)
        // 0-1 at the timeline's start goes to the edge; 3-4 keeps 0.4 s
        // each side; 6-6.6 and 8-8.3 are too short; the quiet noise in 9-12
        // counts as silence; 29-30 and file 32-40 are one silence across the
        // two clips (29-38 on the timeline); the end goes to the edge. Each
        // edge may sit a frame further in (more kept), never further out.
        let expected: [(Double, Double)] = [(0, 0.6), (3.4, 3.6), (9.4, 11.6), (29.4, 37.6), (48.4, 60)]
        XCTAssertEqual(plan.cuts.count, expected.count, plan.readableText)
        for (cut, (start, end)) in zip(plan.cuts, expected) {
            XCTAssertGreaterThanOrEqual(cut.cut.start.seconds, start - 1e-6, plan.readableText)
            XCTAssertLessThanOrEqual(cut.cut.start.seconds, start + 0.034, plan.readableText)
            XCTAssertLessThanOrEqual(cut.cut.end.seconds, end + 1e-6, plan.readableText)
            XCTAssertGreaterThanOrEqual(cut.cut.end.seconds, end - 0.034, plan.readableText)
        }
        XCTAssertEqual(plan.buffer, Self.t(0.4))
        XCTAssertTrue(plan.readableText.contains("as Filmora did"), plan.readableText)

        // A lower threshold hears the quiet noise, so 9-12 is two silences.
        let strict = try await h.service.tighten(TightenRequest(filmora: true, threshold: -45), context: h.context)
        XCTAssertEqual(strict.cuts.filter { $0.cut.start.seconds > 9 && $0.cut.end.seconds < 12 }.count, 2, strict.readableText)
    }

    func testProtectFromAndToAndApply() async throws {
        let h = try harness()
        defer { h.close() }
        let kept = try await h.service.tighten(TightenRequest(filmora: true, protect: [Self.t(10)]), context: h.context)
        XCTAssertFalse(kept.cuts.contains { $0.cut.start.seconds > 9 && $0.cut.end.seconds < 12 })
        XCTAssertEqual(kept.protected.count, 1)

        // A silence running into `from` keeps its buffer there.
        let bounded = try await h.service.tighten(TightenRequest(filmora: true, from: Self.t(10), to: Self.t(20)), context: h.context)
        XCTAssertEqual(bounded.cuts.count, 1, bounded.readableText)
        XCTAssertEqual(bounded.cuts[0].cut.start.seconds, 10.4, accuracy: 0.001)
        XCTAssertEqual(bounded.cuts[0].cut.end.seconds, 11.6, accuracy: 0.034)

        let applied = try await h.service.tighten(TightenRequest(filmora: true, apply: true), context: h.context)
        XCTAssertNotNil(applied.applied)
        let removed = applied.cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        XCTAssertEqual(h.service.coordinator.project.duration.seconds, 60 - removed, accuracy: 0.001)
        XCTAssertEqual(removed, 0.6 + 0.2 + 2.2 + 8.2 + 11.6, accuracy: 5 * 0.034)
    }

    func testTranscriptOptionsAreRefused() async throws {
        let h = try harness()
        defer { h.close() }
        do {
            _ = try await h.service.tighten(TightenRequest(sentence: 0.4, filmora: true), context: h.context)
            XCTFail("sentence and filmora together should be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("sentence"), error.message)
        }
    }

    static func write(to url: URL, length: Double, loud: [(Double, Double)], quiet: [(Double, Double)]) throws {
        let rate = 32_000.0
        let count = Int(length * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        for i in 0..<count { data[i] = 0 }
        func fill(_ spans: [(Double, Double)], amplitude: Float) {
            for (start, end) in spans {
                for i in Int(start * rate)..<min(count, Int(end * rate)) {
                    data[i] = amplitude * Float(sin(2 * .pi * 220 * Double(i) / rate))
                }
            }
        }
        fill(loud, amplitude: 0.3)
        fill(quiet, amplitude: 0.008) // about -42 dB peak
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
