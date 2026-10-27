import AVFoundation
import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

/// `tandem check` through the service: what it checks, what it reports.
final class CheckAPITests: XCTestCase {
    /// Grey frames at 30 fps from `start`, with a flat white flash at `flash`.
    private func frames(from start: Double, to end: Double, flash: Double? = nil) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let lit = flash.map { abs($0 - seconds) < 0.001 } ?? false
            return FrameStats(
                time: Time(seconds: seconds), luma: lit ? 1 : 0.4, brightestTile: lit ? 1 : 0.4,
                flatGreen: 0, flatWhite: lit ? 1 : 0, thumbnail: [UInt8](repeating: lit ? 255 : 100, count: 16)
            )
        }
    }

    func testAFlashInTheFramesIsAProblem() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = frames(from: 0, to: 2, flash: 1)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(2)).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.frames, 60)
        XCTAssertEqual(result.problems.map(\.kind), [.whiteBlock])
        XCTAssertEqual(result.problems.first?.start, t(1))
        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Checked 00:00.000-00:02.000 (60 frames) in "), text)
        XCTAssertTrue(text.contains("1 problem:"), text)
        XCTAssertTrue(text.contains("White block"), text)
        XCTAssertTrue(text.contains("On: clip_cam1 take1-camera"), "names the clips on screen, top first: \(text)")
    }

    /// Grey frames at 30 fps, one of them lighter at `flash`: not white,
    /// just unlike its neighbours, like the preview jumping for a frame.
    private func flicker(from start: Double, to end: Double, at flash: Double) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let lit = abs(flash - seconds) < 0.001
            return FrameStats(time: Time(seconds: seconds), luma: 0.4, brightestTile: 0.4, flatGreen: 0, flatWhite: 0, thumbnail: [UInt8](repeating: lit ? 160 : 100, count: 16))
        }
    }

    func testAFlickerInTheScreenRecordingComesWithTheHoldThatFixesIt() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = flicker(from: 0, to: 2, at: 1)
        renderer.screenScanned = flicker(from: 0, to: 2, at: 1)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(2)).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.flicker])
        let flash = TimeRange(start: t(1), end: t(1) + FrameRate.fps30.frameDuration)
        let hold = EditCommand.holdFrame(clipID: "clip_scr1", range: flash)
        XCTAssertEqual(result.problems.first?.fix, hold, "the screen recording flashes on its own, under the camera")
        XCTAssertEqual(result.commands, [hold])
        XCTAssertEqual(result.revision, h.service.coordinator.revision)
        let text = result.readableText
        XCTAssertTrue(text.contains("Hold the frame before it: holdFrame on clip_scr1."), text)
        XCTAssertTrue(text.contains(#"Fix: tandem apply --expect \#(h.service.coordinator.revision) --label "Hold the frame before each flicker" '[{"holdFrame":"#), text)
        let json = String(decoding: try ServiceJSON.encoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""commands":[{"holdFrame""#), json)

        _ = try h.service.apply(ApplyRequest(label: QualityCheck.holdLabel, commands: result.commands, expectedRevision: result.revision), context: h.context)
        let screen = try XCTUnwrap(h.service.coordinator.project.track(named: "Screen")).clips
        XCTAssertEqual(screen.filter(\.freezeFrame).map(\.range), [flash])
        XCTAssertEqual(h.service.coordinator.project.track(named: "Voice")?.clips.first?.range, TimeRange(start: t(0), end: t(30)), "the sound plays on uncut")
    }

    func testBrollJustAfterACameraCutIsADoubleJumpWithItsFixOnTheApplyLine() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // The take cuts at 30, the camera in the corner dissolving from
        // 29.75 to 30.25; the shot lands two frames after the cut, halfway
        // through the dissolve.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(10.066), includeLinked: false))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok, "a double jump fails the check, even a quick one")
        XCTAssertEqual(result.problems.map(\.kind), [.doubleJump])
        let problem = try XCTUnwrap(result.problems.first)
        XCTAssertEqual(problem.start, t(29.75), "from where the dissolve starts")
        let fix = try XCTUnwrap(problem.fix)
        XCTAssertEqual(result.commands, [fix])
        XCTAssertEqual(result.revision, h.service.coordinator.revision)
        let text = result.readableText
        XCTAssertTrue(text.contains("00:29.750-00:30.066  Double jump: servers.mp4 starts 9 frames after a dissolve on the camera starts, so the camera shows for 0.32 s before it. Extend it back to the start of the dissolve.  On: clip_brl1 servers"), text)
        XCTAssertTrue(text.contains(#"Fix: tandem apply --expect \#(h.service.coordinator.revision) --label "\#(QualityCheck.doubleJumpLabel)" '[{"updateClip":{"clipID":"clip_brl1","patch":{"#), text)
        let json = String(decoding: try ServiceJSON.encoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"doubleJump""#), json)
        XCTAssertTrue(json.contains(#""commands":[{"updateClip""#), json)

        _ = try h.service.apply(ApplyRequest(label: QualityCheck.doubleJumpLabel, commands: result.commands, expectedRevision: result.revision), context: h.context)
        XCTAssertEqual(h.service.coordinator.project.clip("clip_brl1")?.start, t(29.75), "over the whole dissolve and the screen's cut")
        let again = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.ok, "\(again.problems.map(\.message))")
    }

    func testAFlickerUnderADoubleJumpsFixIsLeftToTheFix() async throws {
        // The shot lands 2 frames after the cut at 30, and the screen
        // recording flickers in the camera that shows before it. Running the
        // shot back over the cut hides the flicker, so a hold there would
        // only freeze the take under the shot: one problem, one fix.
        var renderer = FakeRenderer()
        renderer.scanned = flicker(from: 28, to: 32, at: 30.0333)
        renderer.screenScanned = flicker(from: 28, to: 32, at: 30.0333)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(10.066), includeLinked: false))
        let result = try await CheckRequest(from: t(28), to: t(32)).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.doubleJump], "\(result.problems.map(\.message))")
        XCTAssertFalse(result.commands.contains { if case .holdFrame = $0 { return true } else { return false } }, "\(result.commands)")

        // Away from the shot the flicker keeps its hold.
        var away = FakeRenderer()
        away.scanned = flicker(from: 28, to: 32, at: 29)
        away.screenScanned = flicker(from: 28, to: 32, at: 29)
        let g = try ServiceHarness(renderer: away)
        defer { g.close() }
        try g.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(10.066), includeLinked: false))
        let other = try await CheckRequest(from: t(28), to: t(32)).run(on: g.service, context: g.context)
        XCTAssertEqual(Set(other.problems.map(\.kind)), [.doubleJump, .flicker])
    }

    func testTheNextCheckOnlyRendersThePiecesThatChanged() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let first = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.filter { !$0.screen }.map(\.ranges), [[TimeRange(start: .zero, end: t(40))]])

        let again = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.count, 2, "nothing changed, so nothing is rendered again")
        XCTAssertEqual(again.frames, first.frames)
        XCTAssertEqual(again.problems, first.problems)
        XCTAssertEqual(again.notes, first.notes)

        // The B-roll at 20 to 25 moves a second later: the pieces from 10 to
        // 30 (with the margin either side for transitions) render again.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        _ = try await CheckRequest(from: t(0), to: t(40)).run(on: h.service, context: h.context)
        XCTAssertEqual(renderer.scans.all.dropFirst(2).filter { !$0.screen }.map(\.ranges), [[TimeRange(start: t(10), end: t(30))]])
    }

    func testCachedFramesReadBackExactly() throws {
        let frames = [
            FrameStats(time: t(1.5), luma: 0.123456789, brightestTile: 0.9, flatGreen: 0.01, flatWhite: 0.2, thumbnail: [1, 2, 3, 4], columns: 2, scanlines: [9, 8, 7]),
            FrameStats(time: t(1.533), luma: 0, brightestTile: 0, flatGreen: 0, flatWhite: 0, thumbnail: [], columns: 1)
        ]
        XCTAssertEqual(CheckCache.decode(CheckCache.encode(frames)), frames)
        XCTAssertNil(CheckCache.decode(CheckCache.encode(frames).dropLast()), "a cut-short file isn't read")
    }

    /// Still 32 x 18 frames at 30 fps from `start`, and with `turn` a new
    /// page from then on, as the screen recording on its own shows it.
    private func pages(from start: Double, to end: Double, turn: Double? = nil) -> [FrameStats] {
        stride(from: start, to: end - 0.0001, by: 1.0 / 30).map { seconds in
            let page = turn.map { seconds >= $0 - 0.0001 ? 1 : 0 } ?? 0
            let tiles = (0..<(32 * 18)).map { (tile: Int) -> UInt8 in UInt8(20 + (tile * (page + 3) + page * 11) % 7 * 6) }
            return FrameStats(time: Time(seconds: seconds), luma: 0.1, brightestTile: 0.2, flatGreen: 0, flatWhite: 0, thumbnail: tiles, columns: 32)
        }
    }

    func testDeadAirAndPageChangesAreNotes() async throws {
        var renderer = FakeRenderer()
        renderer.scanned = pages(from: 0, to: 9)
        renderer.screenScanned = pages(from: 0, to: 9, turn: 8)
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(from: t(0), to: t(9)).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        XCTAssertEqual(result.notes.map(\.kind), [.deadAir, .pageChange])
        let dead = try XCTUnwrap(result.notes.first)
        XCTAssertEqual(dead.start, t(3.6), "the 1.4 s pause after \"decision models.\"; the 0.7 s one isn't")
        XCTAssertEqual(dead.end, t(5.0))
        XCTAssertEqual(result.notes.last?.start, t(8))
        XCTAssertEqual(renderer.scans.all.count, 2)
        XCTAssertEqual(Set(renderer.scans.all.map(\.screen)), [false, true], "the composite and the screen recording on its own")
        XCTAssertEqual(renderer.scans.all.first { $0.screen }?.ranges, [TimeRange(start: .zero, end: t(9))])

        let text = result.readableText
        XCTAssertTrue(text.contains("no problems."), text)
        XCTAssertTrue(text.contains("Notes (not problems):\n  00:03.600-00:05.000  Dead air: 1.40 s with nothing said, no sound effect or music swell, and a still picture (after \"talk about decision models.\"). Cut it, or keep it if the pause earns it.  On: clip_txt1 title \"DECISION MODELS\", clip_cam1 take1-camera, clip_scr1 take1-screen"), text)
        XCTAssertTrue(text.contains("00:08.000-00:08.033  Page change inside a clip, with no transition: "), text)
        let json = String(decoding: try ServiceJSON.encoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""kind":"deadAir""#) && json.contains(#""kind":"pageChange""#), json)
    }

    func testChangedChecksDeadAirAndPagesWhereThingsChanged() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        // An agent moves the B-roll to 21 to 26, where nothing is said.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        let result = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        let changed = TimeRange(start: t(20.5), end: t(26.5))
        XCTAssertEqual(renderer.scans.all.map(\.ranges), [[changed], [changed]], "both scans read only what changed")
        XCTAssertEqual(result.notes.map(\.kind), [.deadAir])
        XCTAssertEqual(result.notes.first.map { TimeRange(start: $0.start, end: $0.end) }, changed)
    }

    func testNoTranscriptMeansNoDeadAirAndSaysSo() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        h.analysis.transcripts = [:]
        let result = try await CheckRequest(from: t(0), to: t(9)).run(on: h.service, context: h.context)
        XCTAssertTrue(result.notes.isEmpty, "the voice could be saying anything: \(result.notes)")
        XCTAssertEqual(result.warnings, ["No transcript yet for take1-camera.mov, so dead air isn't checked where it plays."])
        XCTAssertTrue(result.readableText.contains("Warning: No transcript yet for take1-camera.mov"), result.readableText)
    }

    func testAQuickCheckRendersNothing() async throws {
        let renderer = FakeRenderer()
        let h = try ServiceHarness(renderer: renderer)
        defer { h.close() }
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(renderer.scans.all.isEmpty, "not even the screen recording")
        XCTAssertTrue(result.warnings.isEmpty, "a quick check doesn't look for dead air, so it can't miss any")
        XCTAssertEqual(result.frames, 0)
        XCTAssertEqual(result.ranges, [TimeRange(start: .zero, end: t(60))])
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertTrue(result.readableText.contains("(quick: no frames rendered)"), result.readableText)
    }

    func testChangedChecksWhatsWaitingForReview() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let nothing = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertTrue(nothing.ranges.isEmpty)
        XCTAssertEqual(nothing.readableText, "Nothing is waiting for Mike's review, so there was nothing to check.")

        // An agent moves the B-roll to 21 to 26.
        try h.apply(.moveClips(clipIDs: ["clip_brl1"], delta: t(1), includeLinked: false))
        let changed = try await CheckRequest(changed: true).run(on: h.service, context: h.context)
        XCTAssertEqual(changed.ranges, [TimeRange(start: t(20.5), end: t(26.5))], "the change and half a second either side")
        XCTAssertEqual(changed.frames, 180)
    }

    func testABlownUpPictureIsANoteNotAProblem() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        try h.apply(.updateMedia(mediaID: "med_broll", patch: .object(["width": .number(1280), "height": .number(720)])))
        try h.apply(.updateClip(clipID: "clip_brl1", patch: .object(["video": .object(["transform": .object(["scale": .number(1.5)])])])))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        XCTAssertEqual(result.notes.map(\.kind), [.soft])
        XCTAssertTrue(result.readableText.contains("Notes (not problems):"), result.readableText)
    }

    func testClipsAndGapsShorterThanAFrameAreSliverNotes() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // Small, so the take shows around them: full-frame solids with
        // camera between them would be double jumps (camera flashes) too.
        func solid(_ id: String, _ start: Double, _ duration: Double) -> EditCommand {
            .insertClip(trackID: "trk_broll", clip: Clip(
                id: id, content: .solid(color: .black), start: t(start), duration: t(duration), video: VideoProperties(transform: Transform(scale: 0.25))
            ))
        }
        try h.apply(solid("clip_a", 26, 1), solid("clip_b", 27.01, 1), solid("clip_tiny", 29, 0.02))
        let result = try await CheckRequest(quick: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "notes don't fail a check")
        let slivers = result.notes.filter { $0.kind == .sliver }
        XCTAssertEqual(slivers.map(\.start), [t(27), t(29)])
        XCTAssertEqual(slivers.map(\.end), [t(27.01), t(29.02)])
        XCTAssertEqual(slivers.map(\.clipIDs), [["clip_a", "clip_b"], ["clip_tiny"]])
        let text = result.readableText
        XCTAssertTrue(text.contains("00:27.000-00:27.010  Sliver: a 0.010 s gap between clips on \"B-roll\", under a frame at 30 fps."), text)
        XCTAssertTrue(text.contains("00:29.000-00:29.020  Sliver: a 0.020 s clip on \"B-roll\", under a frame at 30 fps."), text)

        let narrow = try await CheckRequest(from: t(0), to: t(28), quick: true).run(on: h.service, context: h.context)
        XCTAssertEqual(narrow.notes.filter { $0.kind == .sliver }.map(\.start), [t(27)], "only what's in the checked stretch")
    }

    func testRequestsThatDontMakeSenseAreRefused() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        for request in [CheckRequest(from: t(10), to: t(5)), CheckRequest(from: t(1), changed: true), CheckRequest(width: 10), CheckRequest(quick: true, cuts: true), CheckRequest(quick: true, listen: true)] {
            do {
                _ = try await request.run(on: h.service, context: h.context)
                XCTFail("\(request) should be refused")
            } catch let error as ServiceError {
                XCTAssertEqual(error.code, "badRequest")
            }
        }
    }

    // MARK: - Cuts

    /// The camera's sound as a 16 kHz WAV: room noise, with "words" (a buzz
    /// of harmonics) where `words` says, in file time, and `soft` ones some
    /// dB under them: (start, end, dB).
    private func writeVoice(to url: URL, length: Double, words: [(Double, Double)], soft: [(Double, Double, Double)] = []) throws {
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
        for (start, end, under) in words.map({ ($0.0, $0.1, 0.0) }) + soft {
            let from = Int(start * rate), to = Int(end * rate)
            let gain = 0.08 * pow(10, -under / 20)
            for i in from..<to {
                let t = Double(i) / rate
                let fade = min(1, Double(i - from) / 80, Double(to - i) / 80)
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                data[i] += Float(buzz * gain * fade)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// The fixture with the camera's sound in a WAV file that's really there.
    private func voicedHarness(
        words: [(Double, Double)], soft: [(Double, Double, Double)] = [], edit: (inout Project) -> Void = { _ in }
    ) throws -> ServiceHarness {
        var project = APIFixture.project()
        project.media[0].path = "source/take1-camera.wav"
        edit(&project)
        let h = try ServiceHarness(project: project)
        try FileManager.default.createDirectory(at: h.folder.file("source"), withIntermediateDirectories: true)
        try writeVoice(to: h.folder.file("source/take1-camera.wav"), length: 64, words: words, soft: soft)
        return h
    }

    func testAWordRunningPastACutIsAProblemWithItsFix() async throws {
        // "section." runs on 0.12 s past file time 30, where the first piece
        // of the take ends; "Now" starts well after the second piece does (32).
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.12), (30.5, 31.4), (32.3, 32.8)])
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.frames, 0, "nothing rendered")
        XCTAssertEqual(result.cuts, 4, "the take's start, the cut at 30 (both sides) and its end")
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let problem = try XCTUnwrap(result.problems.first)
        XCTAssertEqual(problem.start, t(30))
        XCTAssertEqual(problem.clipIDs, ["clip_voc1", "clip_voc2"])
        let cut = try XCTUnwrap(problem.cut)
        XCTAssertEqual(cut.clipID, "clip_voc1")
        XCTAssertEqual(cut.edge, .end)
        XCTAssertEqual(cut.fixKind, .trimToPause)
        XCTAssertLessThan(try XCTUnwrap(cut.margin), 9, "cut while the word's sounding")
        // Just into the pause after the word (30.16), on a frame.
        let to = t(30) + Time.frames(5, at: .fps30)
        XCTAssertEqual(cut.to, to)
        let fix = EditCommand.trim(clipID: "clip_voc1", edge: .end, to: to, ripple: true, includeLinked: nil)
        XCTAssertEqual(result.commands, [fix])
        XCTAssertEqual(result.revision, h.service.coordinator.revision)

        let text = result.readableText
        XCTAssertTrue(text.hasPrefix("Checked 00:00.000-01:00.000 (4 cut edges) in "), text)
        XCTAssertTrue(text.contains("  00:30.000  Clipped word at the end of clip_voc1: the voice runs on 0.12 s past the cut; the clip's last 25 ms is 1.2 dB under the speech. Trim the end 0.167 s later, into the pause after it.  On: clip_voc1 take1-camera, clip_voc2 take1-camera"), text)
        XCTAssertTrue(text.contains("Fix: tandem apply --expect \(result.revision ?? 0) --label \"Move clipped cuts into pauses\" '[{\"trim\":"), text)

        // Applying the fix leaves nothing to find.
        try h.service.apply(ApplyRequest(label: "fix", commands: result.commands), context: h.context)
        let again = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.ok, "\(again.problems)")
        XCTAssertTrue(again.commands.isEmpty)
    }

    func testACutWhoseOnlyPauseIsPastACutWordIsPutBack() async throws {
        // "that because": "that" is kept and runs straight into "because",
        // cut with the 2 s after it. The pause after "because" is in reach,
        // but trimming into it brings "because" back.
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.25), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "that", start: t(29.5), end: t(30)),
            TranscriptWord(text: "because", start: t(30.02), end: t(30.24)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let cut = try XCTUnwrap(result.problems.first?.cut)
        XCTAssertEqual(cut.fixKind, .putBack)
        XCTAssertNil(cut.to)
        let fix = EditCommand.trim(clipID: "clip_voc1", edge: .end, to: t(32), ripple: true, includeLinked: nil)
        XCTAssertEqual(cut.fix, fix, "the end of the first piece on to where the second starts in the take")
        XCTAssertEqual(result.commands, [fix])
        XCTAssertTrue(result.readableText.contains("No pause it can reach without bringing back a cut word: put back the 2.00 s cut here, filler and all (the end of clip_voc1 2.000 s later)."), result.readableText)

        // Put back, the take carries straight on: nothing left to check there.
        try h.service.apply(ApplyRequest(label: "fix", commands: result.commands), context: h.context)
        let again = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(again.ok, "\(again.problems)")
        XCTAssertEqual(again.cuts, 2, "the take's start and end")

        // Without the transcript, nothing says "because" is a word, so the
        // trim goes into the pause.
        XCTAssertNotNil(h.service.coordinator.undo())
        h.analysis.transcripts["med_camera"] = nil
        let unheard = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(unheard.problems.first?.cut?.fixKind, .trimToPause)
    }

    /// Hears what `script` says for the join whose render starts at the
    /// key's time, and counts how often it's asked.
    private final class FakeEar: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        let script: [Double: [CutListen.Word]]
        let engine: String
        let model: String
        /// Throws for these joins (by render start), or every one when nil
        /// is in it.
        var failing: Set<Double?> = []

        init(_ script: [Double: [CutListen.Word]], engine: String = "fake", model: String = "1") {
            self.script = script
            self.engine = engine
            self.model = model
        }

        struct Failed: Error {}

        /// A render whose every sample says where it starts, so the ear can
        /// tell which join it's hearing.
        var mix: CutCheck.Mix {
            CutCheck.Mix(rate: CutListen.sampleRate) { from, to in [Float](repeating: Float(from) / 1000, count: Int(((to - from) * CutListen.sampleRate).rounded())) }
        }

        var ear: CutCheck.Ear {
            CutCheck.Ear(engine: engine, model: model) { samples in
                self.lock.withLock { self.calls += 1 }
                let from = (Double(samples[Int(CutListen.padding * CutListen.sampleRate)]) * 1000).rounded()
                if self.failing.contains(nil) || self.failing.contains(from) { throw Failed() }
                return self.script[from] ?? []
            }
        }
    }

    func testListeningHearsEachJoinAndFlagsWhatsCutOff() async throws {
        // "that [because] Now": the first piece ends between "that" and
        // "because", but "be" is heard after the join: the start of the cut
        // word left in.
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.0), (30.02, 30.24), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "So", start: t(1), end: t(3.6)),
            TranscriptWord(text: "that", start: t(29.5), end: t(30)),
            TranscriptWord(text: "because", start: t(30.02), end: t(30.24)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        // Heard times are from the start of what the engine hears: the
        // padding, then 3 s before the join.
        let lead = CutListen.padding + CutListen.span
        let ear = FakeEar([
            27: [CutListen.Word(text: "that", start: lead - 0.5, end: lead), CutListen.Word(text: "be", start: lead + 0.01, end: lead + 0.1),
                 CutListen.Word(text: "Now.", start: lead + 1, end: lead + 1.8)],
            -3: [CutListen.Word(text: "So", start: lead + 1, end: lead + 3.6)]
        ])
        h.service.cutListening = ([ear.ear], ear.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertEqual(listened.engine, "fake")
        XCTAssertEqual(listened.joins.map(\.time), [t(0), t(30), t(60)], "the take's start, the cut and its end")
        XCTAssertEqual(listened.heard, 3)
        XCTAssertEqual(listened.cached, 0)
        let join = listened.joins[1]
        XCTAssertEqual(join.said, "that | Now")
        XCTAssertEqual(join.heard, "that | be Now.")
        XCTAssertTrue(join.clipped)
        XCTAssertEqual(join.clipIDs, ["clip_voc1", "clip_voc2"])
        XCTAssertEqual(listened.joins[0].findings, [], "\(listened.joins[0])")

        // The levels flag the cut through "because" too: one problem that
        // says both, with the levels' fix.
        let heard = heardCutOff(result)
        XCTAssertEqual(heard.map(\.start), [t(30)])
        XCTAssertEqual(heard.map(\.kind), [.clippedWord], "\(result.problems)")
        let message = try XCTUnwrap(heard.first?.message)
        XCTAssertTrue(message.contains("and heard cut off (\"be\" is heard, which the take doesn't keep here (sounds like part of \"because\", which is cut))"), message)
        XCTAssertFalse(result.ok)

        let text = result.readableText
        XCTAssertTrue(text.contains("Heard across 3 joins with fake (3 heard, "), text)
        XCTAssertTrue(text.contains("  00:30.000  cut off\n    take:  that | Now\n    heard: that | be Now."), text)
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertTrue(json.contains(#""listened":{"#), json)

        // Nothing changed: every join comes from the cache.
        let again = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        XCTAssertEqual(again.listened?.cached, 3)
        XCTAssertEqual(again.listened?.heard, 0)
        XCTAssertEqual(ear.calls, 3, "nothing heard again")
        XCTAssertEqual(heardCutOff(again).map(\.start), [t(30)])
    }

    /// The problems listening backs: heard cut off on its own, or with the
    /// levels flagging the same join.
    private func heardCutOff(_ result: CheckResult) -> [CheckProblem] {
        result.problems.filter { $0.kind == .heardCutOff || $0.message.contains(", and heard cut off (") }
    }

    /// A clipped edge for `CutCheck.combine`, with its trim.
    private func clipped(_ clipID: String, _ edge: ClipEdge, at time: Double, margin: Double, lastWordCut: String? = nil) -> CheckProblem {
        let fix = EditCommand.trim(clipID: clipID, edge: edge, to: t(time + 0.1), ripple: true, includeLinked: nil)
        return CheckProblem(
            kind: .clippedWord, start: t(time), end: t(time), message: "Clipped word at the end of \(clipID): the voice runs on 0.30 s past the cut.",
            clipIDs: [clipID], cut: CheckProblem.CutEdge(clipID: clipID, edge: edge, margin: margin, fixKind: .trimToPause, fix: fix, lastWordCut: lastWordCut)
        )
    }

    func testListeningDismissesALevelFlagWhoseWordsAreHeardWhole() {
        // Tandem video 9:06: a tight join in fluent speech, every word heard.
        let summary = ListenSummary(engine: "fake", joins: [
            HeardJoin(time: t(30), said: "remove the bad takes, | So I have", heard: "remove the bad takes. | So I have", findings: [], clipIDs: ["clip_voc1", "clip_voc2"], cached: false)
        ], heard: 1, cached: 0, secondsPerJoin: nil)
        let combined = CutCheck.combine(problems: [clipped("clip_voc1", .end, at: 30, margin: 27.4)], notes: [], summary: summary)
        XCTAssertEqual(combined.problems, [])
        XCTAssertEqual(combined.commands, [], "no fix for what isn't wrong")
        let note = try? XCTUnwrap(combined.notes.first)
        XCTAssertEqual(note?.kind, .heardWhole)
        XCTAssertTrue(note?.message.contains("levels flagged it, but every kept word is heard whole") == true, note?.message ?? "")
        XCTAssertNotNil(note?.cut, "what the levels said is still there to read")
    }

    func testAJoinFlaggedByLevelsAndHeardCutOffIsOneProblemThatSaysBoth() {
        // Tandem video 20:05: "pub" left in, and the levels flagged the end.
        let pub = CutListen.Finding(kind: .extra, heard: "pub", time: 29.7, slip: false, why: "heard right at the join")
        let summary = ListenSummary(engine: "fake", joins: [
            HeardJoin(time: t(30), said: "made in the | comfortable, and", heard: "made in the pub | comfortable and", findings: [pub],
                      clipIDs: ["clip_voc1", "clip_voc2"], cached: false, cut: ["past", "couple"])
        ], heard: 1, cached: 0, secondsPerJoin: nil)
        let combined = CutCheck.combine(problems: [clipped("clip_voc1", .end, at: 30, margin: 7.7)], notes: [], summary: summary)
        XCTAssertEqual(combined.problems.map(\.kind), [.clippedWord], "one problem, not two")
        XCTAssertTrue(combined.problems[0].message.hasPrefix("Clipped word at the end of clip_voc1, and heard cut off (\"pub\" is heard"), combined.problems[0].message)
        XCTAssertEqual(combined.commands.count, 1)
    }

    func testAWordTheTakeCutHeardWholeIsANoteAndALastWordHeardIsDismissed() {
        // Tandem video 12:39: "yet." is heard; the transcript has it cut.
        let yet = CutListen.Finding(kind: .extra, heard: "yet.", time: 29.6, slip: false, why: "heard right at the join")
        let summary = ListenSummary(engine: "fake", joins: [
            HeardJoin(time: t(30), said: "reviewed all of it | And hopefully", heard: "reviewed all of it yet. | And hopefully", findings: [yet],
                      clipIDs: ["clip_voc1", "clip_voc2"], cached: false, cut: ["yet.", "And"])
        ], heard: 1, cached: 0, secondsPerJoin: nil)
        let combined = CutCheck.combine(problems: [clipped("clip_voc1", .end, at: 30, margin: 36.5, lastWordCut: "yet.")], notes: [], summary: summary)
        XCTAssertEqual(combined.problems, [])
        XCTAssertEqual(combined.notes.map(\.kind), [.heardWhole, .heardDifferently])
        XCTAssertTrue(combined.notes[1].message.contains("which the take's transcript explains"), combined.notes[1].message)
        XCTAssertEqual(combined.joins[0].findings.map(\.slip), [true], "the join reads as differing, not cut off")
        XCTAssertFalse(combined.joins[0].clipped)
    }

    func testAJoinNotHeardKeepsWhatTheLevelsFound() {
        let summary = ListenSummary(engine: "fake", joins: [
            HeardJoin(time: t(30), said: "that | Now", heard: "", findings: [], clipIDs: ["clip_voc1", "clip_voc2"], cached: false, skipped: "couldn't listen")
        ], heard: 0, cached: 0, secondsPerJoin: nil)
        let combined = CutCheck.combine(problems: [clipped("clip_voc1", .end, at: 30, margin: 27.4)], notes: [], summary: summary)
        XCTAssertEqual(combined.problems.map(\.kind), [.clippedWord])
        XCTAssertEqual(combined.commands.count, 1)
    }

    func testCutWordsComeFromTheTrackThatHasThem() throws {
        // The mic and a screen recording's sound cut together: the screen's
        // file has no words there, which mustn't blank out the mic's.
        let project = APIFixture.project()
        let voice = try XCTUnwrap(project.audioTracks.first { $0.id == "trk_voice" })
        let camera = try XCTUnwrap(project.media("med_camera")), screen = try XCTUnwrap(project.media("med_screen"))
        let edges = [
            CutCheck.Edge(clip: voice.clips[0], edge: .end, other: "clip_voc2", media: camera, cutAway: 30...32),
            CutCheck.Edge(clip: voice.clips[0], edge: .end, other: "clip_voc2", media: screen, cutAway: 30...32),
            CutCheck.Edge(clip: voice.clips[1], edge: .start, other: "clip_voc1", media: camera, removed: 30...32),
        ]
        let words: [String: [CutAudit.Word]] = ["med_camera": [
            CutAudit.Word(text: "my", start: 29.5, end: 29.9), CutAudit.Word(text: "own", start: 29.92, end: 30.3),
            CutAudit.Word(text: "um", start: 30.5, end: 30.8), CutAudit.Word(text: "Text", start: 31.8, end: 32.1),
        ]]
        let (past, before) = CutCheck.cutWords(beside: edges, words: words)
        XCTAssertEqual(past, ["own", "um"], "\"own\" runs through the edge")
        XCTAssertEqual(before, ["um", "Text"])
    }

    /// The take of `testListeningHearsEachJoinAndFlagsWhatsCutOff`, and
    /// what's heard at its joins: "that [because] Now", "be" heard.
    private func listeningHarness(edit: (inout Project) -> Void = { _ in }) throws -> (ServiceHarness, [Double: [CutListen.Word]]) {
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.0), (30.02, 30.24), (33, 33.8)], edit: edit)
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "So", start: t(1), end: t(3.6)),
            TranscriptWord(text: "that", start: t(29.5), end: t(30)),
            TranscriptWord(text: "because", start: t(30.02), end: t(30.24)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let lead = CutListen.padding + CutListen.span
        return (h, [
            27: [CutListen.Word(text: "that", start: lead - 0.5, end: lead), CutListen.Word(text: "be", start: lead + 0.01, end: lead + 0.1),
                 CutListen.Word(text: "Now.", start: lead + 1, end: lead + 1.8)],
            -3: [CutListen.Word(text: "So", start: lead + 1, end: lead + 3.6)]
        ])
    }

    func testListeningDoesntCompareWhereTheTakeHasNoTranscript() async throws {
        // Without the take's words, everything heard would read as a word
        // the take doesn't keep.
        let (h, script) = try listeningHarness()
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = nil
        let ear = FakeEar(script)
        h.service.cutListening = ([ear.ear], ear.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertEqual(listened.joins.count, 3)
        XCTAssertTrue(listened.joins.allSatisfy { $0.findings.isEmpty }, "\(listened.joins)")
        XCTAssertEqual(listened.joins[1].heard, "that | be Now.", "still heard, to read")
        XCTAssertEqual(listened.joins[1].skipped, "no transcript")
        XCTAssertTrue(heardCutOff(result).isEmpty, "\(result.problems)")
        let said = result.warnings.filter { $0.contains("No transcript") }
        XCTAssertEqual(said.count, 1, "said once: \(result.warnings)")
        XCTAssertTrue(said[0].contains("take1-camera.wav"), said[0])
        XCTAssertTrue(result.readableText.contains("not compared: no transcript"), result.readableText)
    }

    func testListeningHearsWhatExportPlaysWhenATrackIsSoloed() throws {
        var project = APIFixture.project()
        var second = Track(id: "trk_voice2", kind: .audio, name: "Voice 2", clips: [])
        second.rippleMode = .cut
        project.audioTracks.insert(second, at: 1)
        XCTAssertEqual(CutCheck.playedSpeechTracks(project).map(\.id), ["trk_voice", "trk_voice2"])
        project.audioTracks[1].solo = true
        XCTAssertEqual(CutCheck.playedSpeechTracks(project).map(\.id), ["trk_voice2"], "only the soloed one plays")
        project.audioTracks[1].solo = false
        let music = try XCTUnwrap(project.audioTracks.firstIndex { $0.id == "trk_music" })
        project.audioTracks[music].solo = true
        XCTAssertEqual(CutCheck.playedSpeechTracks(project).map(\.id), [], "the music plays alone")
    }

    func testListeningToASoloedTrackComparesItsWordsOnly() async throws {
        // The voice track muted by another track's solo: nothing it says
        // is played, so nothing of it is heard or compared.
        let (h, script) = try listeningHarness { project in
            let music = project.audioTracks.firstIndex { $0.id == "trk_music" }!
            project.audioTracks[music].solo = true
        }
        defer { h.close() }
        let ear = FakeEar(script)
        h.service.cutListening = ([ear.ear], ear.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        XCTAssertNil(result.listened, "\(String(describing: result.listened))")
        XCTAssertTrue(result.warnings.contains { $0.contains("soloed") }, "\(result.warnings)")
        XCTAssertEqual(ear.calls, 0)
    }

    func testNothingHeardWhereTheTakeHasWordsIsntCachedOrBlamedOnTheCut() async throws {
        let (h, _) = try listeningHarness()
        defer { h.close() }
        let ear = FakeEar([:])
        h.service.cutListening = ([ear.ear], ear.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertTrue(heardCutOff(result).isEmpty, "\(result.problems)")
        XCTAssertEqual(listened.joins.map(\.skipped), ["nothing heard", "nothing heard", nil], "the end has no words to hear")
        // Asked twice where there are words, once where there aren't.
        XCTAssertEqual(ear.calls, 5)
        XCTAssertEqual(result.warnings.filter { $0.contains("Nothing was heard") }.count, 1, "\(result.warnings)")
        // Not cached: asked again next time.
        let again = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        XCTAssertEqual(again.listened?.cached, 1)
        XCTAssertEqual(ear.calls, 9)
    }

    func testNothingHeardFallsBackToTheNextEngine() async throws {
        let (h, script) = try listeningHarness()
        defer { h.close() }
        let silent = FakeEar([:], engine: "silent")
        let fallback = FakeEar(script, engine: "fallback")
        h.service.cutListening = ([silent.ear, fallback.ear], silent.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertEqual(listened.joins.map(\.skipped), [nil, nil, nil])
        XCTAssertEqual(heardCutOff(result).map(\.start), [t(30)])
    }

    func testAnEngineFailingAtOneJoinStillHearsTheRest() async throws {
        let (h, script) = try listeningHarness()
        defer { h.close() }
        let ear = FakeEar(script)
        ear.failing = [-3]
        h.service.cutListening = ([ear.ear], ear.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertEqual(listened.joins.map(\.time), [t(0), t(30), t(60)])
        XCTAssertEqual(listened.joins[0].skipped, "couldn't listen")
        XCTAssertNil(listened.joins[1].skipped)
        XCTAssertEqual(heardCutOff(result).map(\.start), [t(30)])
        XCTAssertEqual(result.warnings.filter { $0.contains("couldn't listen") }.count, 1, "\(result.warnings)")

        // Failing everywhere now: what was heard before still comes from
        // the cache.
        ear.failing = [nil]
        let again = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        XCTAssertEqual(again.listened?.cached, 2)
        XCTAssertEqual(heardCutOff(again).map(\.start), [t(30)])
    }

    func testAnEngineThatKeepsFailingFallsBackToTheNext() async throws {
        let (h, script) = try listeningHarness()
        defer { h.close() }
        let broken = FakeEar(script, engine: "broken")
        broken.failing = [nil]
        let fallback = FakeEar(script, engine: "fallback")
        h.service.cutListening = ([broken.ear, fallback.ear], broken.mix)
        let result = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let listened = try XCTUnwrap(result.listened)
        XCTAssertEqual(listened.joins.map(\.skipped), [nil, nil, nil], "the second fails over, and the first is heard again with the fallback")
        XCTAssertEqual(broken.calls, 2, "given up on after failing twice in a row")
        XCTAssertEqual(listened.engine, "broken, then fallback")
        XCTAssertEqual(heardCutOff(result).map(\.start), [t(30)])
        XCTAssertTrue(result.warnings.contains { $0.contains("listening with fallback") }, "\(result.warnings)")
    }

    func testANewModelHearsAgain() async throws {
        let (h, script) = try listeningHarness()
        defer { h.close() }
        let ear = FakeEar(script)
        h.service.cutListening = ([ear.ear], ear.mix)
        _ = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        let updated = FakeEar(script, model: "2")
        h.service.cutListening = ([updated.ear], updated.mix)
        let again = try await CheckRequest(cuts: true, listen: true).run(on: h.service, context: h.context)
        XCTAssertEqual(again.listened?.cached, 0)
        XCTAssertEqual(updated.calls, 3)
    }

    func testACutOfAFillerAndTheWordBeforeItIsJudgedOverTheWholeCut() async throws {
        // "And [the like,] challenge": a 4 s cut that took "the like" and
        // nothing else said. The take's 3 s past the edge don't reach the
        // cut's end, so the check reads the transcript over all of it.
        let h = try voicedHarness(words: [(1, 3.6), (29.4, 29.8), (30.05, 30.35), (30.35, 30.65), (34.2, 34.8)]) { project in
            for tracks in [\Project.videoTracks, \Project.audioTracks] {
                for track in project[keyPath: tracks].indices {
                    for clip in project[keyPath: tracks][track].clips.indices where project[keyPath: tracks][track].clips[clip].linkGroup == "lnk_b" {
                        project[keyPath: tracks][track].clips[clip].sourceStart = t(34)
                    }
                }
            }
        }
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "And", start: t(29.4), end: t(29.8)),
            TranscriptWord(text: "the", start: t(30.05), end: t(30.35)),
            TranscriptWord(text: "like,", start: t(30.35), end: t(30.65)),
            TranscriptWord(text: "challenge", start: t(34.2), end: t(34.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.first?.cut?.beforeFiller, "the", "\(result.problems)")
    }

    func testACutInAShortGapBetweenWordsIsFine() async throws {
        // "convex. [It's]": the first piece ends at 30, in the 40 ms gap
        // before the next word, which is cut. The sound alone can't tell
        // that gap from a closure inside a word; the transcript's word
        // boundary by it can ("It's" starts late, as Bark has it).
        let h = try voicedHarness(words: [(1, 3.6), (29.4, 30.0), (30.04, 30.6), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = nil
        let unheard = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(unheard.problems.map(\.kind), [.clippedWord], "without the transcript")

        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "convex.", start: t(29.4), end: t(30)),
            TranscriptWord(text: "It's", start: t(30.15), end: t(30.6)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertTrue(result.notes.isEmpty, "\(result.notes)")
    }

    func testAClipEndingJustBeforeTheLastWordOfItsSentenceIsClipped() async throws {
        // "lies about [time.]": the same gap, but the word cut after it ends
        // the sentence and the kept one doesn't. It sounds clean and leaves
        // the sentence hanging, so the fix finishes it.
        let h = try voicedHarness(words: [(1, 3.6), (29.4, 30.0), (30.04, 30.4), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "about", start: t(29.4), end: t(30)),
            TranscriptWord(text: "time.", start: t(30), end: t(30.4)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let cut = try XCTUnwrap(result.problems.first?.cut)
        XCTAssertEqual(cut.lastWordCut, "time.")
        XCTAssertNil(cut.drops)
        XCTAssertEqual(cut.fixKind, .trimToPause)
        let to = try XCTUnwrap(cut.to)
        XCTAssertGreaterThan(to, t(30.4), "past \"time.\"")
        XCTAssertLessThan(to, t(30.5))
        let text = result.readableText
        XCTAssertTrue(text.contains("Clipped word at the end of clip_voc1: it ends just before \"time.\", the last word of the sentence, which is cut. Trim the end "), text)
        XCTAssertTrue(text.contains(" s later, past \"time.\", into the pause after it."), text)
        let json = String(decoding: try JSONEncoder().encode(cut), as: UTF8.self)
        XCTAssertTrue(json.contains(#""lastWordCut":"time.""#), json)
    }

    func testAClipOpeningOnTheLastWordOfACutSentenceIsClipped() async throws {
        // "that [I've not seen other places] do, but": the second piece
        // starts in the gap before "do,", the end of the sentence the cut
        // took. It sounds clean and reads wrong, so the fix drops "do,".
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 30.0), (31.4, 31.95), (32.03, 32.25), (32.32, 32.6), (33, 33.8)])
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "that", start: t(29.5), end: t(30)),
            TranscriptWord(text: "places", start: t(31.4), end: t(31.95)),
            TranscriptWord(text: "do,", start: t(32.03), end: t(32.25)),
            TranscriptWord(text: "but", start: t(32.32), end: t(32.6)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(result.problems.map(\.kind), [.clippedWord])
        let cut = try XCTUnwrap(result.problems.first?.cut)
        XCTAssertEqual(cut.clipID, "clip_voc2")
        XCTAssertEqual(cut.fragment, "do,")
        XCTAssertEqual(cut.fixKind, .trimToPause)
        let to = try XCTUnwrap(cut.to)
        XCTAssertGreaterThan(to, t(30.25), "past \"do,\"")
        XCTAssertLessThan(to, t(30.32), "before \"but\"")
        let text = result.readableText
        XCTAssertTrue(text.contains("Clipped word at the start of clip_voc2: it opens on \"do,\", the last word of the sentence cut before it. Trim the start "), text)
        XCTAssertTrue(text.contains("past \"do,\", into the gap between words after it, dropping the leftover."), text)
        let json = String(decoding: try JSONEncoder().encode(cut), as: UTF8.self)
        XCTAssertTrue(json.contains(#""fragment":"do,""#), json)
    }

    func testTheLastWordIsntCutWhenTheNextClipPlaysIt() async throws {
        // "about [time.]" again, but the second piece starts where the first
        // ends, at another speed: not a through-edit, so the join is checked,
        // but it plays "time." whole and the sentence isn't left hanging.
        let h = try voicedHarness(words: [(1, 3.6), (29.4, 30.0), (30.04, 30.4), (33, 33.8)]) { project in
            for tracks in [\Project.videoTracks, \Project.audioTracks] {
                for track in project[keyPath: tracks].indices {
                    for clip in project[keyPath: tracks][track].clips.indices where project[keyPath: tracks][track].clips[clip].linkGroup == "lnk_b" {
                        project[keyPath: tracks][track].clips[clip].sourceStart = t(30)
                        project[keyPath: tracks][track].clips[clip].speed = 1.1
                    }
                }
            }
        }
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "about", start: t(29.4), end: t(30)),
            TranscriptWord(text: "time.", start: t(30), end: t(30.4)),
            TranscriptWord(text: "Now", start: t(33), end: t(33.8))
        ])
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "\(result.problems)")

        // With nothing after the first piece, "time." is gone.
        try h.service.apply(ApplyRequest(label: "remove", commands: [.removeClips(clipIDs: ["clip_voc2"])]), context: h.context)
        let alone = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertEqual(alone.problems.first?.cut?.lastWordCut, "time.", "\(alone.problems)")
    }

    func testAMarginalJoinIsANote() async throws {
        // The first piece's last 30 ms trail off 12 dB under the speech, and
        // what's cut after them is the rest of that soft tail, then a pause:
        // nothing at speech level is cut off, so only the level says how it
        // sounds. (A cut word running on past the cut would clip it.)
        let h = try voicedHarness(words: [(1, 3.6), (29, 29.97), (33, 33.8)], soft: [(29.97, 30.1, 12)])
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "marginal doesn't fail: \(result.problems)")
        XCTAssertTrue(result.commands.isEmpty)
        XCTAssertEqual(result.notes.map(\.kind), [.marginalJoin])
        let cut = try XCTUnwrap(result.notes.first?.cut)
        XCTAssertEqual(cut.clipID, "clip_voc1")
        XCTAssertEqual(try XCTUnwrap(cut.margin), 12, accuracy: 2)
        XCTAssertNil(cut.fixKind)
        XCTAssertNil(cut.fix)
        let text = result.readableText
        XCTAssertTrue(text.contains("no problems.\nNotes (not problems):\n  00:30.000  Marginal join at the end of clip_voc1: the clip's last 25 ms is "), text)
        XCTAssertTrue(text.contains(" dB under the speech (clean is 15 or more, clipped under 9). Listen to it with tandem clip.  On: clip_voc1 take1-camera, clip_voc2 take1-camera"), text)
    }

    func testCutsInPausesAreFine() async throws {
        let h = try voicedHarness(words: [(1, 3.6), (29.5, 29.9), (32.3, 32.8)])
        defer { h.close() }
        let result = try await CheckRequest(from: t(25), to: t(35), cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok, "\(result.problems)")
        XCTAssertEqual(result.cuts, 2, "only the cut in the stretch checked")
        XCTAssertTrue(result.readableText.contains("no problems."), result.readableText)
    }

    func testCutsWithNoSoundToReadSaySo() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try await CheckRequest(cuts: true).run(on: h.service, context: h.context)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.warnings, ["Couldn't read the sound of take1-camera.mov, so its cuts weren't checked."])
    }

    func testTheRequestReadsFriendlyTimes() throws {
        let request = try ServiceJSON.decodeRequest(CheckRequest.self, from: Data(#"{"from": "5:40", "to": 371, "quick": true, "cuts": true}"#.utf8))
        XCTAssertEqual(request.from, t(340))
        XCTAssertEqual(request.to, t(371))
        XCTAssertEqual(request.quick, true)
        XCTAssertEqual(request.cuts, true)
    }
}
