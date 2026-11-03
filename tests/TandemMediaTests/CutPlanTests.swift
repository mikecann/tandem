import XCTest
@testable import TandemMedia

/// `CutPlanner` on made-up takes (`Take`, from SpeechEnergyTests): where it
/// puts each edge of a cut, and when it won't cut at all.
final class CutPlanTests: XCTestCase {
    private func placer(_ take: Take) -> CutPlacer {
        let energy = take.energy
        return CutPlacer(energy, levels: SpeechLevels(of: [energy]))
    }

    private func plan(
        _ take: Take, removing stretch: ClosedRange<Double>, cut: [ClosedRange<Double>] = [], kept: [ClosedRange<Double>] = [],
        keep: Double = 0.12, tightenFrom: Double = 0, falseStart: Bool? = nil
    ) -> CutPlan {
        CutPlanner.plan(placer(take), removing: stretch, cut: cut, kept: kept, keep: keep, tightenFrom: tightenFrom, falseStart: falseStart)
    }

    func testBothEdgesGoInThePausesEitherSide() throws {
        // "...that's it. [Um, sorry.] So the..." with 0.4 s pauses either side.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let result = plan(take, removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8])
        XCTAssertTrue(result.cuts, "\(result)")
        let from = try XCTUnwrap(result.from), to = try XCTUnwrap(result.to)
        let before = try XCTUnwrap(result.startPause), after = try XCTUnwrap(result.endPause)
        // The pauses as the sound has them: the room's rumble splits off a
        // little of each, but they're in the silences between the words.
        assertInside(before, 11.0...11.4)
        assertInside(after, 11.9...12.3)
        XCTAssertGreaterThan(before.upperBound - before.lowerBound, 0.2)
        XCTAssertGreaterThan(after.upperBound - after.lowerBound, 0.2)
        XCTAssertTrue(before.contains(from) && after.contains(to))
        // A comma's 0.12 s, split as tighten does, but never under 30 ms
        // after the word before or 80 ms before the word after.
        XCTAssertEqual(result.keptBefore, 0.06, accuracy: 0.001)
        XCTAssertEqual(result.keptAfter, 0.08, accuracy: 0.001)
        XCTAssertEqual(from, before.lowerBound + 0.06, accuracy: 0.001)
        XCTAssertEqual(to, after.upperBound - 0.08, accuracy: 0.001)
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)
        XCTAssertGreaterThan(try XCTUnwrap(result.start?.margin), CutAudit.cleanFrom)
        XCTAssertGreaterThan(try XCTUnwrap(result.end?.margin), CutAudit.cleanFrom)
        XCTAssertFalse(result.falseStart)
        XCTAssertTrue(result.broughtBack.isEmpty)

        // After a sentence, 0.4 s: 0.2 either side.
        let sentence = plan(take, removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.4)
        XCTAssertEqual(try XCTUnwrap(sentence.from), before.lowerBound + 0.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sentence.to), after.upperBound - 0.2, accuracy: 0.001)

        // Shorter pauses than the keep are kept, all but 30 ms of each by
        // the cut words.
        let snug = Take(length: 5, words: [(10.5, 11.0), (11.2, 11.9), (12.1, 12.8)])
        let whole = plan(snug, removing: 11.2...11.9, cut: [11.2...11.9], kept: [10.5...11.0, 12.1...12.8], keep: 0.6)
        XCTAssertTrue(whole.cuts, "\(whole)")
        let pauses = try XCTUnwrap(whole.startPause).upperBound - XCTUnwrap(whole.startPause).lowerBound
            + XCTUnwrap(whole.endPause).upperBound - XCTUnwrap(whole.endPause).lowerBound
        XCTAssertEqual(whole.keptBefore + whole.keptAfter, pauses - 0.06, accuracy: 0.001)
    }

    private func assertInside(_ pause: ClosedRange<Double>, _ gap: ClosedRange<Double>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(pause.lowerBound, gap.lowerBound - 0.006, "\(pause) in \(gap)", file: file, line: line)
        XCTAssertLessThanOrEqual(pause.upperBound, gap.upperBound + 0.006, "\(pause) in \(gap)", file: file, line: line)
    }

    func testPausesUnderTightensMinimumAreKeptAsTheyWere() throws {
        // 0.3 s pauses either side: shorter than tighten's 0.5 s, so the join
        // keeps one of them (0.3 s, less the 30 ms by the cut words), not the
        // sentence's 0.4 s or the mid-sentence 0.08.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.3, 11.9), (12.2, 12.8)])
        let result = plan(take, removing: 11.3...11.9, cut: [11.3...11.9], kept: [10.5...11.0, 12.2...12.8], keep: 0.08, tightenFrom: 0.5)
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertEqual(result.keptBefore + result.keptAfter, 0.3, accuracy: 0.03)
    }

    func testAFillerInFluentSpeechIsLeftIn() {
        // "do that [because of] to keep": no pause either side of the filler.
        let take = Take(length: 5, words: [(10.5, 12.3), (13, 13.5)])
        let result = plan(
            take, removing: 11.3...11.7, cut: [11.3...11.5, 11.5...11.7],
            kept: [10.5...10.9, 10.9...11.3, 11.7...11.9, 11.9...12.3]
        )
        XCTAssertFalse(result.cuts)
        XCTAssertNil(result.from)
        XCTAssertEqual(result.problem, .fluent)
        XCTAssertNotNil(result.problemEdge)
        XCTAssertFalse(result.falseStart, "0.4 s isn't a long false start")

        // Without the transcript, the nearest pause is too far to be the
        // pause round these words.
        let unheard = plan(take, removing: 11.3...11.7)
        XCTAssertFalse(unheard.cuts)
        XCTAssertEqual(unheard.problem, .runsOn)
    }

    func testTheEdgeGoesInTheRealPauseWhenTheTranscriptIsLate() throws {
        // Two cut words with a 0.1 s pause between them, and the transcript
        // 0.2 s late on every word (#64: "processed" started 0.2 s before
        // SpeechAnalyzer said). The pause nearest the transcript's start is
        // the one between the two cut words; the real one is before them.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.6), (11.7, 11.9), (12.3, 12.8)])
        let late = 0.2
        let result = plan(
            take, removing: (11.4 + late)...(11.9 + late), cut: [(11.4 + late)...(11.6 + late), (11.7 + late)...(11.9 + late)],
            kept: [(10.5 + late)...(11.0 + late), (12.3 + late)...(12.8 + late)]
        )
        XCTAssertTrue(result.cuts, "\(result)")
        assertInside(try XCTUnwrap(result.startPause), 11.0...11.4)
        assertInside(try XCTUnwrap(result.endPause), 11.9...12.3)
        XCTAssertLessThan(try XCTUnwrap(result.from), 11.4, "not on the transcript's 11.6")
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)

        // From the sound alone, the late end still finds the real pause.
        // (The late start is in the pause between the two cut words, and
        // only the transcript can say a cut word is before it.)
        let unheard = plan(take, removing: (11.4 + late)...(11.9 + late))
        XCTAssertTrue(unheard.cuts, "\(unheard)")
        assertInside(try XCTUnwrap(unheard.endPause), 11.9...12.3)
    }

    func testALongFalseStartIsCutPauseToPauseAndARestartWordComesBack() throws {
        // "So the way [we do, the way we can, we] we do it": the false start
        // runs 2.2 s, and its last word runs straight into the restart.
        let take = Take(start: 9, length: 6, words: [(9.5, 9.8), (10.0, 10.3), (10.5, 10.8), (11.0, 11.3), (11.5, 11.7), (11.9, 12.7), (13.2, 13.6)])
        let cut: [ClosedRange<Double>] = [10.0...10.3, 10.5...10.8, 11.0...11.3, 11.5...11.7, 11.9...12.2]
        let kept: [ClosedRange<Double>] = [9.5...9.8, 12.2...12.7, 13.2...13.6]
        let result = plan(take, removing: 10.0...12.2, cut: cut, kept: kept)
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertTrue(result.falseStart, "over 2 s: a long false start")
        assertInside(try XCTUnwrap(result.startPause), 9.8...10.0)
        assertInside(try XCTUnwrap(result.endPause), 11.7...11.9)
        XCTAssertEqual(result.broughtBack, [11.9...12.2], "the cut \"we\" comes back with the restart")
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)

        // Only as a false start: told it isn't, it's left in.
        let told = plan(take, removing: 10.0...12.2, cut: cut, kept: kept, falseStart: false)
        XCTAssertFalse(told.cuts)
        XCTAssertEqual(told.problem, .fluent)
        XCTAssertEqual(told.problemEdge, .end)

        // A short one is a false start only when asked.
        let rest = kept + cut.prefix(2)
        let short = plan(take, removing: 11.0...12.2, cut: Array(cut.suffix(3)), kept: rest)
        XCTAssertFalse(short.cuts, "1.2 s: put back rather than bring a word back")
        let asked = plan(take, removing: 11.0...12.2, cut: Array(cut.suffix(3)), kept: rest, falseStart: true)
        XCTAssertTrue(asked.cuts)
        XCTAssertEqual(asked.broughtBack, [11.9...12.2])
    }

    func testSeveralStretchesFromOneTake() throws {
        let take = Take(length: 8, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8), (13.3, 13.8), (14.2, 14.6), (15.1, 15.5)])
        let placer = placer(take)
        let words: [ClosedRange<Double>] = [10.5...11.0, 11.4...11.9, 12.3...12.8, 13.3...13.8, 14.2...14.6, 15.1...15.5]
        let plans = [11.4...11.9, 13.3...13.8].map { stretch in
            CutPlanner.plan(placer, removing: stretch, cut: words.filter { stretch.contains($0.lowerBound) }, kept: words.filter { !stretch.contains($0.lowerBound) }, keep: 0.12, falseStart: nil)
        }
        XCTAssertTrue(plans.allSatisfy(\.cuts), "\(plans)")
        XCTAssertLessThan(try XCTUnwrap(plans[0].to), try XCTUnwrap(plans[1].from))
        XCTAssertTrue(plans.allSatisfy { $0.start?.verdict == .clean && $0.end?.verdict == .clean })
    }

    func testAPauseTheClipDoesntPlayIsntAPauseForItsEdge() throws {
        // The clip plays the file to 10.9, in fluent speech, and a false
        // start begins at 10.5. The file's next pause (11.0 to 11.4) is past
        // the clip's end, so nobody hears it there: the next clip, of another
        // stretch, plays instead. Without a pause the clip plays, the start
        // has nowhere to go.
        let take = Take(start: 9, length: 6, words: [(9.5, 11.0), (11.4, 12.0)])
        let restart = Take(start: 18, length: 6, words: [(19.0, 19.5), (20.0, 20.5)])
        let end = CutPlanner.Boundary(time: 19.5, before: [19.0...19.5], after: [20.0...20.5])
        func start(playing within: ClosedRange<Double>) -> CutPlanner.Boundary {
            CutPlanner.Boundary(time: 10.5, before: [9.5...10.0, 10.0...10.5], after: [10.5...10.9], within: within)
        }
        let result = CutPlanner.plan(
            start: placer(take), start(playing: 9.0...10.9), end: placer(restart), end, keep: 0.12, falseStart: true, sameFile: false
        )
        XCTAssertFalse(result.cuts, "\(result)")
        XCTAssertEqual(result.problem, .fluent)
        XCTAssertEqual(result.problemEdge, .start)

        // A clip that plays into the pause can cut to the part of it it plays.
        let played = CutPlanner.plan(
            start: placer(take), start(playing: 9.0...11.2), end: placer(restart), end, keep: 0.12, falseStart: true, sameFile: false
        )
        XCTAssertTrue(played.cuts, "\(played)")
        let pause = try XCTUnwrap(played.startPause)
        assertInside(pause, 11.0...11.2)
        XCTAssertLessThanOrEqual(try XCTUnwrap(played.from), 11.2)
    }

    func testFaintTappingRoundTheWordsLeavesThePauseAPause() throws {
        // The Threadbear launch video's editor's notes: "...as well. [9 s of
        // a foot tapping] Editor's note, get rid of that. [more tapping] And
        // we also...", the tapping low bumps at -62 dB in a quiet room. Each
        // bump was sound no word claims, so there was no pause within 0.3 s
        // of the note, and tandem cut left it in ("runs into it from before").
        let take = Take(
            length: 14, words: [(10.5, 11.0), (15.0, 16.5), (20.5, 21.0)], room: 0.04,
            pulses: [(11.1, 14.95, 0.43, 0.18, -62.0), (16.6, 20.45, 0.43, 0.18, -62.0)]
        )
        let result = plan(take, removing: 15.0...16.5, cut: [15.0...16.5], kept: [10.5...11.0, 20.5...21.0], keep: 0.4)
        XCTAssertTrue(result.cuts, "\(result)")
        let from = try XCTUnwrap(result.from), to = try XCTUnwrap(result.to)
        // The pauses run through the bumps, as far as the 3 s either side
        // of each edge that's looked at, and the cut keeps a sentence's
        // 0.4 s (at least) of them.
        assertInside(try XCTUnwrap(result.startPause), 11.0...15.0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.startPause).lowerBound, 15.0 - CutAudit.around + 0.01)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.endPause).upperBound, 16.5 + CutAudit.around - 0.01)
        XCTAssertGreaterThanOrEqual(result.keptBefore + result.keptAfter, 0.4 - 1e-9)
        XCTAssertLessThan(result.keptBefore + result.keptAfter, 0.4 + 0.5)
        // Neither edge sits in a bump: each is in the quiet between them.
        for edge in [from, to] {
            let phase = (edge - (edge < 16 ? 11.1 : 16.6)).truncatingRemainder(dividingBy: 0.43)
            XCTAssertGreaterThan(phase, 0.18, "\(edge) is in a bump")
        }
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)

        // A low swell running straight into "Editor's", with no quiet
        // between (43:10 on the Threadbear video), isn't the word: it made
        // the note's sound start 0.6 s before the transcript has it.
        let swell = Take(
            length: 14, words: [(10.5, 11.0), (15.0, 16.5), (20.5, 21.0)], room: 0.04,
            pulses: [(11.1, 14.0, 0.43, 0.18, -62.0), (14.4, 15.0, 1, 0.6, -60.0)]
        )
        let joined = plan(swell, removing: 15.0...16.5, cut: [15.0...16.5], kept: [10.5...11.0, 20.5...21.0], keep: 0.4)
        XCTAssertTrue(joined.cuts, "\(joined)")
        XCTAssertGreaterThan(try XCTUnwrap(joined.startPause).upperBound, 14.9, "the pause runs on to the word's voice")
        XCTAssertEqual(joined.start?.verdict, .clean)
        XCTAssertEqual(joined.end?.verdict, .clean)
    }

    func testSoundNoWordClaimsGoesWithTheStretchItsIn() throws {
        // "So [um, the] right": two short removed words with a 0.15 s pause
        // between them, and the transcript 0.2 s late on every word. The
        // first removed word's time lands on the second's sound, so no word
        // claims the first's, and the kept "So" is nearest it. It's inside
        // the stretch asked for, allowing for the slack, so it goes: the cut
        // starts in the pause after "So", not the one after "um".
        let take = Take(length: 5, words: [(10.0, 10.4), (10.6, 10.7), (10.85, 11.05), (11.5, 11.8)])
        let late = 0.2
        let result = plan(
            take, removing: (10.6 + late)...(11.05 + late), cut: [(10.6 + late)...(10.7 + late), (10.85 + late)...(11.05 + late)],
            kept: [(10.0 + late)...(10.4 + late), (11.5 + late)...(11.8 + late)]
        )
        XCTAssertTrue(result.cuts, "\(result)")
        assertInside(try XCTUnwrap(result.startPause), 10.4...10.6)
        assertInside(try XCTUnwrap(result.endPause), 11.05...11.5)
        XCTAssertTrue(result.missed.isEmpty, "\(result.missed)")
    }

    func testSoundTheCutHasToKeepIsSaid() throws {
        // A bit of sound no word claims (10.7 to 10.78), then a short kept
        // word ("a", 10.93 to 11.0), then the cut word, which the transcript
        // starts 0.25 s early. The sound is within the slack of the stretch,
        // but cutting it would cut "a" too, so it stays, and the plan says
        // so rather than pass as a clean cut of all that was asked.
        let take = Take(length: 5, words: [(10.0, 10.4), (10.7, 10.78), (10.93, 11.0), (11.3, 11.6), (12.0, 12.4)])
        let result = plan(take, removing: 11.05...11.6, cut: [11.05...11.6], kept: [10.0...10.4, 10.93...11.0, 12.0...12.4])
        XCTAssertTrue(result.cuts, "\(result)")
        assertInside(try XCTUnwrap(result.startPause), 11.0...11.3)
        let missed = try XCTUnwrap(result.missed[.start])
        XCTAssertEqual(missed.count, 1, "\(missed)")
        assertInside(try XCTUnwrap(missed.first), 10.6...10.85)
        XCTAssertNil(result.missed[.end])
    }

    func testTheKeepIsTimelineSecondsOnAFastClip() throws {
        // At 2x, the comma's 0.12 s on the timeline is 0.24 s of the file:
        // 0.12 of each pause, where at 1x it's 0.06 and 0.08.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let placer = placer(take)
        let result = CutPlanner.plan(
            start: placer, CutPlanner.Boundary(time: 11.4, before: [10.5...11.0], after: [11.4...11.9], speed: 2),
            end: placer, CutPlanner.Boundary(time: 11.9, before: [11.4...11.9], after: [12.3...12.8], speed: 2),
            keep: 0.12, falseStart: false
        )
        XCTAssertTrue(result.cuts, "\(result)")
        XCTAssertEqual(result.keptBefore, 0.12, accuracy: 0.001)
        XCTAssertEqual(result.keptAfter, 0.12, accuracy: 0.001)
    }

    func testAnEdgeThatWouldntBeCleanIsntCut() {
        // Snapped (to a frame, say) out of its pause and into the word:
        // judged clipped, so the stretch isn't cut.
        let take = Take(length: 5, words: [(10.5, 11.0), (11.4, 11.9), (12.3, 12.8)])
        let result = CutPlanner.plan(
            placer(take), removing: 11.4...11.9, cut: [11.4...11.9], kept: [10.5...11.0, 12.3...12.8], keep: 0.12, falseStart: nil,
            snap: { time, edge, _ in edge == .start ? 10.9 : time }
        )
        XCTAssertFalse(result.cuts)
        XCTAssertEqual(result.problem, .notClean)
        XCTAssertEqual(result.problemEdge, .start)
        XCTAssertEqual(result.start?.verdict, .clipped)
    }
    func testTwoFillersSideBySideAreOneCutWithThePauseBetweenThem() throws {
        // "Right. [um, uh] next one": two fillers with a 0.3 s pause between
        // them, and 0.5 s pauses round them. One stretch from the start of
        // "um" to the end of "uh" goes pause to pause, the pause between
        // them with it, rather than leaving a sliver of "um, uh" apart.
        let take = Take(length: 4, words: [(10.5, 11.0), (11.5, 11.8), (12.1, 12.4), (12.9, 13.3)])
        let result = plan(take, removing: 11.5...12.4, cut: [11.5...11.8, 12.1...12.4], kept: [10.5...11.0, 12.9...13.3], keep: 0.4, tightenFrom: 0.5)
        XCTAssertTrue(result.cuts, "\(result)")
        assertInside(try XCTUnwrap(result.startPause), 11.0...11.5)
        assertInside(try XCTUnwrap(result.endPause), 12.4...12.9)
        XCTAssertLessThan(try XCTUnwrap(result.from), 11.5)
        XCTAssertGreaterThan(try XCTUnwrap(result.to), 12.4)
        XCTAssertEqual(result.start?.verdict, .clean)
        XCTAssertEqual(result.end?.verdict, .clean)
    }
    func testAFilledPauseGoesByTheWholePauseFillerAndAll() throws {
        // "you have a query, [um] we": 0.3 s pauses either side of a 0.3 s
        // "um". Neither is 0.5 s, but without the "um" it's one 0.9 s pause,
        // which tighten would cut to a comma's 0.12 s, so the cut does too.
        let take = Take(length: 4, words: [(10.5, 11.0), (11.3, 11.6), (11.9, 12.4)])
        let cut = CutPlanner.plan(
            start: placer(take), CutPlanner.Boundary(time: 11.3, before: [10.5...11.0], after: [11.3...11.6]),
            end: placer(take), CutPlanner.Boundary(time: 11.6, before: [11.3...11.6], after: [11.9...12.4]),
            keep: 0.12, tightenFrom: 0.5, falseStart: false, filled: true
        )
        XCTAssertTrue(cut.cuts, "\(cut)")
        // Split as tighten splits it, 0.06 / 0.08 with the least before a word.
        XCTAssertEqual(cut.keptBefore + cut.keptAfter, 0.14, accuracy: 0.001)
        // A phrase isn't a pause: its pauses are kept as they were.
        let phrase = CutPlanner.plan(
            start: placer(take), CutPlanner.Boundary(time: 11.3, before: [10.5...11.0], after: [11.3...11.6]),
            end: placer(take), CutPlanner.Boundary(time: 11.6, before: [11.3...11.6], after: [11.9...12.4]),
            keep: 0.12, tightenFrom: 0.5, falseStart: false
        )
        XCTAssertGreaterThan(phrase.keptBefore + phrase.keptAfter, 0.2)
    }
    func testAFilledPauseIsMeasuredFromTheSound() throws {
        // "query, [um] we" where the sound has 0.2 s, a short 0.06 s "um"
        // and 0.2 s: 0.46 s from "query" to "we", under the 0.5 s minimum,
        // so the pauses are kept as they were. The transcript has the "um"
        // wider (0.3 s), which added to the pauses read as 0.7 s and cut
        // them to a comma's 0.12 s.
        let take = Take(length: 4, words: [(10.5, 11.0), (11.2, 11.26), (11.46, 12.0)])
        let cut = CutPlanner.plan(
            start: placer(take), CutPlanner.Boundary(time: 11.1, before: [10.5...11.0], after: [11.1...11.4]),
            end: placer(take), CutPlanner.Boundary(time: 11.4, before: [11.1...11.4], after: [11.46...12.0]),
            keep: 0.12, tightenFrom: 0.5, falseStart: false, filled: true
        )
        XCTAssertTrue(cut.cuts, "\(cut)")
        let pauses = try XCTUnwrap(cut.startPause).upperBound - XCTUnwrap(cut.startPause).lowerBound
            + XCTUnwrap(cut.endPause).upperBound - XCTUnwrap(cut.endPause).lowerBound
        // All but 30 ms of each pause by the "um", as a pause under the
        // minimum is kept, rather than the comma's 0.12 s.
        XCTAssertEqual(cut.keptBefore + cut.keptAfter, pauses - 0.06, accuracy: 0.001, "\(cut)")
    }
}
