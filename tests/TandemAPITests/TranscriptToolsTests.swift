import XCTest
@testable import TandemAPI
@testable import TandemCore
import TandemMedia

final class TranscriptToolsTests: XCTestCase {
    func testWordsMapThroughSourceStartAndSpeed() {
        let transcript = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "before", start: t(8), end: t(9)),
            TranscriptWord(text: "straddles", start: t(9.5), end: t(10.5)),
            TranscriptWord(text: "inside", start: t(12), end: t(13)),
            TranscriptWord(text: "after", start: t(21), end: t(22))
        ])
        // Plays file 10...20 at double speed, starting at 100 on the timeline.
        let clip = Clip(id: "clip_fast", content: .media(mediaID: "med_a"), start: t(100), duration: t(5), sourceStart: t(10), speed: 2)
        let track = Track(id: "trk_voice", kind: .audio, name: "Voice", clips: [clip], rippleMode: .cut)
        let words = TranscriptTools.words(transcript, playedBy: clip, on: track)
        XCTAssertEqual(words.map(\.text), ["straddles", "inside"], "half of \"straddles\" plays, so it stays")
        XCTAssertEqual(words[0].start, t(100), "clamped to the clip's start")
        XCTAssertEqual(words[0].end, t(100.25))
        XCTAssertEqual(words[1].start, t(101))
        XCTAssertEqual(words[1].end, t(101.5))
        XCTAssertEqual(TranscriptTools.timelineTime(ofMediaTime: t(20), in: clip), t(105))
    }

    func testTimelineTranscriptSkipsCutMaterial() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.transcript(id: nil, from: nil, to: nil)
        let text = result.words.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("Second section. Now let's look"), text)
        XCTAssertFalse(text.contains("Um"), "file time 30-32 was cut out")
        let now = try XCTUnwrap(result.words.first { $0.text == "Now" })
        XCTAssertEqual(now.start, t(30.5))
        XCTAssertEqual(now.clipID, "clip_voc2")
        XCTAssertTrue(result.readableText.contains("00:30.500  Now let's look at decision models again."), result.readableText)
    }

    func testClipAndMediaTranscripts() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let clip = try h.service.transcript(id: "clip_voc2", from: nil, to: nil)
        XCTAssertTrue(clip.timelineTimes)
        XCTAssertEqual(clip.words.first?.text, "Now")
        let camera = try h.service.transcript(id: "clip_cam2", from: t(31), to: nil)
        XCTAssertEqual(camera.words.first?.text, "let's", "a camera clip plays the same words as its voice clip")
        let media = try h.service.transcript(id: "med_camera", from: t(30), to: t(32))
        XCTAssertFalse(media.timelineTimes)
        XCTAssertEqual(media.words.map(\.text), ["Um,", "wait."])
        assertServiceError(.unavailable) { _ = try h.service.transcript(id: "med_music", from: nil, to: nil) }
        assertServiceError(.invalid) { _ = try h.service.transcript(id: "clip_txt1", from: nil, to: nil) }
        assertServiceError(.notFound) { _ = try h.service.transcript(id: "clip_nope", from: nil, to: nil) }
    }

    func testSearchMapsHitsToTheTimeline() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.search(phrase: "decision models", limit: nil)
        XCTAssertEqual(result.hits.map(\.start), [t(2.55), t(7.55), t(31.65)])
        XCTAssertEqual(result.hits.map(\.end), [t(3.6), t(8.5), t(32.5)])
        XCTAssertEqual(Set(result.hits[2].clipIDs), ["clip_voc2", "clip_cam2"])
        XCTAssertEqual(result.hits[2].mediaStart, t(33.65))
        XCTAssertEqual(result.hits[0].after, "They help you choose")
        XCTAssertFalse(result.hits.contains(where: \.partial))
        XCTAssertTrue(result.unused.isEmpty)
    }

    func testSearchFindsMaterialThatWasCutOut() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.search(phrase: "um wait", limit: nil)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.unused.map(\.mediaStart), [t(30.5)])
        XCTAssertTrue(result.readableText.contains("In the source but not on the timeline"), result.readableText)
    }

    func testSearchMarksPhrasesACutRunsThrough() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // "section um" starts in the first piece and ends in the cut material.
        let result = try h.service.search(phrase: "Section. Um", limit: nil)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertTrue(result.hits[0].partial)
        XCTAssertEqual(result.hits[0].start, t(29.45))
        XCTAssertEqual(result.hits[0].end, t(29.9), "the end of \"section.\", the last of its words that plays")
        XCTAssertEqual(Set(result.hits[0].clipIDs), ["clip_voc1", "clip_cam1"])
    }

    func testAWordACutRunsThroughIsSaidOnce() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // Cut 29.6-29.7 out of "section." (file 29.45-29.9): 0.15 s of it
        // before the cut, 0.2 s after.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(29.6), end: t(29.7)), trackIDs: nil))
        let spoken = try h.service.transcript(id: nil, from: nil, to: nil).words
        XCTAssertEqual(spoken.filter { $0.text == "section." }.count, 1)
        let section = try XCTUnwrap(spoken.first { $0.text == "section." })
        XCTAssertEqual(section.start, t(29.6), "on the piece after the cut, where most of it plays")
        XCTAssertEqual(section.end, t(29.8))
        XCTAssertNotEqual(section.clipID, "clip_voc1")
        let captions = try h.service.captions(CaptionsRequest(), context: h.context)
        let text = captions.captions.map(\.text).joined(separator: " ")
        XCTAssertEqual(text.components(separatedBy: "section.").count - 1, 1, text)
        // Each clip's words in the dump show it once too.
        let dump = try h.service.timeline(from: t(25), to: t(35), format: .text, words: true).text ?? ""
        XCTAssertEqual(dump.components(separatedBy: "section.").count - 1, 1, dump)
        let search = try h.service.search(phrase: "second section", limit: nil)
        XCTAssertEqual(search.hits.count, 2, "\"second\" before the cut, \"section.\" after it")
        XCTAssertTrue(search.hits.allSatisfy(\.partial))
    }

    func testAWordMostlyCutOutIsGone() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // "decision" is file (and timeline) 2.55-3.0; cut 2.6-2.95 out of it.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(2.6), end: t(2.95)), trackIDs: nil))
        let text = try h.service.transcript(id: nil, from: nil, to: t(10)).words.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.hasPrefix("So today we talk about models. They help you choose"), text)
        let clip = try h.service.transcript(id: "clip_voc1", from: nil, to: nil).words.map(\.text)
        XCTAssertFalse(clip.contains("decision"), "\(clip)")
    }

    /// The workbench short's numbers from end to end: "of" ran from 28.14
    /// to 29.22 over a silence from 28.26 to 29.05, "and" from 30.18 to
    /// 31.50 over one from 30.74 to 31.40. Trimmed to the voice, both pauses
    /// show, and a cut in the first one says "of" once.
    func testTheWorkbenchPausesAndTheCutAfterWorkbench() throws {
        var peaks = [Float](repeating: 0.001, count: 3500)
        for (start, end) in [(27.66, 28.26), (29.05, 30.74), (31.40, 31.68)] {
            for index in Int((start * 100).rounded())..<Int((end * 100).rounded()) { peaks[index] = 0.25 }
        }
        let raw = Transcript(language: "en-US", engine: "SpeechAnalyzer", words: [
            TranscriptWord(text: "a", start: t(27.48), end: t(27.66)),
            TranscriptWord(text: "workbench", start: t(27.66), end: t(28.14)),
            TranscriptWord(text: "of", start: t(28.14), end: t(29.22)),
            TranscriptWord(text: "this", start: t(29.22), end: t(29.40)),
            TranscriptWord(text: "size", start: t(29.40), end: t(30.18)),
            TranscriptWord(text: "and", start: t(30.18), end: t(31.50)),
            TranscriptWord(text: "then", start: t(31.50), end: t(31.68))
        ])
        var project = APIFixture.project()
        // The take from file 25 at the start of the timeline, uncut.
        project.videoTracks = project.videoTracks.map { track in
            var track = track
            if track.rippleMode == .cut { track.clips = [] }
            return track
        }
        project.audioTracks[0].clips = [
            Clip(id: "clip_voc", content: .media(mediaID: "med_camera"), start: t(0), duration: t(10), sourceStart: t(25))
        ]
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        h.analysis.transcripts["med_camera"] = raw
        XCTAssertTrue(try h.service.pauses(minimum: t(0.45), from: nil, to: nil).pauses.isEmpty, "the engine's times hide them")

        h.analysis.transcripts["med_camera"] = raw.aligned(to: Waveform(samplesPerSecond: 100, peaks: peaks))
        let pauses = try h.service.pauses(minimum: t(0.45), from: nil, to: nil).pauses
        XCTAssertEqual(pauses.map(\.start), [t(3.26), t(5.74)])
        XCTAssertEqual(pauses.map(\.end), [t(4.05), t(6.40)])
        XCTAssertEqual(pauses.map(\.before), ["a workbench", "of this size and"])

        // Cut file 28.35-28.95 (timeline 3.35-3.95), inside the first pause.
        try h.apply(.rippleDeleteRange(range: TimeRange(start: t(3.35), end: t(3.95)), trackIDs: nil))
        let text = try h.service.captions(CaptionsRequest(), context: h.context).captions.map(\.text).joined(separator: " ")
        XCTAssertEqual(text, "a workbench of this size and then")
    }

    func testSearchIgnoresCaseAndPunctuation() {
        let transcript = Transcript(language: "en", engine: "fake", words: [
            TranscriptWord(text: "Don't", start: t(0), end: t(0.3)),
            TranscriptWord(text: "real-time", start: t(0.4), end: t(0.8)),
            TranscriptWord(text: "SYNC!", start: t(0.9), end: t(1.2))
        ])
        XCTAssertEqual(TranscriptTools.matches(of: "dont real time sync", in: transcript), [0...2])
        XCTAssertEqual(TranscriptTools.matches(of: "time sync", in: transcript), [1...2])
        XCTAssertEqual(TranscriptTools.matches(of: "sync now", in: transcript), [])
    }

    func testPausesInTimelineTime() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let result = try h.service.pauses(minimum: t(0.6), from: nil, to: nil)
        XCTAssertEqual(result.pauses.map(\.start), [t(3.6), t(6.3), t(9), t(29.9)])
        XCTAssertEqual(result.pauses.map(\.end), [t(5), t(7), t(29), t(30.5)])
        XCTAssertEqual(result.pauses[0].before, "talk about decision models.")
        XCTAssertEqual(result.pauses[0].after, "They help you choose")
        XCTAssertEqual(result.pauses[3].clipIDs, ["clip_voc1", "clip_voc2"], "the pause runs across the cut")
        let longer = try h.service.pauses(minimum: t(1), from: nil, to: nil)
        XCTAssertEqual(longer.pauses.map(\.start), [t(3.6), t(9)])
        let ranged = try h.service.pauses(minimum: t(0.6), from: t(5), to: t(29.5))
        XCTAssertEqual(ranged.pauses.map(\.start), [t(6.3), t(9)])
    }

    func testPausesSkipHolesAndUntranscribedClips() throws {
        var project = APIFixture.project()
        // Lift the second voice piece's first 2 s: a hole in the take isn't a pause.
        project.audioTracks[0].clips[1].start = t(32)
        project.audioTracks[0].clips[1].duration = t(28)
        project.audioTracks[0].clips[1].sourceStart = t(34)
        let map = TranscriptTools.speechMap(project, analysis: FakeAnalysis())
        let pauses = TranscriptTools.pauses(in: map, minimum: t(0.6))
        XCTAssertFalse(pauses.contains { $0.start == t(29.9) })

        let noTranscripts = FakeAnalysis()
        noTranscripts.transcripts = [:]
        let empty = TranscriptTools.speechMap(APIFixture.project(), analysis: noTranscripts)
        XCTAssertEqual(empty.missing, ["med_camera"])
        XCTAssertTrue(TranscriptTools.pauses(in: empty, minimum: t(0.6)).isEmpty)
    }

    func testTightenPlanIsFrameAlignedAndKeepsTheSilence() {
        let pause = Pause(start: t(3.6), end: t(5), duration: t(1.4), before: "", after: "", clipIDs: [])
        let cuts = TranscriptTools.plan([pause], keep: t(0.15), frameRate: .fps30)
        XCTAssertEqual(cuts.count, 1)
        let cut = cuts[0].cut
        // 3.6 + 0.075 = 3.675, up to the next frame (3.7); 5 - 0.075 = 4.925, down to 4.9.
        XCTAssertEqual(cut.start, Time.frames(111, at: .fps30))
        XCTAssertEqual(cut.end, Time.frames(147, at: .fps30))
        XCTAssertGreaterThanOrEqual((pause.duration - cut.duration).seconds, 0.15)
        // A pause that would lose less than a frame is left alone.
        let tiny = Pause(start: t(1), end: t(1.2), duration: t(0.2), before: "", after: "", clipIDs: [])
        XCTAssertTrue(TranscriptTools.plan([tiny], keep: t(0.15), frameRate: .fps30).isEmpty)
    }

    func testTightenDryRunThenApplyThenUndo() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let before = h.service.coordinator.project
        let plan = try h.service.tighten(TightenRequest(min: 0.6, keep: 0.15), context: h.context)
        XCTAssertEqual(plan.cuts.count, 4)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(h.service.coordinator.project, before, "a dry run changes nothing")
        XCTAssertEqual(plan.commands.count, 4)
        guard case .rippleDeleteRange(let latest, nil) = plan.commands[0] else { return XCTFail("expected a ripple delete") }
        XCTAssertEqual(latest.start, plan.cuts.last?.cut.start, "latest cut first")
        XCTAssertEqual(plan.durationAfter, plan.durationBefore - plan.removed)

        let applied = try h.service.tighten(TightenRequest(min: 0.6, keep: 0.15, apply: true), context: h.context)
        XCTAssertEqual(applied.applied?.revision, 2)
        XCTAssertEqual(applied.applied?.label, "Tighten 4 pauses to 0.150s")
        XCTAssertEqual(h.service.coordinator.project.duration, plan.durationAfter)
        // The words still line up with the picture and every pause is now short.
        let after = try h.service.pauses(minimum: t(0.2), from: nil, to: nil)
        XCTAssertTrue(after.pauses.allSatisfy { $0.duration <= t(0.2) }, "\(after.pauses)")
        XCTAssertEqual(h.service.coordinator.project.markers.first?.time, t(30) - plan.cuts.prefix(3).reduce(Time.zero) { $0 + $1.cut.duration })
        _ = try h.service.undo(expectedRevision: nil)
        XCTAssertEqual(h.service.coordinator.project, before)
    }

    func testTightenRefusesToDesyncALockedTake() throws {
        var project = APIFixture.project()
        project.videoTracks[1].locked = true
        let h = try ServiceHarness(project: project)
        defer { h.close() }
        let plan = try h.service.tighten(TightenRequest(), context: h.context)
        XCTAssertTrue(plan.warnings.contains { $0.contains("\"Camera\" is locked") }, "\(plan.warnings)")
        assertServiceError(.locked) { _ = try h.service.tighten(TightenRequest(apply: true), context: h.context) }
        assertServiceError(.badRequest) { _ = try h.service.tighten(TightenRequest(min: 0.5, keep: 0.5), context: h.context) }
    }
}

final class CaptionPlanningTests: XCTestCase {
    func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptTools.SpokenWord {
        TranscriptTools.SpokenWord(text: text, start: Time(seconds: start), end: Time(seconds: end), clipID: "clip_v", mediaID: "med_c", confidence: nil)
    }

    func testGroupsBreakAtWordCountSentencesAndPauses() {
        let words = [
            word("So", 0.00, 0.20), word("this", 0.22, 0.40), word("is", 0.42, 0.50), word("Convex.", 0.52, 1.00),
            word("It", 1.02, 1.10), word("syncs.", 1.12, 1.50),
            word("Later", 3.00, 3.40)
        ]
        let captions = TranscriptTools.captions(words, maxWords: 3, frameRate: .fps30)
        XCTAssertEqual(captions.map { $0.words.map(\.text).joined(separator: " ") }, ["So this is", "Convex.", "It syncs.", "Later"])
        for (a, b) in zip(captions, captions.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "captions overlap")
        }
        for caption in captions {
            XCTAssertEqual(caption.start.roundedToFrame(.fps30), caption.start)
            XCTAssertEqual(caption.end.roundedToFrame(.fps30), caption.end)
        }
        XCTAssertEqual(captions[3].end, Time(seconds: 3.6))
    }

    func testDuplicateVoiceTracksAreCaptionedOnce() {
        let words = [word("Hello", 0, 0.5), word("Hello", 0, 0.5), word("there", 0.6, 0.9), word("there", 0.6, 0.9)]
        let captions = TranscriptTools.captions(words, maxWords: 3, frameRate: .fps30)
        XCTAssertEqual(captions.map { $0.words.count }, [2])
    }
}

final class ShortLayoutTests: XCTestCase {
    func testCameraGoesToTheBottomUnlessItsFullFrame() {
        var pip = Clip(content: .media(mediaID: "med_c"), start: .zero, duration: Time(seconds: 2))
        pip.video = LayoutPreset.pipRight.apply(to: nil, role: .camera, shadowID: "fx_s")
        var full = pip
        full.video = LayoutPreset.full.apply(to: pip.video, role: .camera, shadowID: "fx_s")
        XCTAssertEqual(TandemService.portraitSlot(for: pip, role: .camera), .bottom)
        XCTAssertEqual(TandemService.portraitSlot(for: full, role: .camera), .full)
        XCTAssertEqual(TandemService.portraitSlot(for: pip, role: .screen), .top)
    }
}

/// Where `cards --insert` cuts the take for a section card's room: in the
/// pause beside the word a marker is on, not through it.
final class SectionCutTests: XCTestCase {
    /// "done." (10 to 10.5), a 1 s pause, "Now let's go." said without a
    /// break (11.5 to 12.4), a 0.15 s pause, "Next" (12.55 to 12.9), and
    /// "extraordinarily" (20 to 21) on its own. In camera file time, which
    /// is timeline time in the uncut take.
    static let words = [
        TranscriptWord(text: "done.", start: t(10), end: t(10.5)),
        TranscriptWord(text: "Now", start: t(11.5), end: t(11.8)),
        TranscriptWord(text: "let's", start: t(11.8), end: t(12.1)),
        TranscriptWord(text: "go.", start: t(12.1), end: t(12.4)),
        TranscriptWord(text: "Next", start: t(12.55), end: t(12.9)),
        TranscriptWord(text: "extraordinarily", start: t(20), end: t(21))
    ]

    /// The fixture's take with a clip on each of its tracks (Screen, Camera
    /// and Voice) for every piece: where it starts on the timeline and in
    /// the camera's file. One piece is the take uncut.
    static func take(_ pieces: [(at: Double, file: Double)] = [(0, 0)]) -> Project {
        var project = APIFixture.project()
        func cut(_ track: Track) -> [Clip] {
            let first = track.clips[0]
            // The screen runs 0.5 s ahead of the camera in its file.
            let offset = first.sourceStart - first.start
            return pieces.enumerated().map { index, piece in
                var clip = first
                clip.id = "\(first.id)_\(index)"
                clip.start = t(piece.at)
                clip.duration = t((index + 1 < pieces.count ? pieces[index + 1].at : 60) - piece.at)
                clip.sourceStart = t(piece.file) + offset
                clip.linkGroup = "lnk_\(index)"
                return clip
            }
        }
        for index in project.videoTracks.indices where project.videoTracks[index].rippleMode == .cut {
            project.videoTracks[index].clips = cut(project.videoTracks[index])
            project.videoTracks[index].transitions = []
        }
        for index in project.audioTracks.indices where project.audioTracks[index].rippleMode == .cut {
            project.audioTracks[index].clips = cut(project.audioTracks[index])
        }
        return project
    }

    func cut(at marker: Double, in project: Project = take(), words: [TranscriptWord] = words, reach: Time = SectionCard.maxCutShift) -> TranscriptTools.SectionCut {
        let transcript = Transcript(language: "en", engine: "fake", words: words)
        let map = TranscriptTools.speechMap(project) { $0.id == "med_camera" ? transcript : nil }
        return TranscriptTools.sectionCut(at: t(marker), in: map, project: project, reach: reach)
    }

    /// The word a cut moved off, and whether the marker was on it.
    func movedOff(_ cut: TranscriptTools.SectionCut) -> (String, Bool)? {
        if case .movedOff(let word, let on) = cut.reason { return (word.text, on) }
        return nil
    }

    func testAMarkerInAPauseStays() {
        XCTAssertEqual(cut(at: 11), TranscriptTools.SectionCut(time: t(11), reason: .clear))
        XCTAssertEqual(cut(at: 11.01), TranscriptTools.SectionCut(time: t(11), reason: .clear), "on its nearest frame")
        // Between two words said without a break there's nowhere better.
        XCTAssertEqual(cut(at: 12.1), TranscriptTools.SectionCut(time: t(12.1), reason: .clear))
    }

    func testAMarkerOnAWordMovesIntoThePauseBeforeIt() throws {
        // On "Now", after a 1 s pause: 0.2 s of the pause stays before it.
        let on = cut(at: 11.5)
        XCTAssertEqual(on.time, t(11.3))
        XCTAssertTrue(try XCTUnwrap(movedOff(on)) == ("Now", true), "\(on.reason)")
        // Just before it, too close to keep its first sound.
        let near = cut(at: 11.45)
        XCTAssertEqual(near.time, t(11.3))
        XCTAssertTrue(try XCTUnwrap(movedOff(near)) == ("Now", false), "\(near.reason)")
        // Just inside it, where a transcript that starts it late would put the marker.
        XCTAssertEqual(cut(at: 11.6).time, t(11.3), "0.3 s back, as far as a cut goes")
        // After a pause under 0.4 s, half way through it, on a frame:
        // 12.475 is a quarter of a frame past frame 374.
        let short = cut(at: 12.55)
        XCTAssertEqual(short.time, Time.frames(374, at: .fps30))
        XCTAssertTrue(try XCTUnwrap(movedOff(short)) == ("Next", true), "\(short.reason)")
        // A short card's quicker wipes let it move less: as far as it may.
        XCTAssertEqual(cut(at: 11.5, reach: t(0.1)).time, t(11.4))
    }

    func testAMarkerInAWordsSecondHalfMovesIntoThePauseAfterIt() throws {
        // On the end of "done.", the last word of the section before.
        let end = cut(at: 10.45)
        XCTAssertEqual(end.time, t(10.7))
        XCTAssertTrue(try XCTUnwrap(movedOff(end)) == ("done.", true), "\(end.reason)")
    }

    func testAMarkerDeepInAWordStays() {
        let deep = cut(at: 20.5)
        XCTAssertEqual(deep.time, t(20.5))
        guard case .inSpeech(let word) = deep.reason else { return XCTFail("\(deep.reason)") }
        XCTAssertEqual(word.text, "extraordinarily")
    }

    /// A pause tightened with its cut off centre: the room goes at the cut
    /// already there, a frame from the middle of the pause, so the take
    /// isn't cut again a frame away from it.
    func testTheRoomGoesAtACutAlreadyInThePause() throws {
        // File 10.6 to 11.45 cut out: "Now" at 10.65, 0.05 s after the cut.
        let tightened = cut(at: 10.65, in: Self.take([(0, 0), (10.6, 11.45)]))
        XCTAssertEqual(tightened.time, t(10.6))
        XCTAssertTrue(try XCTUnwrap(movedOff(tightened)) == ("Now", true), "\(tightened.reason)")
    }

    /// A jump cut right on the word's start: the voice doesn't play on
    /// across it, so room there clips nothing more than the cut does, and
    /// moving off it would leave a sliver of the shot before after the card.
    func testAJumpCutOnTheWordIsWhereTheRoomGoes() {
        // File 10.6 to 11.5 cut out: "Now" starts the second piece.
        XCTAssertEqual(cut(at: 10.6, in: Self.take([(0, 0), (10.6, 11.5)])), TranscriptTools.SectionCut(time: t(10.6), reason: .clear))
    }

    /// A clip split on the word's start with the voice running on across
    /// it is no place for the room: the word's first sound is before it.
    func testASplitOnTheWordIsNoPlaceForTheRoom() {
        XCTAssertEqual(cut(at: 11.5, in: Self.take([(0, 0), (11.5, 11.5)])).time, t(11.3))
    }

    /// Never a piece of a clip under a frame long: in a 0.06 s pause the
    /// nearest frame to its middle is half a frame from a split already
    /// there (off the frames, 0.01 s before "Next"), so the room goes there.
    func testNoSliverUnderAFrame() {
        var words = Self.words
        words[4] = TranscriptWord(text: "Next", start: t(12.46), end: t(12.9))
        XCTAssertEqual(cut(at: 12.46, in: Self.take([(0, 0), (12.45, 12.45)]), words: words).time, t(12.45))
        XCTAssertEqual(cut(at: 12.46, words: words).time, Time.frames(373, at: .fps30), "the middle's nearest frame, uncut")
    }

    func testWithoutATranscriptTheCutStaysOnTheMarker() {
        let project = Self.take()
        let map = TranscriptTools.speechMap(project) { _ in nil }
        XCTAssertEqual(TranscriptTools.sectionCut(at: t(11.5), in: map, project: project), TranscriptTools.SectionCut(time: t(11.5), reason: .untranscribed(mediaIDs: ["med_camera"])))
    }

    /// Word edges come from the voice. The engine runs its words end to
    /// end, so "done." swallows the pause and "Now" starts at 11.6, 0.1 s
    /// after the voice does. On the engine's times there's no pause and the
    /// cut would land in the voice; on the voice's, it keeps 0.2 s of
    /// silence before it.
    func testTheCutKeepsClearOfTheVoiceNotTheEnginesTimes() {
        var peaks = [Float](repeating: 0.001, count: 3000)
        for (start, end) in [(10.0, 10.5), (11.5, 12.4), (12.55, 12.9)] {
            for index in Int((start * 100).rounded())..<Int((end * 100).rounded()) { peaks[index] = 0.25 }
        }
        let engine = [
            TranscriptWord(text: "done.", start: t(10), end: t(11.6)),
            TranscriptWord(text: "Now", start: t(11.6), end: t(11.8)),
            TranscriptWord(text: "let's", start: t(11.8), end: t(12.1)),
            TranscriptWord(text: "go.", start: t(12.1), end: t(12.55)),
            TranscriptWord(text: "Next", start: t(12.55), end: t(12.9))
        ]
        let voice = Transcript(language: "en", engine: "SpeechAnalyzer", words: engine).aligned(to: Waveform(samplesPerSecond: 100, peaks: peaks))
        XCTAssertEqual(voice.words.map(\.start), [t(10), t(11.5), t(11.8), t(12.1), t(12.55)])
        XCTAssertEqual(cut(at: 11.6, words: engine).time, t(11.6))
        XCTAssertEqual(cut(at: 11.6, words: voice.words).time, t(11.3))
    }
}
