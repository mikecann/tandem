import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem cut` through the service: phrases and ranges taken out of the
/// take pause to pause, judged clean by `check --cuts` afterwards.
final class CutAPITests: XCTestCase {
    /// The camera's sound (file time = timeline time in the first piece):
    /// "This is fine. [as I said] we go on." with pauses round "as I said",
    /// "do that [because of] to keep." said without a break, and "fine."
    /// again on its own at 25.
    static let speech: [(Double, Double)] = [(10.0, 11.0), (11.5, 12.2), (12.7, 13.6), (20.0, 22.0), (25.0, 25.5)]
    static let transcript = Transcript(language: "en", engine: "fake", words: [
        TranscriptWord(text: "This", start: t(10.0), end: t(10.4)),
        TranscriptWord(text: "is", start: t(10.45), end: t(10.6)),
        TranscriptWord(text: "fine.", start: t(10.65), end: t(11.0)),
        TranscriptWord(text: "as", start: t(11.5), end: t(11.7)),
        TranscriptWord(text: "I", start: t(11.72), end: t(11.8)),
        TranscriptWord(text: "said", start: t(11.85), end: t(12.2)),
        TranscriptWord(text: "we", start: t(12.7), end: t(12.9)),
        TranscriptWord(text: "go", start: t(12.95), end: t(13.2)),
        TranscriptWord(text: "on.", start: t(13.25), end: t(13.6)),
        TranscriptWord(text: "do", start: t(20.0), end: t(20.3)),
        TranscriptWord(text: "that", start: t(20.35), end: t(20.7)),
        TranscriptWord(text: "because", start: t(20.75), end: t(21.1)),
        TranscriptWord(text: "of", start: t(21.15), end: t(21.3)),
        TranscriptWord(text: "to", start: t(21.35), end: t(21.5)),
        TranscriptWord(text: "keep.", start: t(21.55), end: t(22.0)),
        TranscriptWord(text: "fine.", start: t(25.0), end: t(25.5))
    ])

    private func harness() throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        h.analysis.transcripts["med_camera"] = Self.transcript
        return h
    }

    /// Room noise with a buzz of harmonics where `words` says, as
    /// CheckAPITests writes its voice.
    static func writeVoice(to url: URL, length: Double, words: [(Double, Double)]) throws {
        let rate = 16_000.0
        let count = Int(length * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        var seed: UInt32 = 7
        var rumble: Float = 0
        for i in 0..<count {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            rumble += (Float(Int32(bitPattern: seed)) / Float(Int32.max) - rumble) * 0.04
            data[i] = rumble * 0.03
        }
        for (start, end) in words {
            let from = Int(start * rate), to = Int(end * rate)
            for i in from..<to {
                let t = Double(i) / rate
                let fade = min(1, Double(i - from) / 80, Double(to - i) / 80)
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                data[i] += Float(buzz * 0.08 * fade)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    func testAPhraseIsCutPauseToPauseAndAFillerInRunningSpeechIsLeftIn() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let revision = h.service.coordinator.revision
        let plan = try await CutRequest(remove: [CutTarget(phrase: "as I said"), CutTarget(phrase: "because of")]).run(on: h.service, context: h.context)

        XCTAssertEqual(plan.cuts.map(\.status), [.cut, .kept])
        let cut = try XCTUnwrap(plan.cuts[0].cut)
        XCTAssertEqual(plan.cuts[0].text, "as I said")
        XCTAssertEqual(plan.cuts[0].before, "This is fine.")
        // In the pause after "fine." and the one before "we", on frames,
        // leaving a sentence's 0.4 s between them.
        XCTAssertTrue((11.0...11.5).contains(cut.start.seconds), "\(cut)")
        XCTAssertTrue((12.2...12.7).contains(cut.end.seconds), "\(cut)")
        XCTAssertEqual(cut.start, cut.start.roundedToFrame(.fps30))
        XCTAssertEqual(cut.end, cut.end.roundedToFrame(.fps30))
        let kept = try XCTUnwrap(plan.cuts[0].keptBefore) + XCTUnwrap(plan.cuts[0].keptAfter)
        XCTAssertEqual(kept.seconds, 0.4, accuracy: 0.07)
        XCTAssertEqual(plan.cuts[0].startEdge?.verdict, .clean)
        XCTAssertEqual(plan.cuts[0].endEdge?.verdict, .clean)
        XCTAssertGreaterThan(try XCTUnwrap(plan.cuts[0].startEdge?.margin), 15)

        XCTAssertEqual(plan.cuts[1].problem, .fluent)
        XCTAssertNil(plan.cuts[1].cut)
        XCTAssertTrue(try XCTUnwrap(plan.cuts[1].reason).contains("no pause between it and \"that\""), plan.cuts[1].reason ?? "")

        XCTAssertEqual(plan.commands, [.cutRanges(ranges: [cut], trackIDs: nil)])
        XCTAssertEqual(plan.removed, cut.duration)
        XCTAssertNil(plan.applied)
        let text = plan.readableText
        XCTAssertTrue(text.hasPrefix("Cut 1 stretch pause to pause (dry run, revision \(revision)), removing "), text)
        XCTAssertTrue(text.contains("\"as I said\"  ...This is fine. | we go on....  keeps "), text)
        XCTAssertTrue(text.contains("Left in:\n  00:20.750-00:21.300  \"because of\": no pause between it and \"that\""), text)
        XCTAssertTrue(text.contains("Run again with --apply"), text)

        // The dry run changed nothing.
        XCTAssertEqual(h.service.coordinator.revision, revision)
        XCTAssertEqual(h.service.coordinator.project, before)

        let applied = try await CutRequest(remove: [CutTarget(phrase: "as I said"), CutTarget(phrase: "because of")], apply: true)
            .run(on: h.service, context: h.context)
        XCTAssertEqual(applied.applied?.label, "Cut \"as I said\" pause to pause")
        XCTAssertEqual(h.service.coordinator.revision, revision + 1)
        XCTAssertEqual(h.service.coordinator.project.duration, before.duration - cut.duration)
        let search = try h.service.search(phrase: "as I said", limit: nil)
        XCTAssertTrue(search.hits.isEmpty, "\(search.hits)")

        // check --cuts finds nothing clipped at the new join.
        let check = try await CheckRequest(from: t(5), to: t(20), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.ok, "\(check.problems)")
        XCTAssertTrue(check.notes.isEmpty, "\(check.notes)")
        XCTAssertGreaterThan(check.cuts ?? 0, 0)

        // One undo puts it back.
        XCTAssertNotNil(h.service.coordinator.undo())
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testSeveralStretchesAreOneUndoStep() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let result = try await CutRequest(
            remove: [CutTarget(phrase: "fine", at: t(25)), CutTarget(phrase: "as I said")], apply: true, label: "Tidy"
        ).run(on: h.service, context: h.context)
        XCTAssertEqual(result.cuts.map(\.status), [.cut, .cut])
        // The second "fine.", with 3 s of silence before it and after:
        // the join keeps a sentence's 0.4 s of it, as tighten would.
        let fine = try XCTUnwrap(result.cuts[0].cut)
        XCTAssertTrue((22.0...22.3).contains(fine.start.seconds), "\(fine)")
        XCTAssertGreaterThan(fine.end.seconds, 25.5)
        XCTAssertEqual(result.cuts[0].text, "fine.")
        guard case .cutRanges(let ranges, nil) = try XCTUnwrap(result.commands.first) else { return XCTFail("\(result.commands)") }
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(result.applied?.label, "Tidy")
        XCTAssertEqual(h.service.coordinator.project.duration, before.duration - result.removed)
        // The voice and the camera lose the same time.
        let project = h.service.coordinator.project
        XCTAssertEqual(project.clip("clip_cam2")?.start, project.clip("clip_voc2")?.start)
        XCTAssertNotNil(h.service.coordinator.undo())
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testAPhraseSaidTwiceNeedsAt() async throws {
        let h = try harness()
        defer { h.close() }
        do {
            _ = try await CutRequest(remove: [CutTarget(phrase: "fine")]).run(on: h.service, context: h.context)
            XCTFail("two matches")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "badRequest")
            XCTAssertTrue(error.message.contains("is said 2 times, at 00:10.650, 00:25.000"), error.message)
        }
        do {
            _ = try await CutRequest(remove: [CutTarget(phrase: "not said")]).run(on: h.service, context: h.context)
            XCTFail("no match")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
        }
        let range = try await CutRequest(remove: [CutTarget(start: t(11.6), end: t(12.1))]).run(on: h.service, context: h.context)
        XCTAssertEqual(range.cuts.first?.status, .cut, "a range is planned from its words like a phrase")
        XCTAssertEqual(range.cuts.first?.text, "as I said")
    }

    /// A take whose Voice track plays `clips` of the camera's file, which
    /// is `length` long with sound where `speech` says.
    private func harness(voice clips: [Clip], length: Double, speech: [(Double, Double)], words: [(String, Double, Double)]) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.media[0].duration = t(length)
        project.audioTracks[0].clips = clips
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: length, words: speech)
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: words.map {
            TranscriptWord(text: $0.0, start: t($0.1), end: t($0.2))
        })
        return h
    }

    private func voice(_ id: String, start: Double, duration: Double, from source: Double, speed: Double = 1) -> Clip {
        Clip(id: id, name: "take1-camera", content: .media(mediaID: "med_camera"), start: t(start), duration: t(duration), sourceStart: t(source), speed: speed)
    }

    func testAnEdgeIsNeverPlacedInAPauseItsClipDoesntPlay() async throws {
        // The first clip plays the file to 5, in running speech, and the
        // file's next pause (6 to 6.5) is after that, where the second clip
        // plays file time 100 on. A false start from 4.5 can't go there: on
        // the timeline it's in the middle of "beta".
        let h = try harness(
            voice: [voice("clip_a", start: 0, duration: 5, from: 0), voice("clip_b", start: 5, duration: 10, from: 100)],
            length: 110, speech: [(3.0, 6.0), (6.5, 7.5), (100.0, 102.9), (103.5, 105.0)],
            words: [
                ("one", 3.0, 3.5), ("two", 3.5, 4.0), ("three", 4.0, 4.5), ("four", 4.5, 5.0), ("five", 5.0, 5.5), ("six", 5.5, 6.0),
                ("seven", 6.5, 7.5), ("alpha", 100.0, 101.0), ("beta", 101.0, 102.0), ("gamma", 102.0, 102.9), ("delta", 103.5, 105.0)
            ]
        )
        defer { h.close() }
        let plan = try await CutRequest(remove: [CutTarget(start: t(4.5), end: t(8))]).run(on: h.service, context: h.context)
        let stretch = try XCTUnwrap(plan.cuts.first)
        if let cut = stretch.cut, stretch.status == .cut {
            XCTAssertLessThanOrEqual(cut.start.seconds, 5, "the start is in the first clip: \(cut)")
        }
        XCTAssertEqual(stretch.status, .kept)
        XCTAssertEqual(stretch.problem, .fluent)
        XCTAssertEqual(stretch.problemEdge, .start)
        XCTAssertTrue(plan.commands.isEmpty)
    }

    func testClipsOfOneFilePlayedOutOfOrder() async throws {
        // The timeline plays file time 100 to 105, then 0 to 5. Cutting from
        // timeline 3 to 5.9 starts at file time 103 and ends at 0.9: earlier
        // in the file, but later on the timeline.
        let h = try harness(
            voice: [voice("clip_a", start: 0, duration: 5, from: 100), voice("clip_b", start: 5, duration: 5, from: 0)],
            length: 110, speech: [(101.0, 102.6), (103.0, 104.8), (0.2, 0.9), (1.3, 3.0)],
            words: [
                ("this", 101.0, 101.5), ("is", 101.5, 102.0), ("fine.", 102.0, 102.6), ("one", 103.0, 103.9), ("two", 103.9, 104.8),
                ("three", 0.2, 0.9), ("we", 1.3, 1.8), ("go", 1.8, 2.4), ("on.", 2.4, 3.0)
            ]
        )
        defer { h.close() }
        let plan = try await CutRequest(remove: [CutTarget(start: t(3), end: t(5.9))]).run(on: h.service, context: h.context)
        let stretch = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(stretch.status, .cut, stretch.reason ?? "")
        XCTAssertEqual(stretch.text, "one two three")
        let cut = try XCTUnwrap(stretch.cut)
        XCTAssertTrue((2.6...3.0).contains(cut.start.seconds), "\(cut)")
        XCTAssertTrue((5.9...6.3).contains(cut.end.seconds), "\(cut)")
    }

    func testTheKeptPauseIsTimelineSecondsOnAFastClip() async throws {
        // The first piece plays at 2x: "fine." at file time 25 is at 12.5,
        // and the 3 s of silence before it plays in 1.5 s. The join keeps a
        // sentence's 0.4 s on the timeline, 0.2 s of it after "keep." (file
        // 22.0, timeline 11.0), which is 0.4 s of the file.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.audioTracks[0].clips[0].speed = 2
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        h.analysis.transcripts["med_camera"] = Self.transcript

        let plan = try await CutRequest(remove: [CutTarget(phrase: "fine", at: t(12.5))]).run(on: h.service, context: h.context)
        let stretch = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(stretch.status, .cut, stretch.reason ?? "")
        let cut = try XCTUnwrap(stretch.cut)
        XCTAssertEqual(cut.start.seconds, 11.2, accuracy: 0.02, "\(cut)")
        XCTAssertEqual(try XCTUnwrap(stretch.keptBefore).seconds, 0.2, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(stretch.mediaStart).seconds, 22.4, accuracy: 0.04)
    }

    func testOverlappingMatchesOfAPhraseNeedAt() async throws {
        // "very very very": "very very" is said twice, starting on the first
        // "very" and on the second.
        let h = try harness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: Self.transcript.words + [
            TranscriptWord(text: "very", start: t(40.0), end: t(40.3)),
            TranscriptWord(text: "very", start: t(40.35), end: t(40.6)),
            TranscriptWord(text: "very", start: t(40.65), end: t(40.9))
        ])
        do {
            _ = try await CutRequest(remove: [CutTarget(phrase: "very very")]).run(on: h.service, context: h.context)
            XCTFail("two overlapping matches")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "badRequest")
            XCTAssertTrue(error.message.contains("is said 2 times, at 00:38.000, 00:38.350"), error.message)
        }
        let second = try await CutRequest(remove: [CutTarget(phrase: "very very", at: t(38.9))]).run(on: h.service, context: h.context)
        XCTAssertEqual(second.cuts.first?.start, t(38.35))
        XCTAssertEqual(second.cuts.first?.end, t(38.9))
    }

    func testAPhraseBothVoiceTracksHearIsFoundOnce() async throws {
        // An interview with a mic each: both mics hear "as I said", a few
        // milliseconds apart, and both are transcribed.
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.media.append(MediaItem(id: "med_mic2", path: "source/take1-mic2.wav", kind: .audio, role: .other, duration: t(64), hasAudio: true))
        project.audioTracks.insert(Track(id: "trk_voice2", kind: .audio, name: "Voice 2", clips: [
            Clip(id: "clip_mic2", name: "take1-mic2", content: .media(mediaID: "med_mic2"), start: t(0), duration: t(30), sourceStart: t(0))
        ], rippleMode: .cut), at: 1)
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.speech)
        try Self.writeVoice(to: h.folder.file("source/take1-mic2.wav"), length: 64, words: Self.speech)
        h.analysis.transcripts["med_camera"] = Self.transcript
        h.analysis.transcripts["med_mic2"] = Transcript(language: "en", engine: "fake", words: Self.transcript.words.map {
            TranscriptWord(text: $0.text, start: $0.start + t(0.02), end: $0.end + t(0.02))
        })

        let plan = try await CutRequest(remove: [CutTarget(phrase: "as I said")]).run(on: h.service, context: h.context)
        let stretch = try XCTUnwrap(plan.cuts.first)
        XCTAssertEqual(stretch.status, .cut, stretch.reason ?? "")
        XCTAssertEqual(stretch.text, "as I said")
        XCTAssertEqual(stretch.start, t(11.5))
    }

    func testTheResultSaysWhenSoundAskedForStays() {
        var stretch = CutStretch(
            asked: "as I said", text: "as I said", start: t(11.5), end: t(12.2), status: .cut,
            falseStart: false, before: "This is fine.", after: "we go on."
        )
        stretch.cut = TimeRange(start: t(11.2), end: t(12.5))
        stretch.keptBefore = t(0.2)
        stretch.keptAfter = t(0.2)
        stretch.startEdge = CutJoinSide(verdict: .clean, margin: 30)
        stretch.endEdge = CutJoinSide(verdict: .clean, margin: 30)
        stretch.missed = "0.08 s of sound"
        let result = CutResult(revision: 1, cuts: [stretch], removed: t(1.3), durationBefore: t(60), durationAfter: t(58.7), commands: [], applied: nil, warnings: [])
        let text = result.readableText
        XCTAssertTrue(text.contains("but 0.08 s of sound in the stretch asked for stays"), text)
    }

    func testTheRequestReadsFriendlyTimes() throws {
        let request = try ServiceJSON.decodeRequest(CutRequest.self, from: Data(#"{"remove": [{"phrase": "you know", "at": "2:14"}, {"start": "1:02.5", "end": 70, "falseStart": true}], "apply": true}"#.utf8))
        XCTAssertEqual(request.remove, [CutTarget(phrase: "you know", at: t(134)), CutTarget(start: t(62.5), end: t(70), falseStart: true)])
        XCTAssertEqual(request.apply, true)
    }
}
