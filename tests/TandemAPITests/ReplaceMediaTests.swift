import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
@testable import TandemMedia

/// `tandem media replace`: swapping in a processed copy of a file without
/// moving a clip, and the file's analyses following it (James interview,
/// 30 Oct 2026).
final class ReplaceMediaTests: XCTestCase {
    static let rate = 48_000.0

    /// A mono WAV of a tone at `level`, `seconds` long.
    func writeWAV(_ url: URL, seconds: Double, level: Float) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let count = Int(seconds * Self.rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for n in 0..<count { buffer.floatChannelData![0][n] = level * Float(sin(2 * Double.pi * 220 * Double(n) / Self.rate)) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// A mono WAV of speech-like bursts of noise from one seeded "room":
    /// `skip` seconds into it, `seconds` long, so two calls with different
    /// skips are the same sound starting at different moments.
    func writeSpeech(_ url: URL, skip: Double = 0, seconds: Double, level: Float = 0.3) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state: UInt64 = 0x1234_5678
        func random() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var room = [Float](repeating: 0, count: Int(12 * Self.rate))
        var i = 0
        var smooth: Float = 0
        while i < room.count {
            let burst = Int((0.06 + 0.3 * random()) * Self.rate)
            let gap = Int((0.04 + 0.4 * random()) * Self.rate)
            for j in 0..<burst where i + j < room.count {
                smooth = 0.6 * smooth + 0.4 * Float(random() * 2 - 1)
                room[i + j] = Float(sin(Double.pi * Double(j) / Double(burst))) * smooth
            }
            i += burst + gap
        }
        let first = Int(skip * Self.rate)
        let count = Int(seconds * Self.rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for n in 0..<count { buffer.floatChannelData![0][n] = first + n < room.count ? level * room[first + n] : 0 }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// A 10 s voice placed on the timeline, of speech-like sound that can
    /// be lined up by `SoundSync`.
    func speechHarness() async throws -> ServiceHarness {
        let h = try ServiceHarness()
        let original = h.folder.url.appendingPathComponent("audio/mic.wav")
        try writeSpeech(original, skip: 1, seconds: 10)
        let item = try await MediaScanner.probe(original, folder: h.session.folder, id: "med_voice")
        try h.apply(.addMedia(item: item), .placeMedia(mediaIDs: ["med_voice"], at: t(61), duration: t(5)))
        return h
    }

    func replaceError(_ h: ServiceHarness, _ file: String) async -> String {
        do {
            _ = try await MediaRequest(replace: "med_voice", file: file).run(on: h.service, context: h.context)
            return "replaced"
        } catch {
            return "\(error)"
        }
    }

    func testACopyWithEncoderPaddingAtItsStartIsRefusedSayingTrimTheStart() async throws {
        // ffmpeg kept the 44 ms of priming AVFoundation drops, and the end
        // was trimmed to fit: same length, every word 44 ms out.
        let h = try await speechHarness()
        defer { h.close() }
        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic-clean.wav"), skip: 1 - 0.044, seconds: 10)
        let message = await replaceError(h, "audio/mic-clean.wav")
        XCTAssertTrue(message.contains("44 ms more at its start") && message.contains("Trim 0.0440 s off its start"), message)
        XCTAssertEqual(h.session.coordinator.project.media("med_voice")?.path, "audio/mic.wav")

        // Untrimmed, it's 44 ms longer too; the start is still what's wrong.
        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic-long.wav"), skip: 1 - 0.044, seconds: 10.044)
        let longer = await replaceError(h, "audio/mic-long.wav")
        XCTAssertTrue(longer.contains("off its start"), longer)

        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic-late.wav"), skip: 1.03, seconds: 10)
        let late = await replaceError(h, "audio/mic-late.wav")
        XCTAssertTrue(late.contains("missing 30 ms at its start") && late.contains("adelay=30"), late)
    }

    func testACopyThatStartsTogetherButRunsLongSaysTheEndIsWhereItDiffers() async throws {
        let h = try await speechHarness()
        defer { h.close() }
        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic-tail.wav"), skip: 1, seconds: 10.1)
        let message = await replaceError(h, "audio/mic-tail.wav")
        XCTAssertTrue(message.contains("the difference is at the end: trim 0.1000 s at its end"), message)

        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic-same.wav"), skip: 1, seconds: 10, level: 0.1)
        let result = try await MediaRequest(replace: "med_voice", file: "audio/mic-same.wav").run(on: h.service, context: h.context)
        XCTAssertEqual(result.replaced?.applied.warnings, [], "lined up by sound, so nothing to check")
    }

    func testAFileProcessedInPlaceIsTakenAsNew() async throws {
        let h = try await speechHarness()
        defer { h.close() }
        let old = try XCTUnwrap(h.session.coordinator.project.media("med_voice"))
        let same = await replaceError(h, "audio/mic.wav")
        XCTAssertTrue(same.contains("hasn't changed"), same)

        try writeSpeech(h.folder.url.appendingPathComponent("audio/mic.wav"), skip: 1, seconds: 10, level: 0.1)
        _ = try await MediaRequest(replace: "med_voice", file: "audio/mic.wav").run(on: h.service, context: h.context)
        let item = try XCTUnwrap(h.session.coordinator.project.media("med_voice"))
        XCTAssertEqual(item.path, "audio/mic.wav")
        XCTAssertNotEqual(item.fingerprint, old.fingerprint, "its analyses are made again")
        XCTAssertEqual(item.replaces, old.replaces, "it doesn't hide itself from scans")
    }

    /// The fixture with a 4 s voice file placed on the timeline.
    func harness() async throws -> (ServiceHarness, URL) {
        let h = try ServiceHarness()
        let original = h.folder.url.appendingPathComponent("audio/take1.wav")
        try writeWAV(original, seconds: 4, level: 0.3)
        let item = try await MediaScanner.probe(original, folder: h.session.folder, id: "med_voice")
        try h.apply(.addMedia(item: item), .placeMedia(mediaIDs: ["med_voice"], at: t(61), duration: t(2)))
        return (h, original)
    }

    func testReplaceSwapsTheFileAndItsFingerprint() async throws {
        let (h, _) = try await harness()
        defer { h.close() }
        let old = try XCTUnwrap(h.session.coordinator.project.media("med_voice"))
        let clipsBefore = h.session.coordinator.project.allTracks.flatMap(\.clips).filter { $0.mediaID == "med_voice" }
        let clean = h.folder.url.appendingPathComponent("audio/take1-clean.wav")
        try writeWAV(clean, seconds: 4, level: 0.1)

        let result = try await MediaRequest(replace: "med_voice", file: "audio/take1-clean.wav").run(on: h.service, context: h.context)
        let item = try XCTUnwrap(h.session.coordinator.project.media("med_voice"))
        XCTAssertEqual(item.path, "audio/take1-clean.wav")
        XCTAssertNotNil(item.fingerprint)
        XCTAssertNotEqual(item.fingerprint, old.fingerprint, "analyses are keyed on the new file")
        XCTAssertEqual(h.session.coordinator.project.allTracks.flatMap(\.clips).filter { $0.mediaID == "med_voice" }, clipsBefore, "no clip moves")
        let replaced = try XCTUnwrap(result.replaced)
        XCTAssertEqual(replaced.clips, 1)
        XCTAssertEqual(item.replaces, ["audio/take1.wav"])
        let rescan = try await h.session.refreshMedia()
        XCTAssertEqual(rescan, [], "the old file isn't added back as new media")
        XCTAssertTrue(result.readableText.contains("plays audio/take1-clean.wav now"), result.readableText)
    }

    func testReplaceRefusesAFileOfAnotherLength() async throws {
        let (h, _) = try await harness()
        defer { h.close() }
        let longer = h.folder.url.appendingPathComponent("audio/take1-long.wav")
        try writeWAV(longer, seconds: 4.2, level: 0.1)
        await assertServiceErrorAsync(.invalid) {
            _ = try await MediaRequest(replace: "med_voice", file: longer.path).run(on: h.service, context: h.context)
        }
        XCTAssertEqual(h.session.coordinator.project.media("med_voice")?.path, "audio/take1.wav")
    }

    func testReplaceAcceptsLessThanAFrameOfDifference() async throws {
        let (h, _) = try await harness()
        defer { h.close() }
        let close = h.folder.url.appendingPathComponent("audio/take1-close.wav")
        try writeWAV(close, seconds: 4.01, level: 0.1)
        _ = try await MediaRequest(replace: "med_voice", file: "audio/take1-close.wav").run(on: h.service, context: h.context)
        XCTAssertEqual(h.session.coordinator.project.media("med_voice")?.path, "audio/take1-close.wav")
    }

    func testRefreshThenReplaceLeavesOneItemForTheFile() async throws {
        let (h, _) = try await harness()
        defer { h.close() }
        let clean = h.folder.url.appendingPathComponent("audio/take1-clean.wav")
        try writeWAV(clean, seconds: 4, level: 0.1)
        // The scan gets there first and adds the file as media of its own.
        let added = try await h.session.refreshMedia()
        XCTAssertEqual(added.count, 1)
        _ = try await MediaRequest(replace: "med_voice", file: "audio/take1-clean.wav").run(on: h.service, context: h.context)
        XCTAssertEqual(h.session.coordinator.project.media.filter { $0.path == "audio/take1-clean.wav" }.map(\.id), ["med_voice"])
        // And a later scan doesn't add it again.
        let again = try await h.session.refreshMedia()
        XCTAssertEqual(again, [])
    }

    func testAScanProbesMediaRepointedWithoutAFingerprint() async throws {
        let (h, _) = try await harness()
        defer { h.close() }
        let clean = h.folder.url.appendingPathComponent("audio/take1-clean.wav")
        try writeWAV(clean, seconds: 4, level: 0.1)
        let before = h.session.coordinator.project
        try h.apply(.updateMedia(mediaID: "med_voice", patch: .object(["path": .string("audio/take1-clean.wav")])))
        XCTAssertNil(h.session.coordinator.project.media("med_voice")?.fingerprint)
        XCTAssertTrue(ProjectSession.repointed(from: before, to: h.session.coordinator.project), "a watching session scans")
        let added = try await h.session.refreshMedia()
        XCTAssertEqual(added, [], "the file is med_voice's, not a new take")
        let print = try XCTUnwrap(h.session.coordinator.project.media("med_voice")?.fingerprint)
        XCTAssertEqual(print, try Fingerprint.compute(for: clean).description)
    }

    func testTheScanKeepsTheFingerprintOfAFileItFollowedToANewName() throws {
        let folder = TempFolder()
        let projectFolder = ProjectFolder(root: folder.url)
        let item = MediaItem(id: "med_a", path: "a.wav", kind: .audio, role: .other, duration: t(4), hasAudio: true, fingerprint: "1-2-x")
        var project = Project(id: "prj", name: "P")
        project.media = [item]
        var renamed = item
        renamed.path = "b.wav"
        let (commands, _) = ProjectSession.refreshCommands([renamed], scannedFrom: project, into: project, folder: projectFolder)
        guard case .updateMedia(_, .object(let patch)) = try XCTUnwrap(commands.first) else { return XCTFail("\(commands)") }
        XCTAssertEqual(patch["fingerprint"], .string("1-2-x"))
    }
}

extension ReplaceMediaTests {
    /// A byte-identical copy with the same date has the same fingerprint;
    /// the scan's copy of it must still go just once.
    func testAnIdenticalCopyAScanAddedIsReplacedCleanly() async throws {
        let (h, original) = try await harness()
        defer { h.close() }
        let copy = h.folder.url.appendingPathComponent("audio/take1-copy.wav")
        try FileManager.default.copyItem(at: original, to: copy)
        let date = try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate]
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: copy.path)
        let added = try await h.session.refreshMedia()
        XCTAssertEqual(added.count, 1)
        _ = try await MediaRequest(replace: "med_voice", file: "audio/take1-copy.wav").run(on: h.service, context: h.context)
        XCTAssertEqual(h.session.coordinator.project.media.filter { $0.path == "audio/take1-copy.wav" }.map(\.id), ["med_voice"])
    }
}
