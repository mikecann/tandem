import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tighten` and `pauses` listening to the take: every cut in a real pause
/// in the sound of every track that plays there, Mike's gaps kept from the
/// words' sound, and pauses with sound in them left alone and said where.
final class TightenSoundTests: XCTestCase {
    /// The voice's file, as heard: (start, end, dB under the speaker).
    /// Timeline time is file time up to 30 s.
    static let voice: [(Double, Double, Double)] = [
        (2.0, 3.0, 0),
        (3.2, 3.5, 20),      // someone off mic, 20 dB under (#11)
        (4.6, 5.9, 0),
        (7.5, 9.0, 0),
        (10.4, 11.6, 0),     // "Then" starts 0.2 s before the transcript says (#64)
        (13.2, 13.8, 0),
        (13.88, 14.42, 20),  // off mic again, filling the gap after "Done."
        (14.5, 15.0, 0),
        (16.6, 17.0, 0)
    ]
    static let breaths: [(Double, Double)] = [(16.1, 16.4)]
    /// The iPad's own recording: digital silence but for the app talking.
    static let app: [(Double, Double, Double)] = [(12.0, 12.8, 0)]

    static let transcript = Transcript(language: "en", engine: "fake", words: [
        TranscriptWord(text: "That's", start: t(2.0), end: t(2.4)),
        TranscriptWord(text: "it.", start: t(2.45), end: t(3.0)),
        TranscriptWord(text: "So", start: t(4.6), end: t(5.0)),
        TranscriptWord(text: "the", start: t(5.05), end: t(5.3)),
        // Ends 0.15 s before its sound does.
        TranscriptWord(text: "plan.", start: t(5.35), end: t(5.75)),
        // Starts 0.1 s after its sound does.
        TranscriptWord(text: "Now", start: t(7.6), end: t(8.0)),
        TranscriptWord(text: "we", start: t(8.05), end: t(8.3)),
        TranscriptWord(text: "build.", start: t(8.35), end: t(9.0)),
        TranscriptWord(text: "Then", start: t(10.6), end: t(11.0)),
        TranscriptWord(text: "test.", start: t(11.05), end: t(11.6)),
        TranscriptWord(text: "Done.", start: t(13.2), end: t(13.8)),
        TranscriptWord(text: "Okay.", start: t(14.5), end: t(15.0)),
        TranscriptWord(text: "Right.", start: t(16.6), end: t(17.0))
    ])

    static let ipad = MediaItem(id: "med_ipad", path: "source/ipad.wav", kind: .audio, role: .other, duration: t(64), hasVideo: false, hasAudio: true)

    private func harness(muteIPad: Bool = false, iPadFile: Bool = true, edit: (inout Project) throws -> Void = { _ in }) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        project.media.append(Self.ipad)
        // The iPad's recording on its own track, cut with the take.
        project.audioTracks.insert(Track(id: "trk_ipad", kind: .audio, name: "iPad", clips: [
            Clip(id: "clip_ipad", name: "ipad", content: .media(mediaID: "med_ipad"), start: t(0), duration: t(30), sourceStart: t(0))
        ], muted: muteIPad, rippleMode: .cut), at: 1)
        try edit(&project)
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try Self.write(to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.voice, breaths: Self.breaths, room: true)
        if iPadFile { try Self.write(to: h.folder.file("source/ipad.wav"), length: 64, words: Self.app, breaths: [], room: false) }
        h.analysis.transcripts["med_camera"] = Self.transcript
        // The app's line isn't in any transcript, as on the video in #11.
        h.analysis.transcripts["med_ipad"] = Transcript(language: "en", engine: "fake", words: [])
        return h
    }

    /// Room rumble and hiss (or digital silence) with a buzz of harmonics
    /// where `words` says, and breaths as hiss, at 32 kHz.
    static func write(to url: URL, length: Double, words: [(Double, Double, Double)], breaths: [(Double, Double)], room: Bool) throws {
        let rate = 32_000.0
        let count = Int(length * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let data = buffer.floatChannelData![0]
        var seed: UInt32 = 12_345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        var rumble: Float = 0
        for i in 0..<count {
            rumble += (noise() - rumble) * 0.02
            data[i] = room ? rumble * 0.03 + noise() * 0.00009 : 0
        }
        func span(_ start: Double, _ end: Double) -> Range<Int> { Int(start * rate)..<min(count, Int(end * rate)) }
        func fade(_ i: Int, _ range: Range<Int>) -> Float {
            Float(min(1, Double(i - range.lowerBound) / (0.005 * rate), Double(range.upperBound - i) / (0.005 * rate)))
        }
        for (start, end, under) in words {
            let range = span(start, end)
            let gain = 0.08 * pow(10, -under / 20)
            for i in range {
                let t = Double(i) / rate
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                data[i] += Float(buzz * gain) * fade(i, range)
            }
        }
        for (start, end) in breaths {
            let range = span(start, end)
            var last: Float = 0
            for i in range {
                let white = noise()
                data[i] += (white - last) * 0.0008 * fade(i, range)
                last = white
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func cut(after word: String, in result: TightenResult, file: StaticString = #filePath, line: UInt = #line) throws -> PlannedCut {
        try XCTUnwrap(result.cuts.first { $0.pause.before.hasSuffix(word) }, "no cut after \(word): \(result.readableText)", file: file, line: line)
    }

    func testEveryCutIsInARealPauseAndNeverThroughSound() async throws {
        let h = try harness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertFalse(plan.warnings.contains { $0.contains("Couldn't read") }, "\(plan.warnings)")

        // The voice off mic after "it.": the quiet either side of it is
        // cut, and it stays, 30 ms of quiet either side of it.
        let offMic = plan.cuts.filter { $0.pause.before.hasSuffix("it.") }
        XCTAssertEqual(offMic.count, 2, "\(offMic.map(\.cut))")
        let heard = try XCTUnwrap(offMic.first?.pause.sound?.heard.first)
        XCTAssertEqual(heard.start.seconds, 3.2, accuracy: 0.02)
        XCTAssertEqual(heard.end.seconds, 3.5, accuracy: 0.02)
        XCTAssertEqual(heard.tracks, ["Voice"])
        XCTAssertLessThanOrEqual(offMic[0].cut.end.seconds, heard.start.seconds - 0.03 + 0.001)
        XCTAssertGreaterThanOrEqual(offMic[1].cut.start.seconds, heard.end.seconds + 0.03 - 0.001)
        XCTAssertLessThanOrEqual(offMic[1].cut.end.seconds, 4.6 - CutPlanner.minimumLead + 0.001)

        // Mike's 0.4 s between sentences, from the end of "plan."'s sound
        // (5.9, not the transcript's 5.75) to the start of "Now"'s (7.5,
        // not 7.6).
        let plan2 = try cut(after: "plan.", in: plan)
        let sound = try XCTUnwrap(plan2.pause.sound)
        XCTAssertEqual(sound.start.seconds, 5.9, accuracy: 0.011)
        XCTAssertEqual(sound.end.seconds, 7.5, accuracy: 0.011)
        let kept = (plan2.cut.start.seconds - 5.9) + (7.5 - plan2.cut.end.seconds)
        XCTAssertEqual(kept, 0.4, accuracy: 0.04, "\(plan2.cut)")
        XCTAssertGreaterThanOrEqual(kept, 0.4 - 0.011)

        // "Then" starts 0.2 s before the transcript says: the cut ends
        // before its sound, not before 10.6.
        let early = try cut(after: "build.", in: plan)
        XCTAssertLessThanOrEqual(early.cut.end.seconds, 10.4 - 0.03 + 0.001)

        // The app talking on the iPad track in the voice's gap: the cut
        // goes beside it, never through it.
        let device = try cut(after: "test.", in: plan)
        XCTAssertEqual(device.pause.sound?.heard.first?.tracks, ["iPad"])
        XCTAssertFalse(device.cut.overlaps(TimeRange(start: t(12.0), end: t(12.8))), "\(device.cut)")

        // A breath before "Right.": kept, and the cut is in the quiet
        // before it.
        let breath = try cut(after: "Okay.", in: plan)
        XCTAssertLessThanOrEqual(breath.cut.end.seconds, 16.1 - 0.03 + 0.001)

        // Off mic right across the gap after "Done.": left alone, with
        // where the sound is.
        XCTAssertFalse(plan.cuts.contains { $0.pause.before.hasSuffix("Done.") })
        let crowded = try XCTUnwrap(plan.skipped.first { $0.pause.before.hasSuffix("Done.") }, "\(plan.skipped)")
        XCTAssertTrue([.sound, .speech].contains(crowded.reason), "\(crowded.reason)")
        XCTAssertFalse(try XCTUnwrap(crowded.pause.sound).heard.isEmpty)
        let text = plan.readableText
        XCTAssertTrue(text.contains("Left 1 pause with sound in it alone (listen with tandem clip):\n  00:13.800-00:14.500  0.700s  "), text)
        XCTAssertTrue(text.contains("Done. | Okay. Right....  sound at 00:13.8"), text)
        XCTAssertTrue(text.contains("...we build. Then test. | Done. Okay. Right...., beside sound at 00:12.0"), text)

        // Every join judges clean, as check --cuts will. Five pauses are
        // cut: the three with sound in them either side of it.
        XCTAssertEqual(plan.pausesCut, 5, text)
        XCTAssertEqual(plan.cuts.count, 8, text)
        for planned in plan.cuts {
            XCTAssertEqual(planned.startEdge?.verdict, .clean, "\(planned.cut)")
            XCTAssertEqual(planned.endEdge?.verdict, .clean, "\(planned.cut)")
        }
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")

        // Applied, it's one undo step, and check --cuts passes every join.
        let applied = try await h.service.tighten(TightenRequest(mike: true, apply: true), context: h.context)
        XCTAssertEqual(applied.cuts, plan.cuts)
        XCTAssertEqual(h.service.coordinator.revision, 2)
        let check = try await CheckRequest(from: t(0), to: t(20), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(check.ok, "\(check.problems)")
        XCTAssertTrue(check.notes.isEmpty, "\(check.notes)")
        XCTAssertNotNil(h.service.coordinator.undo())
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testAMutedTrackIsntListenedTo() async throws {
        let h = try harness(muteIPad: true)
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        // Nothing is heard on the voice between "test." and "Done.", so the
        // cut runs through where the muted iPad's app talks.
        let device = try cut(after: "test.", in: plan)
        XCTAssertEqual(device.pause.sound?.heard, [])
        XCTAssertTrue(device.cut.overlaps(TimeRange(start: t(12.0), end: t(12.8))), "\(device.cut)")
    }

    func testPausesSaysWhatsInTheSound() async throws {
        let h = try harness()
        defer { h.close() }
        let result = try await PausesRequest(min: 0.5).run(on: h.service, context: h.context)
        let device = try XCTUnwrap(result.pauses.first { $0.before.hasSuffix("test.") })
        XCTAssertEqual(device.start, t(11.6))
        XCTAssertEqual(device.sound?.heard.first?.tracks, ["iPad"])
        let early = try XCTUnwrap(result.pauses.first { $0.before.hasSuffix("build.") })
        XCTAssertEqual(try XCTUnwrap(early.sound).end.seconds, 10.4, accuracy: 0.011)
        let text = result.readableText
        XCTAssertTrue(text.contains("heard as 1.600s, sound at 00:12."), text)
        XCTAssertTrue(text.contains(" on iPad"), text)
    }

    func testAWordTheSoundHasNoVoiceForIsLeftOutAndThePauseIsOne() async throws {
        // The Threadbear launch video: the transcript had "Yes." in a long
        // pause where the mic had only the room, splitting it in two, and
        // tighten kept a keep either side of a word that isn't there. Here
        // "Yes." is at 19.0 between "Right." and "Next." with nothing said.
        let h = try harness()
        defer { h.close() }
        try Self.write(
            to: h.folder.file("source/take1-camera.wav"), length: 64, words: Self.voice + [(21.0, 21.5, 0)],
            breaths: Self.breaths, room: true
        )
        var transcript = Self.transcript
        transcript.words += [
            TranscriptWord(text: "Yes.", start: t(19.0), end: t(19.3)),
            TranscriptWord(text: "Next.", start: t(21.0), end: t(21.5))
        ]
        h.analysis.transcripts["med_camera"] = transcript

        let pauses = try await PausesRequest(min: 0.5).run(on: h.service, context: h.context)
        let merged = try XCTUnwrap(pauses.pauses.first { $0.before.hasSuffix("Right.") }, pauses.readableText)
        XCTAssertEqual(merged.start, t(17.0))
        XCTAssertEqual(merged.end, t(21.0))
        XCTAssertTrue(merged.after.hasPrefix("Next."), merged.after)
        XCTAssertTrue(pauses.warnings?.contains { $0.contains("\"Yes.\"") } == true, "\(pauses.warnings ?? [])")
        // "Done." and "Okay." are lone words too, with their voice: they stay.
        XCTAssertTrue(pauses.pauses.contains { $0.after.hasPrefix("Done.") })
        XCTAssertTrue(pauses.pauses.contains { $0.after.hasPrefix("Okay.") })

        // Tighten makes one cut of the pause, keeping a sentence's 0.4 s.
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        let cuts = plan.cuts.filter { $0.cut.start >= t(17.0) && $0.cut.end <= t(21.0) }
        XCTAssertEqual(cuts.count, 1, plan.readableText)
        XCTAssertEqual(4.0 - (cuts.first?.cut.duration.seconds ?? 0), 0.4, accuracy: 0.05)
    }

    func testWithoutSoundToListenToTheTranscriptsGapsAreCutAndItSaysSo() async throws {
        // The fixture's files aren't there.
        let h = try ServiceHarness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertFalse(plan.cuts.isEmpty)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("Couldn't read the sound of take1-camera.mov, so pauses there were cut from the transcript's gaps alone") }, "\(plan.warnings)")
    }
    /// The harness with the voice's file and transcript swapped for
    /// `voice` and `words`.
    private func harness(voice: [(Double, Double, Double)], words: [TranscriptWord]) throws -> ServiceHarness {
        let h = try harness()
        try Self.write(to: h.folder.file("source/take1-camera.wav"), length: 64, words: voice, breaths: [], room: true)
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: words)
        return h
    }

    func testAThroughEditInAPauseStillListensToBothPieces() async throws {
        // The voice split at 6.5, in the pause after "plan.", into two
        // pieces of the same file at the same offset. The iPad's muted, so
        // only the voice is heard there.
        let h = try harness(muteIPad: true) { project in
            let track = try XCTUnwrap(project.audioTracks.firstIndex { $0.id == "trk_voice" })
            let whole = project.audioTracks[track].clips[0]
            var head = whole, tail = whole
            head.duration = t(6.5)
            tail.id = "clip_voc1b"
            tail.start = t(6.5)
            tail.sourceStart = t(6.5)
            tail.duration = whole.duration - t(6.5)
            project.audioTracks[track].clips.replaceSubrange(0...0, with: [head, tail])
        }
        defer { h.close() }

        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
        let split = try cut(after: "plan.", in: plan)
        XCTAssertNotNil(split.pause.sound, "heard on both pieces, not planned from the transcript")
        XCTAssertEqual(split.startEdge?.verdict, .clean)
        XCTAssertEqual(try XCTUnwrap(split.pause.sound).start.seconds, 5.9, accuracy: 0.011)
        XCTAssertEqual(try XCTUnwrap(split.pause.sound).end.seconds, 7.5, accuracy: 0.011)
    }

    func testCutsStayInsideFromAndToAndNeverRemoveAProtectedTime() async throws {
        // The transcript's gap is 3.3-4.7, but the sound's is 3.0-5.0: a
        // cut leaving Mike's 0.4 s in the sound runs 3.2-4.8.
        let h = try harness(voice: [(2.0, 3.0, 0), (5.0, 6.0, 0)], words: [
            TranscriptWord(text: "One.", start: t(2.0), end: t(3.3)),
            TranscriptWord(text: "Two.", start: t(4.7), end: t(6.0))
        ])
        defer { h.close() }
        let free = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        let unbounded = try XCTUnwrap(free.cuts.first)
        XCTAssertLessThan(unbounded.cut.start.seconds, 3.3, "the sound's gap starts before the transcript's")

        // Asked for 3.3 to 4.7, it stays inside them.
        let bounded = try await h.service.tighten(TightenRequest(mike: true, from: t(3.3), to: t(4.7)), context: h.context)
        let inside = try XCTUnwrap(bounded.cuts.first, bounded.readableText)
        XCTAssertGreaterThanOrEqual(inside.cut.start, t(3.3))
        XCTAssertLessThanOrEqual(inside.cut.end, t(4.7))
        XCTAssertEqual(inside.startEdge?.verdict, .clean)
        XCTAssertEqual(inside.endEdge?.verdict, .clean)

        // 3.25 is in the pause as it's heard, if not in the transcript's:
        // the pause is left alone.
        let kept = try await h.service.tighten(TightenRequest(mike: true, protect: [t(3.25)]), context: h.context)
        XCTAssertTrue(kept.cuts.isEmpty, kept.readableText)
        XCTAssertEqual(kept.protected.count, 1, kept.readableText)
        XCTAssertFalse(kept.cuts.contains { $0.cut.start <= t(3.25) && t(3.25) <= $0.cut.end })
    }

    func testTheMinimumIsMeasuredOnTheSoundNotTheTranscript() async throws {
        // 0.4 s between the words in the transcript, 0.7 s in the sound.
        let h = try harness(voice: [(2.0, 3.0, 0), (3.7, 4.5, 0)], words: [
            TranscriptWord(text: "one", start: t(2.0), end: t(3.15)),
            TranscriptWord(text: "two", start: t(3.55), end: t(4.5))
        ])
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(min: 0.5, keep: 0.15), context: h.context)
        let cut = try XCTUnwrap(plan.cuts.first, plan.readableText)
        XCTAssertGreaterThanOrEqual(cut.cut.start.seconds, 3.0 + CutPlanner.minimumTail - 0.001)
        XCTAssertLessThanOrEqual(cut.cut.end.seconds, 3.7 - CutPlanner.minimumLead + 0.001)
        XCTAssertEqual(cut.startEdge?.verdict, .clean)

        // A gap that's under the minimum both ways isn't listed as skipped.
        let short = try await h.service.tighten(TightenRequest(min: 0.8, keep: 0.15), context: h.context)
        XCTAssertTrue(short.cuts.isEmpty)
        XCTAssertTrue(short.skipped.isEmpty, "\(short.skipped)")
    }

    func testATrackThatCantBeReadSendsItsPausesToTheTranscript() async throws {
        // The iPad's file isn't there, so nobody knows what it plays: its
        // pauses are cut from the transcript with a warning, not called
        // quiet from the voice alone.
        let h = try harness(iPadFile: false)
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        XCTAssertTrue(plan.warnings.contains { $0.contains("Couldn't read the sound of ipad.wav, so pauses there were cut from the transcript's gaps alone") }, "\(plan.warnings)")
        let device = try cut(after: "test.", in: plan)
        XCTAssertNil(device.pause.sound)
        XCTAssertNil(device.startEdge)
        let transcript = TranscriptTools.plan([device.pause], rules: TranscriptTools.mikeRules, frameRate: h.service.coordinator.project.settings.frameRate)
        XCTAssertEqual(transcript.first?.cut, device.cut)
    }

    func testAnOlderAppsResultStillDecodes() async throws {
        // Before tighten listened, its result had no skipped pauses, no
        // edges on its cuts and no sound on its pauses.
        let h = try harness()
        defer { h.close() }
        let plan = try await h.service.tighten(TightenRequest(mike: true), context: h.context)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json["skipped"] = nil
        json["cuts"] = (json["cuts"] as? [[String: Any]])?.map { cut in
            var cut = cut
            cut["startEdge"] = nil
            cut["endEdge"] = nil
            var pause = cut["pause"] as? [String: Any]
            pause?["sound"] = nil
            cut["pause"] = pause
            return cut
        }
        let old = try JSONDecoder().decode(TightenResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.skipped, [])
        XCTAssertEqual(old.cuts.count, plan.cuts.count)
        XCTAssertNil(old.cuts.first?.startEdge)
        XCTAssertNil(old.cuts.first?.pause.sound)
    }
}
