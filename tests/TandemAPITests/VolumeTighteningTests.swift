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

    private func planned(_ start: Double, _ end: Double) -> PlannedCut {
        let pause = Pause(start: Self.t(start), end: Self.t(end), duration: Self.t(end - start), before: "", after: "", clipIDs: [])
        return PlannedCut(pause: pause, cut: TimeRange(start: Self.t(start), end: Self.t(end)))
    }

    func testAClipUnderTheMinimumGetsAShortPauseBesideItPutBack() {
        // Clips between the cuts: 2-5 (3 s), 5.3-6.3 (1 s, too short), 9-12.
        let cuts = [planned(0, 2), planned(5, 5.3), planned(6.3, 9), planned(12, 13)]
        let (kept, back) = VolumeTightening.keepingClips(cuts, minimum: 2)
        // The 0.3 s pause before the short clip goes back, not the 2.7 s one.
        XCTAssertEqual(back.map(\.cut.start.seconds), [5])
        XCTAssertEqual(kept.count, 3)

        // Both pauses beside it over a second: it stays short, nothing put back.
        let long = [planned(0, 2), planned(5, 7), planned(7.5, 10)]
        XCTAssertEqual(VolumeTightening.keepingClips(long, minimum: 2).putBack.count, 0)
        XCTAssertEqual(VolumeTightening.keepingClips(cuts, minimum: 0).kept.count, 4)

        // The video's first and last clips don't count, after a lead-in cut
        // from 0 or before a run-out cut to the end.
        let edges = [planned(0, 0.6), planned(1.6, 1.8), planned(5, 7), planned(9.5, 9.7), planned(10.5, 11)]
        XCTAssertEqual(VolumeTightening.keepingClips(edges, minimum: 2, timelineEnd: Self.t(11)).putBack.count, 0)
        // Without the timeline's end, the last short clip does count.
        XCTAssertEqual(VolumeTightening.keepingClips(edges, minimum: 2).putBack.count, 1)
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
        // No transcript: every silence is taken as between sentences, so
        // these tests are Filmora's cut alone. Tests that need the kinds
        // set their own words.
        h.analysis.transcripts = [:]
        return h
    }

    /// Every pause the dry run found, given `kind`.
    private func every(_ plan: TightenResult, _ kind: FilmoraKind) -> [PauseKindMark] {
        (plan.pauses ?? []).map { PauseKindMark(at: Time(seconds: ($0.start.seconds + $0.end.seconds) / 2), kind: kind) }
    }

    func testEveryPauseATopicIsFilmorasCut() async throws {
        let h = try harness()
        defer { h.close() }
        let found = try await h.service.tighten(TightenRequest(min: 0.5, filmora: true, minClip: 0), context: h.context)
        let plan = try await h.service.tighten(TightenRequest(min: 0.5, filmora: true, minClip: 0, kinds: every(found, .topic)), context: h.context)
        // 0-1 at the timeline's start goes to the edge, all but the 0.05 s
        // lead before the first word; 3-4 keeps a topic's 0.8 s, 0.75 s
        // after the word and the lead before the next (so the clip coming in
        // starts just before he speaks); 6-6.6 and 8-8.3 are too short; the
        // quiet noise in 9-12 counts as silence; 29-30 and file 32-40 are
        // one silence across the two clips (29-38 on the timeline); the end
        // goes to the edge. Each edge may sit a frame further in (more
        // kept), never further out.
        let expected: [(Double, Double)] = [(0, 0.95), (3.75, 3.95), (9.75, 11.95), (29.75, 37.95), (48.75, 60)]
        XCTAssertEqual(plan.cuts.count, expected.count, plan.readableText)
        for (cut, (start, end)) in zip(plan.cuts, expected) {
            XCTAssertGreaterThanOrEqual(cut.cut.start.seconds, start - 1e-6, plan.readableText)
            XCTAssertLessThanOrEqual(cut.cut.start.seconds, start + 0.034, plan.readableText)
            XCTAssertLessThanOrEqual(cut.cut.end.seconds, end + 1e-6, plan.readableText)
            XCTAssertGreaterThanOrEqual(cut.cut.end.seconds, end - 0.034, plan.readableText)
        }
        XCTAssertTrue(plan.cuts.allSatisfy { $0.spoken == .topic && $0.guessed == false })

        // A lower threshold hears the quiet noise, so 9-12 is two silences.
        let strict = try await h.service.tighten(TightenRequest(min: 0.5, filmora: true, threshold: -45, minClip: 0), context: h.context)
        XCTAssertEqual(strict.cuts.filter { $0.cut.start.seconds > 9 && $0.cut.end.seconds < 12 }.count, 2, strict.readableText)
    }

    func testHissAboveFourKilohertzIsntSilence() {
        // 5 ms frames: all under the threshold, but hiss (a soft "s") in the
        // first 0.2 s of a second.
        let levels = [Float?](repeating: -60, count: 200)
        let hiss = Array(repeating: Float(-40), count: 40) + Array(repeating: Float(-90), count: 160)
        let found = VolumeTightening.silences(levels, hiss: hiss, start: 0, frame: 0.005, threshold: -35, minimum: 0.3)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].lowerBound, 0.2, accuracy: 1e-9)
    }

    func testTheKeepIsMeasuredFromWhereTheWordsReallyEndAndStart() {
        // 5 ms frames over a 1 s pause: a soft "v" at -45 dB RMS for 0.1 s,
        // then room tone, then a vowel's onset at -50 dB for 0.05 s.
        let rms = Array(repeating: Float(-45), count: 20) + Array(repeating: Float(-70), count: 170) + Array(repeating: Float(-50), count: 10)
        let hiss = [Float](repeating: -90, count: 200)
        let edges = VolumeTightening.speechEdges(10...11, rms: rms, hiss: hiss, start: 10, frame: 0.005)
        XCTAssertEqual(edges.lowerBound, 10.1, accuracy: 1e-9)
        XCTAssertEqual(edges.upperBound, 11.0, accuracy: 1e-9, "-50 dB is under the word floor: it is pause")
        let loud = Array(repeating: Float(-45), count: 20) + Array(repeating: Float(-70), count: 170) + Array(repeating: Float(-40), count: 10)
        XCTAssertEqual(VolumeTightening.speechEdges(10...11, rms: loud, hiss: hiss, start: 10, frame: 0.005).upperBound, 10.95, accuracy: 1e-9)
        let onset = Array(repeating: Float(-70), count: 185) + Array(repeating: Float(-40), count: 15)
        XCTAssertEqual(VolumeTightening.speechEdges(10...11, rms: onset, hiss: hiss, start: 10, frame: 0.005).upperBound, 10.925, accuracy: 1e-9)
    }

    func testEachKindKeepsItsGapAndTheDryRunGuesses() async throws {
        let h = try harness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "Built", start: Self.t(1.0), end: Self.t(2.0)),
            TranscriptWord(text: "using.", start: Self.t(2.1), end: Self.t(3.0)),
            TranscriptWord(text: "The", start: Self.t(4.0), end: Self.t(5.0)),
            TranscriptWord(text: "latest", start: Self.t(5.1), end: Self.t(6.0)),
            TranscriptWord(text: "and", start: Self.t(6.6), end: Self.t(8.0)),
            TranscriptWord(text: "done.", start: Self.t(8.3), end: Self.t(9.0)),
            TranscriptWord(text: "Next", start: Self.t(12.0), end: Self.t(29.0))
        ])
        let plan = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0), context: h.context)
        func cut(at time: Double, in plan: TightenResult) -> PlannedCut? {
            plan.cuts.first { $0.pause.start.seconds <= time && time <= $0.pause.end.seconds }
        }
        // "using." is Bark's full stop on a thinking pause: mid, 0.12 s,
        // 0.07 s after the word and the 0.05 s lead before the next. "latest | and" is a clause, "and | done"
        // (0.3 s, a hair under the minimum on 5 ms frames) isn't a pause,
        // "done. | Next" over 1.5 s is a new topic, and the two after the
        // last word are sentences (the safe side).
        let guesses = (plan.pauses ?? []).map { $0.guess }
        XCTAssertEqual(guesses, [.sentence, .mid, .clause, .topic, .sentence, .sentence], plan.readableText)
        let mid = try XCTUnwrap(cut(at: 3.5, in: plan), plan.readableText)
        XCTAssertEqual(mid.spoken, .mid)
        XCTAssertEqual(mid.guessed, true)
        XCTAssertEqual(mid.cut.start.seconds, 3.1, accuracy: 0.001, plan.readableText)
        XCTAssertEqual(mid.cut.end.seconds, 3.933, accuracy: 0.001, plan.readableText)
        let clause = try XCTUnwrap(cut(at: 6.3, in: plan), plan.readableText)
        XCTAssertEqual(clause.cut.start.seconds, 6.167, accuracy: 0.001, plan.readableText)
        XCTAssertTrue(plan.readableText.contains("only a guessed kind"), plan.readableText)

        // Given kinds win over the guesses, and nothing given is a guess.
        var kinds = every(plan, .mid)
        kinds[3] = PauseKindMark(at: kinds[3].at, kind: .sentence)
        kinds[2] = PauseKindMark(at: kinds[2].at, kind: .keep)
        let given = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0, kinds: kinds), context: h.context)
        let sentence = try XCTUnwrap(cut(at: 10.5, in: given), given.readableText)
        XCTAssertEqual(sentence.spoken, .sentence)
        // 0.35 s after "done.", 0.05 s before "Next", on frames inwards.
        XCTAssertEqual(sentence.cut.start.seconds, 9.367, accuracy: 0.001, given.readableText)
        XCTAssertEqual(sentence.cut.end.seconds, 11.933, accuracy: 0.001, given.readableText)
        XCTAssertNil(cut(at: 6.3, in: given), "keep is left alone")
        XCTAssertTrue(given.cuts.allSatisfy { $0.guessed == false })
    }

    func testApplyNeedsEveryPausesKind() async throws {
        let h = try harness()
        defer { h.close() }
        do {
            _ = try await h.service.tighten(TightenRequest(filmora: true, apply: true), context: h.context)
            XCTFail("apply with guessed kinds should be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("no kind yet"), error.message)
        }
        let plan = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0), context: h.context)
        var kinds = every(plan, .sentence)
        kinds.removeLast()
        do {
            _ = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0, kinds: kinds, apply: true), context: h.context)
            XCTFail("one pause with no kind should still be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("1 of"), error.message)
        }
        let applied = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0, kinds: every(plan, .sentence), apply: true), context: h.context)
        XCTAssertNotNil(applied.applied)
        let removed = applied.cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        XCTAssertEqual(h.service.coordinator.project.duration.seconds, 60 - removed, accuracy: 0.001)
    }

    func testTwoKindsInOnePauseAreNotTrustedAndKindsNeedFilmora() async throws {
        let h = try harness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(filmora: true), context: h.context)
        var kinds = every(plan, .sentence)
        // A second, different kind inside the pause at 3-4 (as when two
        // pauses the kinds were read for have become one).
        kinds.append(PauseKindMark(at: Self.t(3.2), kind: .keep))
        let mixed = try await h.service.tighten(TightenRequest(filmora: true, kinds: kinds), context: h.context)
        XCTAssertEqual(mixed.pauses?.filter { $0.kind == nil }.count, 1, mixed.readableText)
        XCTAssertTrue(mixed.warnings.contains { $0.contains("kinds given") }, "\(mixed.warnings)")
        do {
            _ = try await h.service.tighten(TightenRequest(filmora: true, kinds: kinds, apply: true), context: h.context)
            XCTFail("an untrusted kind should stop apply")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("no kind yet"), error.message)
        }
        do {
            _ = try await h.service.tighten(TightenRequest(kinds: kinds, apply: true), context: h.context)
            XCTFail("kinds without filmora should be refused")
        } catch let error as ServiceError {
            XCTAssertTrue(error.message.contains("go with `filmora`"), error.message)
        }
    }

    func testProtectAndFromAndTo() async throws {
        let h = try harness()
        defer { h.close() }
        let kept = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0, protect: [Self.t(10)]), context: h.context)
        XCTAssertFalse(kept.cuts.contains { $0.cut.start.seconds > 9 && $0.cut.end.seconds < 12 })
        XCTAssertEqual(kept.protected.count, 1)

        // A silence running into `from` keeps its keep there, as if a word
        // were before it: a sentence's 0.35 s after, the 0.05 s lead before. The
        // quiet noise at 10-10.5 (-45 dB RMS) is loud enough to be sound, and
        // is followed as a word's soft edge as far as the 0.3 s reach: the
        // keep starts from 10.3.
        let bounded = try await h.service.tighten(TightenRequest(filmora: true, minClip: 0, from: Self.t(10), to: Self.t(20)), context: h.context)
        XCTAssertEqual(bounded.cuts.count, 1, bounded.readableText)
        XCTAssertEqual(bounded.cuts[0].cut.start.seconds, 10.667, accuracy: 0.001)
        XCTAssertEqual(bounded.cuts[0].cut.end.seconds, 11.933, accuracy: 0.034)
    }

    func testAFullStopAfterAWordThatNeverEndsASentenceIsMidSentence() {
        XCTAssertEqual(TranscriptTools.spokenKind(after: "using."), .mid)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "The."), .mid)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "it\u{2019}s."), .mid)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "done."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "Right?"), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "then,"), .comma)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "scratch"), .mid)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "'using.'"), .mid)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "using\u{2019}."), .mid)
        // Real endings stay sentences.
        XCTAssertEqual(TranscriptTools.spokenKind(after: "this."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "can."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "in."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "cause."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "from."), .sentence)
        XCTAssertEqual(TranscriptTools.spokenKind(after: "the?"), .sentence)
    }

    func testAThinkingPauseIsNeverPutBackForTheMinimumClip() {
        var mid = planned(5, 5.3)
        mid.spoken = .mid
        // The short clip 5.3-6.3 sits between a mid-sentence cut and a long one.
        let (_, back) = VolumeTightening.keepingClips([planned(0, 2), mid, planned(6.3, 9), planned(12, 13)], minimum: 2)
        XCTAssertTrue(back.isEmpty, "\(back)")
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
