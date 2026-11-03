import XCTest
@testable import TandemMedia

/// `GapSound` on made-up takes (`Take`, from SpeechEnergyTests): what's in
/// the sound under a gap the transcript has between two words, and where
/// tighten's cut goes in it.
final class GapSoundTests: XCTestCase {
    /// One track playing `take` with its file time as timeline time.
    private func layer(_ take: Take, name: String = "Voice") -> SoundLayer {
        let energy = take.energy
        let placer = CutPlacer(energy, levels: SpeechLevels(of: [energy]))
        return SoundLayer(name: name, pieces: [SoundLayer.Piece(timeline: energy.start..<energy.end, mediaStart: energy.start, speed: 1, placer: placer)])
    }

    private func listen(
        _ layers: [SoundLayer], gap: ClosedRange<Double>, before: ClosedRange<Double>, after: ClosedRange<Double>
    ) throws -> GapSound {
        try XCTUnwrap(GapSound.listen(gap: gap, before: before, after: after, layers: layers))
    }

    private let frame = 1.0 / 24

    func testAPlainPauseIsCutFromTheSoundsEdges() throws {
        // "...that's it. | So the..." with 1 s between them.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let sound = try listen([layer(take)], gap: 11.0...12.0, before: 10.5...11.0, after: 12.0...12.5)
        XCTAssertEqual(sound.span.lowerBound, 11.0, accuracy: 0.011)
        XCTAssertEqual(sound.span.upperBound, 12.0, accuracy: 0.011)
        XCTAssertTrue(sound.heard.isEmpty, "\(sound.heard)")
        XCTAssertEqual(sound.pauses.count, 1)

        // A sentence's 0.4 s, half after the last word's sound and half
        // before the next one's.
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 1)
        let placed = try XCTUnwrap(cuts.first)
        XCTAssertEqual(placed.from, sound.span.lowerBound + 0.2, accuracy: 0.001)
        XCTAssertEqual(placed.to, sound.span.upperBound - 0.2, accuracy: 0.001)
        let joins = GapSound.judge([layer(take)], from: placed.from, to: placed.to)
        XCTAssertEqual(joins.start.verdict, .clean)
        XCTAssertEqual(joins.end.verdict, .clean)
    }

    func testTheLeastKeptAtAJoinIsWhatTandemCutKeeps() throws {
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let sound = try listen([layer(take)], gap: 11.0...12.0, before: 10.5...11.0, after: 12.0...12.5)
        // tandem cut keeps at least 30 ms after the word before and 80 ms
        // before the word after, whose sound can start before its burst
        // ("processed" on the Ian video). Tighten keeps the same, so Mike's
        // 0.08 s mid-sentence keep is 0.11 s: 30 ms and 80 ms.
        let mid = try XCTUnwrap(sound.place(keep: 0.08, minimum: 0.5, frame: frame).get().first)
        XCTAssertEqual(mid.from - sound.span.lowerBound, CutPlanner.minimumTail, accuracy: 0.001)
        XCTAssertEqual(sound.span.upperBound - mid.to, CutPlanner.minimumLead, accuracy: 0.001)
        XCTAssertEqual(mid.latest, sound.span.upperBound - CutPlanner.minimumLead, accuracy: 0.001)
        XCTAssertEqual(mid.earliest, sound.span.lowerBound + CutPlanner.minimumTail, accuracy: 0.001)
        // A comma's 0.12 s is still 0.12 s: as even as the minimums let it,
        // 40 ms after and 80 ms before.
        let comma = try XCTUnwrap(sound.place(keep: 0.12, minimum: 0.5, frame: frame).get().first)
        XCTAssertEqual(comma.from - sound.span.lowerBound, 0.04, accuracy: 0.001)
        XCTAssertEqual(sound.span.upperBound - comma.to, 0.08, accuracy: 0.001)
    }

    func testEachQuietStretchBesideSoundIsCutAndTheKeepCountsTheSound() throws {
        // A click of someone off mic in the middle of a 2 s pause. Each side
        // of it is cut, and what's left from "it." to "So" is the keep: the
        // click itself, 30 ms either side of it, and the rest shared out
        // after "it." and before "So" as a plain gap shares it.
        let take = Take(length: 6, words: [(10.5, 11.0), (13.0, 13.5)], softWords: [(11.8, 11.9, 20)])
        let sound = try listen([layer(take)], gap: 11.0...13.0, before: 10.5...11.0, after: 13.0...13.5)
        let click = try XCTUnwrap(sound.heard.first)
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 2, "\(cuts)")
        let (first, second) = (cuts[0], cuts[1])
        XCTAssertEqual(first.to, click.range.lowerBound - 0.03, accuracy: 0.001)
        XCTAssertEqual(second.from, click.range.upperBound + 0.03, accuracy: 0.001)
        let kept = (sound.span.upperBound - sound.span.lowerBound) - cuts.reduce(0) { $0 + ($1.to - $1.from) }
        XCTAssertEqual(kept, 0.4, accuracy: 0.001)
        XCTAssertEqual(first.from - sound.span.lowerBound, sound.span.upperBound - second.to, accuracy: 0.001, "shared evenly")
        for cut in cuts {
            let joins = GapSound.judge([layer(take)], from: cut.from, to: cut.to)
            XCTAssertEqual(joins.start.verdict, .clean, "\(cut)")
            XCTAssertEqual(joins.end.verdict, .clean, "\(cut)")
        }

        // A second of someone talking off mic is more than the keep: it all
        // stays, with only the least kept beside it and the words.
        let chat = Take(length: 8, words: [(10.5, 11.0), (14.0, 14.5)], softWords: [(12.0, 13.0, 20)])
        let long = try listen([layer(chat)], gap: 11.0...14.0, before: 10.5...11.0, after: 14.0...14.5)
        let talk = try XCTUnwrap(long.heard.first)
        let both = try long.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[0].from - long.span.lowerBound, CutPlanner.minimumTail, accuracy: 0.001)
        XCTAssertEqual(long.span.upperBound - both[1].to, CutPlanner.minimumLead, accuracy: 0.001)
        let left = (long.span.upperBound - long.span.lowerBound) - both.reduce(0) { $0 + ($1.to - $1.from) }
        XCTAssertEqual(left, (talk.range.upperBound - talk.range.lowerBound) + 0.03 * 3 + 0.08, accuracy: 0.001)
    }

    func testMikesGapsAreMeasuredFromTheSoundNotTheTranscript() throws {
        // The transcript ends "it." 0.15 s early and starts "So" 0.1 s
        // late, so its gap (10.85-12.1) is 0.35 s longer than the sound's.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let sound = try listen([layer(take)], gap: 10.85...12.1, before: 10.5...10.85, after: 12.1...12.5)
        XCTAssertEqual(sound.span.lowerBound, 11.0, accuracy: 0.011)
        XCTAssertEqual(sound.span.upperBound, 12.0, accuracy: 0.011)
        let placed = try XCTUnwrap(sound.place(keep: 0.4, minimum: 0.5, frame: frame).get().first)
        // What's left between the words' sound is the 0.4 s.
        XCTAssertEqual((placed.from - 11.0) + (12.0 - placed.to), 0.4, accuracy: 0.02)

        // And the minimum is the sound's gap too: 0.45 s of real pause
        // under a 0.6 s transcript gap isn't a pause to tighten.
        let short = Take(length: 5, words: [(10.5, 11.0), (11.45, 12.0)])
        let shortSound = try listen([layer(short)], gap: 10.85...11.45, before: 10.5...10.85, after: 11.45...12.0)
        XCTAssertEqual(shortSound.place(keep: 0.4, minimum: 0.5, frame: frame).failure, .short)
    }

    func testATranscriptTimeOffByAFifthOfASecondStaysInTheRealPause() throws {
        // "processed" starts 0.2 s before the transcript says (#64): the cut
        // has to end before its sound, not before 12.2.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.6)])
        let sound = try listen([layer(take)], gap: 11.0...12.2, before: 10.5...11.0, after: 12.2...12.6)
        XCTAssertEqual(sound.span.upperBound, 12.0, accuracy: 0.011)
        let placed = try XCTUnwrap(sound.place(keep: 0.4, minimum: 0.5, frame: frame).get().first)
        XCTAssertLessThanOrEqual(placed.to, 12.0 - CutPlanner.minimumLead)
        XCTAssertTrue(sound.pauses.contains { $0.contains(placed.from) && $0.contains(placed.to) })
        XCTAssertEqual(GapSound.judge([layer(take)], from: placed.from, to: placed.to).end.verdict, .clean)
    }

    func testAQuietSecondVoiceInTheGapIsNotCutThrough() throws {
        // A child a metre from the mic, 20 dB under the speaker (#11): over
        // the room's floor, so it's sound, though no word of it is in the
        // transcript.
        let take = Take(length: 6, words: [(10.5, 11.0), (12.6, 13.1)], softWords: [(11.2, 11.5, 20)])
        let sound = try listen([layer(take)], gap: 11.0...12.6, before: 10.5...11.0, after: 12.6...13.1)
        XCTAssertEqual(sound.heard.count, 1, "\(sound.heard)")
        let heard = try XCTUnwrap(sound.heard.first)
        XCTAssertEqual(heard.range.lowerBound, 11.2, accuracy: 0.02)
        XCTAssertEqual(heard.range.upperBound, 11.5, accuracy: 0.02)
        XCTAssertEqual(heard.layers, ["Voice"])
        // The quiet either side of the second voice is cut, and the voice
        // stays as it was, 30 ms of quiet either side of it.
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 2, "\(cuts)")
        XCTAssertLessThanOrEqual(cuts[0].to, heard.range.lowerBound - 0.03 + 0.001)
        XCTAssertGreaterThanOrEqual(cuts[1].from, heard.range.upperBound + 0.03 - 0.001)
        XCTAssertLessThanOrEqual(cuts[1].to, 12.6 - CutPlanner.minimumLead + 0.011)

        // With the voice filling a short gap, neither side has room for a
        // frame's cut and 30 ms either side of it: it isn't cut at all.
        let middle = Take(length: 6, words: [(10.5, 11.0), (11.65, 12.1)], softWords: [(11.09, 11.56, 20)])
        let crowded = try listen([layer(middle)], gap: 11.0...11.65, before: 10.5...11.0, after: 11.65...12.1)
        XCTAssertFalse(crowded.heard.isEmpty)
        let refusal = try XCTUnwrap(crowded.place(keep: 0.4, minimum: 0.5, frame: frame).failure)
        XCTAssertTrue([.sound, .speech].contains(refusal), "\(refusal)")
    }

    func testASecondTrackTalkingInTheVoicesGapCounts() throws {
        // The main mic is quiet from 11.0 to 12.6, but the iPad's own
        // recording, on its own track, has the app talking 11.4-12.0.
        let voice = Take(length: 6, words: [(10.5, 11.0), (12.6, 13.1)])
        let device = Take(length: 6, words: [(11.4, 12.0)])
        let sound = try listen([layer(voice), layer(device, name: "iPad")], gap: 11.0...12.6, before: 10.5...11.0, after: 12.6...13.1)
        let heard = try XCTUnwrap(sound.heard.first)
        XCTAssertEqual(heard.layers, ["iPad"])
        XCTAssertEqual(heard.range.lowerBound, 11.4, accuracy: 0.02)
        XCTAssertEqual(heard.range.upperBound, 12.0, accuracy: 0.02)
        // The quiet either side of the app's line is cut, never the line.
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 2, "\(cuts)")
        XCTAssertLessThanOrEqual(cuts[0].to, heard.range.lowerBound - 0.03 + 0.001)
        XCTAssertGreaterThanOrEqual(cuts[1].from, heard.range.upperBound + 0.03 - 0.001)
        for cut in cuts {
            XCTAssertEqual(GapSound.judge([layer(voice), layer(device, name: "iPad")], from: cut.from, to: cut.to).start.verdict, .clean)
        }

        // On the voice alone it's one pause, cut through the app's line.
        let alone = try listen([layer(voice)], gap: 11.0...12.6, before: 10.5...11.0, after: 12.6...13.1)
        XCTAssertTrue(alone.heard.isEmpty)
        XCTAssertNoThrow(try alone.place(keep: 0.4, minimum: 0.5, frame: frame).get())
    }

    func testABreathInALongPauseIsKeptAndTheCutGoesBesideIt() throws {
        // A breath just before the next sentence. It's sound, so the cut
        // goes in the quiet before it and the breath stays with the words
        // it leads into: cutting it out of the middle of a pause leaves two
        // joins for one, and a breath cut short is what Mike heard as
        // clipped on the Ian video.
        let take = Take(length: 6, words: [(10.5, 11.0), (12.5, 13.0)], breaths: [(12.05, 12.35)])
        let sound = try listen([layer(take)], gap: 11.0...12.5, before: 10.5...11.0, after: 12.5...13.0)
        let breath = try XCTUnwrap(sound.heard.first, "a breath is sound")
        XCTAssertEqual(breath.range.lowerBound, 12.05, accuracy: 0.03)
        // The 0.15 s between the breath and "So" is left as it is: what
        // cutting it to its least (30 ms after the breath, 80 ms before the
        // word) would save is under a real pause, not worth two more joins.
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 1, "\(cuts)")
        let placed = try XCTUnwrap(cuts.first)
        XCTAssertEqual(placed.to, breath.range.lowerBound - 0.03, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(placed.from, 11.0)
        // The breath and the quiet after it (0.45 s) are already more than
        // the keep, so the quiet before it keeps only 30 ms either side of
        // the cut: what's left from "it." to "So" is the keep at least.
        XCTAssertEqual(placed.from, sound.span.lowerBound + 0.03, accuracy: 0.001)
        let kept = (sound.span.upperBound - sound.span.lowerBound) - (placed.to - placed.from)
        XCTAssertGreaterThanOrEqual(kept, 0.4)
    }

    func testFaintTappingThroughALongPauseIsOneCut() throws {
        // The Threadbear launch video: a quiet room (about -83 dB) and a
        // foot tapping or a fan all through a 9 s pause, low bumps 0.18 s
        // long every 0.43 s at -62 dB, about 40 dB under the words. Each
        // bump is over the floor, so it was sound, and the pause was cut
        // round every one of them: 20 cuts, the picture jumping every 0.2 s.
        // Timed so a bump is where each edge would go (0.2 s from each word).
        let pulses = (11.1, 19.95, 0.43, 0.18, -62.0)
        let take = Take(length: 13, words: [(10.5, 11.0), (20.0, 20.5)], room: 0.04, pulses: [pulses])
        let sound = try listen([layer(take)], gap: 11.0...20.0, before: 10.5...11.0, after: 20.0...20.5)
        XCTAssertTrue(sound.heard.isEmpty, "\(sound.heard)")
        XCTAssertGreaterThan(sound.faint.count, 15, "the bumps are heard, as faint")
        XCTAssertEqual(sound.pauses.count, 1)

        // One cut across it, its edges in the quiet between bumps, keeping
        // a sentence's 0.4 s at least.
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame).get()
        XCTAssertEqual(cuts.count, 1, "\(cuts)")
        let cut = try XCTUnwrap(cuts.first)
        for edge in [cut.from, cut.to] {
            XCTAssertFalse(sound.faint.contains { $0.contains(edge) }, "\(edge) is in a bump: \(sound.faint)")
        }
        let kept = (sound.span.upperBound - sound.span.lowerBound) - (cut.to - cut.from)
        XCTAssertGreaterThan(kept, 0.4 + 0.1, "both edges moved on out of the bump they'd have been in")
        XCTAssertLessThan(kept, 0.4 + 2 * 0.25, "each edge moves past one bump at most")
        let joins = GapSound.judge([layer(take)], from: cut.from, to: cut.to)
        XCTAssertEqual(joins.start.verdict, .clean)
        XCTAssertEqual(joins.end.verdict, .clean)

        // Bumps with a voice in them, 20 dB under the words like the quiet
        // second voice, are sound the cuts go round.
        let syllables = stride(from: 11.1, to: 19.8, by: 0.43).map { ($0, $0 + 0.18, 20.0) }
        let voiced = Take(length: 13, words: [(10.5, 11.0), (20.0, 20.5)], softWords: syllables, room: 0.04)
        let near = try listen([layer(voiced)], gap: 11.0...20.0, before: 10.5...11.0, after: 20.0...20.5)
        XCTAssertTrue(near.faint.isEmpty, "\(near.faint)")
        XCTAssertGreaterThan(near.heard.count, 15)
    }

    func testSpeechRightThroughTheGapIsNoPause() throws {
        // The transcript has a gap in a word it timed badly: the voice runs
        // on from 10.5 to 12.0 without a break.
        let take = Take(length: 5, words: [(10.5, 12.0), (12.0, 12.4)])
        let sound = try listen([layer(take)], gap: 11.0...11.7, before: 10.5...11.0, after: 11.7...12.4)
        XCTAssertTrue(sound.runsThrough)
        XCTAssertEqual(sound.place(keep: 0.4, minimum: 0.5, frame: frame).failure, .speech)
        XCTAssertFalse(sound.heard.isEmpty, "says where the sound is")
    }

    func testNoTrackPlayingTheGapCantBeHeard() {
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        var short = layer(take)
        short.pieces[0].timeline = 10.0..<11.5
        XCTAssertNil(GapSound.listen(gap: 11.0...12.0, before: 10.5...11.0, after: 12.0...12.5, layers: [short]))
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
