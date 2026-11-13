import XCTest
@testable import TandemMedia

/// Mike's rule for a join in a talking take (13 Nov 2026): the clip coming
/// in starts a frame or two before he speaks, and the pause the join keeps
/// goes on the end of the clip going out, so his face never waits on screen
/// to talk. `LeadIn` finds the word's start; `GapSound.place` and
/// `CutPlanner` put the keep on the outgoing side with a lead.
final class LeadInTests: XCTestCase {
    private func placer(_ take: Take) -> CutPlacer {
        let energy = take.energy
        return CutPlacer(energy, levels: SpeechLevels(of: [energy]))
    }

    private let frame = 1.0 / 30

    func testTheWordsStartIsFoundInTheSound() throws {
        // "...that's it. | So the..." with a second between them.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        // Never late, and early by no more than the word's fade and a blip
        // of the room beside it.
        let start = try XCTUnwrap(LeadIn.speechStart(placer(take), after: 11.2))
        XCTAssertLessThanOrEqual(start, 12.005)
        XCTAssertGreaterThan(start, 11.96)
        // Already in the word: it starts where the clip does.
        XCTAssertEqual(try XCTUnwrap(LeadIn.speechStart(placer(take), after: 12.2)), 12.2, accuracy: 0.001)
        // Nothing said within reach.
        XCTAssertNil(LeadIn.speechStart(placer(take), after: 12.6, reach: 1))
    }

    func testABreathBeforeTheWordIsPause() throws {
        // He breathes in just before "So": to Mike that's still him waiting
        // to talk, as it's pause to tighten.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)], breaths: [(11.55, 11.85)])
        let start = try XCTUnwrap(LeadIn.speechStart(placer(take), after: 11.2))
        XCTAssertEqual(start, 12.0, accuracy: 0.03, "the breath at 11.55 isn't the word")
    }

    func testASoftFirstConsonantStays() throws {
        // A soft "f" 20 dB under the word runs into it: the word starts
        // there, so the lead is measured from the "f".
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)], softWords: [(11.92, 12.0, 20)])
        let start = try XCTUnwrap(LeadIn.speechStart(placer(take), after: 11.2))
        XCTAssertLessThanOrEqual(start, 11.93)
        XCTAssertGreaterThan(start, 11.85)
    }

    func testTheClipStartsTheLeadBeforeTheWord() throws {
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let placer = placer(take)
        let onset = try XCTUnwrap(LeadIn.speechStart(placer, after: 11.2))
        let start = try XCTUnwrap(LeadIn.start(placer, onset: onset, earliest: 11.2))
        XCTAssertEqual(start, onset - LeadIn.lead, accuracy: 0.001)
        XCTAssertEqual(placer.judge(at: start, keeps: .after).verdict, .clean)
        // Already within the lead of the word: nothing to gain.
        XCTAssertNil(LeadIn.start(placer, onset: onset, earliest: onset - 0.03))
    }

    func testTheClipBeforeGrowsOnlyThroughQuiet() {
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let placer = placer(take)
        // From just after "it." there's most of a second of quiet.
        XCTAssertEqual(LeadIn.quietAfter(placer, from: 11.1, limit: 0.4), 0.4, accuracy: 0.006)
        // From 11.7, the next word stops it short of 12.0.
        let run = LeadIn.quietAfter(placer, from: 11.7, limit: 0.6)
        XCTAssertGreaterThan(run, 0.1)
        XCTAssertLessThan(run, 0.3)
        XCTAssertEqual(placer.judge(at: 11.7 + run, keeps: .before).verdict, .clean)
    }

    func testTheClipBeforeDoesntGrowOverACutClick() {
        // A 25 ms click 0.1 s after the clip ends, then quiet: not a word to
        // wait for, but it was cut away and mustn't come back.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5), (11.1, 11.125)])
        let run = LeadIn.quietAfter(placer(take), from: 11.0, limit: 0.43)
        XCTAssertLessThanOrEqual(run, 0.1 - CutAudit.pad + 0.006)
        // A single 5 ms frame of click too.
        let tick = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5), (11.1, 11.107)])
        XCTAssertLessThanOrEqual(LeadIn.quietAfter(placer(tick), from: 11.0, limit: 0.43), 0.1 - CutAudit.pad + 0.006)
    }

    func testTheClipBeforeDoesntGrowIntoACutWordTooSoftToMeasure() {
        // Quiet all the way by the sound, but the transcript has a word that
        // was cut 0.15 s after the clip ends.
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let said = [CutAudit.Word(text: "but", start: 11.15, end: 11.4)]
        XCTAssertEqual(LeadIn.quietAfter(placer(take), from: 11.0, limit: 0.43, transcript: said), 0.15 - CutAudit.pad, accuracy: 0.006)
        // One already sounding at the clip's end: it doesn't grow at all.
        let straddling = [CutAudit.Word(text: "but", start: 10.95, end: 11.3)]
        XCTAssertEqual(LeadIn.quietAfter(placer(take), from: 11.0, limit: 0.43, transcript: straddling), 0)
    }

    func testTighteningPutsTheKeepAfterTheWordBefore() throws {
        // A sentence's 0.4 s: 0.35 after "it." and 0.05 before "So".
        let take = Take(length: 5, words: [(10.5, 11.0), (12.0, 12.5)])
        let energy = take.energy
        let layer = SoundLayer(name: "Voice", pieces: [SoundLayer.Piece(timeline: energy.start..<energy.end, mediaStart: energy.start, speed: 1, placer: placer(take))])
        let sound = try XCTUnwrap(GapSound.listen(gap: 11.0...12.0, before: 10.5...11.0, after: 12.0...12.5, layers: [layer]))
        let placed = try XCTUnwrap(sound.place(keep: 0.4, minimum: 0.5, frame: frame, lead: 0.05).get().first)
        XCTAssertEqual(placed.from, sound.span.lowerBound + 0.35, accuracy: 0.001)
        XCTAssertEqual(placed.to, sound.span.upperBound - 0.05, accuracy: 0.001)
        XCTAssertEqual(placed.latest, sound.span.upperBound - 0.05, accuracy: 0.001, "on a frame it can keep less than the old 80 ms")
        let joins = GapSound.judge([layer], from: placed.from, to: placed.to)
        XCTAssertEqual(joins.start.verdict, .clean)
        XCTAssertEqual(joins.end.verdict, .clean)
    }

    func testWithSoundInThePauseTheKeepGoesAfterTheWordThenBesideTheSound() throws {
        // A click mid-pause: the quiet after "it." takes the keep, and
        // "So" still gets only the lead.
        let take = Take(length: 6, words: [(10.5, 11.0), (13.0, 13.5)], softWords: [(11.8, 11.9, 20)])
        let energy = take.energy
        let layer = SoundLayer(name: "Voice", pieces: [SoundLayer.Piece(timeline: energy.start..<energy.end, mediaStart: energy.start, speed: 1, placer: placer(take))])
        let sound = try XCTUnwrap(GapSound.listen(gap: 11.0...13.0, before: 10.5...11.0, after: 13.0...13.5, layers: [layer]))
        let cuts = try sound.place(keep: 0.4, minimum: 0.5, frame: frame, lead: 0.05).get()
        let last = try XCTUnwrap(cuts.last)
        XCTAssertEqual(sound.span.upperBound - last.to, 0.05, accuracy: 0.001)
    }

    func testTandemCutPutsThePauseOnTheClipBefore() throws {
        // "...that's it. [Um, sorry.] So the..." cut with a comma's 0.12 s:
        // 0.07 after "it." and the 0.05 lead before "So".
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let result = CutPlanner.plan(
            placer(take), removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.12, falseStart: nil, lead: 0.05
        )
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertEqual(result.keptAfter, 0.05, accuracy: 0.001)
        XCTAssertEqual(result.keptBefore, 0.07, accuracy: 0.001)
        XCTAssertEqual(result.end?.verdict, .clean)

        // A sentence's 0.4 s with only 0.4 s of pause after "it.": that
        // pause keeps all it can, and only the rest goes before "So".
        let sentence = CutPlanner.plan(
            placer(take), removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.4, falseStart: nil, lead: 0.05
        )
        XCTAssertTrue(sentence.cuts, "\(sentence)")
        let before = try XCTUnwrap(sentence.startPause)
        XCTAssertEqual(sentence.keptBefore, (before.upperBound - before.lowerBound) - min(CutAudit.pad, (before.upperBound - before.lowerBound) / 2), accuracy: 0.001)
        XCTAssertEqual(sentence.keptBefore + sentence.keptAfter, 0.4, accuracy: 0.001)
        XCTAssertGreaterThan(sentence.keptAfter, 0.05)
    }
}
