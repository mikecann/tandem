import AVFoundation
import XCTest
@testable import TandemMedia

/// A few seconds of a made-up take at 32 kHz: a low hum of room noise, a
/// faint hiss over it, and "words" (a buzz of harmonics up to 3 kHz) and
/// "s" sounds (hiss above 4 kHz that hardly registers in the full band)
/// and "k" releases (a loud burst of the same hiss) where asked. Times are
/// media seconds from `start`.
struct Take {
    static let rate = 32_000.0
    var start = 10.0
    var length = 4.0
    var words: [(Double, Double)] = []
    /// Words this many dB under the others: (start, end, dB).
    var softWords: [(Double, Double, Double)] = []
    var esses: [(Double, Double)] = []
    var releases: [(Double, Double)] = []
    /// Breath: the same hiss as an "s", 10 dB under it.
    var breaths: [(Double, Double)] = []
    /// How loud the room is against the usual (about -55 dB of rumble):
    /// 0.04 is a quiet room, about -83 dB.
    var room: Float = 1
    /// A foot tapping or a fan: a low bump (90 Hz, a smooth swell) `length`
    /// long every `every` seconds from `from` to `to`, at `dB` RMS over the
    /// bump. (from, to, every, length, dB)
    var pulses: [(Double, Double, Double, Double, Double)] = []

    var samples: [Float] {
        let count = Int(length * Self.rate)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt32 = 12_345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        // Room: noise smoothed to a low rumble, about -55 dB, with white
        // hiss about -85 dB on top.
        var rumble: Float = 0
        for i in 0..<count {
            rumble += (noise() - rumble) * 0.02
            out[i] = (rumble * 0.03 + noise() * 0.00009) * room
        }
        for (from, to, every, length, dB) in pulses {
            // A Hann swell's RMS is 0.61 of its peak, a sine's 0.71 of its own.
            let peak = pow(10, dB / 20) / (0.61 * 0.71)
            var at = from
            while at + length <= to {
                for i in span((at, at + length)) {
                    let t = Double(i) / Self.rate
                    let phase = (t + start - at) / length
                    out[i] += Float(peak * sin(2 * .pi * 90 * t) * sin(.pi * phase) * sin(.pi * phase))
                }
                at += every
            }
        }
        func span(_ range: (Double, Double)) -> Range<Int> {
            let from = max(0, Int(((range.0 - start) * Self.rate).rounded()))
            let to = min(count, Int(((range.1 - start) * Self.rate).rounded()))
            return from..<max(from, to)
        }
        // Voices fade in and out over a few milliseconds; a hard edge
        // would click, and the click is heard above 4 kHz.
        func fade(_ i: Int, in range: Range<Int>) -> Float {
            let ramp = 0.005 * Self.rate
            return Float(min(1, Double(i - range.lowerBound) / ramp, Double(range.upperBound - i) / ramp))
        }
        for (start, end, under) in words.map({ ($0.0, $0.1, 0.0) }) + softWords {
            let range = span((start, end))
            let gain = 0.08 * pow(10, -under / 20)
            for i in range {
                let t = Double(i) / Self.rate
                var buzz = 0.0
                for harmonic in stride(from: 150.0, through: 3000, by: 150) { buzz += sin(2 * .pi * harmonic * t) / (harmonic / 150) }
                out[i] += Float(buzz * gain) * fade(i, in: range)
            }
        }
        // Each sample against the last: white noise tipped up to the top of
        // the band, about -54 dB over all for an "s", -34 for a release.
        for (hiss, gain) in esses.map({ ($0, Float(0.0025)) }) + releases.map({ ($0, Float(0.025)) }) + breaths.map({ ($0, Float(0.0008)) }) {
            var last: Float = 0
            let range = span(hiss)
            for i in range {
                let white = noise()
                out[i] += (white - last) * gain * fade(i, in: range)
                last = white
            }
        }
        return out
    }

    var energy: SpeechEnergy { SpeechEnergy(samples: samples, sampleRate: Self.rate, start: start) }
}

final class SpeechEnergyTests: XCTestCase {
    private func judge(
        _ take: Take, at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil, words: [ClosedRange<Double>] = []
    ) -> CutAudit.Edge {
        let energy = take.energy
        return CutAudit.judge(energy, levels: SpeechLevels(of: [energy]), at: time, keeps: side, removed: removed, words: words)
    }

    private func judge(
        _ take: Take, at time: Double, keeps side: CutAudit.Side, removed: ClosedRange<Double>? = nil,
        cutAway: ClosedRange<Double>? = nil, transcript: [CutAudit.Word]
    ) -> CutAudit.Edge {
        let energy = take.energy
        return CutAudit.judge(
            energy, levels: SpeechLevels(of: [energy]), at: time, keeps: side, removed: removed, cutAway: cutAway, transcript: transcript
        )
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> CutAudit.Word {
        CutAudit.Word(text: text, start: start, end: end)
    }

    private func around(_ energy: SpeechEnergy, _ time: Double) -> CutPlacer.Around {
        CutPlacer(energy, levels: SpeechLevels(of: [energy])).around(time)
    }

    func testFramesAreFiveMillisecondsInMediaTime() {
        let energy = Take(words: [(11.0, 11.5)]).energy
        XCTAssertEqual(energy.full.count, 800)
        XCTAssertEqual(energy.high.count, 800)
        let quiet = around(energy, 11.25).quiet
        XCTAssertLessThan(energy.full[energy.index(of: 10.9)], quiet, "the room before the word")
        XCTAssertGreaterThan(energy.full[energy.index(of: 11.2)], quiet, "the word")
        XCTAssertLessThan(energy.full[energy.index(of: 11.6)], quiet, "the room after it")
    }

    func testAWordRunningPastTheEndOfAClipIsClipped() throws {
        let take = Take(words: [(11.0, 11.6)])
        let edge = judge(take, at: 11.45, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(try XCTUnwrap(edge.lost), 0.15, accuracy: 0.015, "the rest of the word, cut off")
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "just into the pause after the word")
        let pause = try XCTUnwrap(edge.pause)
        XCTAssertEqual(pause.lowerBound, 11.6, accuracy: 0.015)
        XCTAssertFalse(edge.highBandOnly)
        XCTAssertNil(edge.gap)
    }

    func testAWordThatEndsInSilenceBeforeTheCutIsFine() {
        let take = Take(words: [(11.0, 11.6)])
        XCTAssertFalse(judge(take, at: 11.75, keeps: .before).clipped)
        // The next word starting right after the cut is cut material, not a clip.
        XCTAssertFalse(judge(take, at: 11.0, keeps: .before).clipped, "the clip ends in the pause, just before a word it doesn't keep")
        XCTAssertFalse(judge(take, at: 11.6, keeps: .before).clipped, "the word ends on the cut")
    }

    func testAShortGapInsideAWordIsNotAPause() throws {
        // "ta" and "kes" with the 40 ms closure before the "k" between them,
        // and the "k" released at the start of "kes".
        let take = Take(words: [(11.0, 11.3), (11.34, 11.6)], releases: [(11.34, 11.37)])
        let edge = judge(take, at: 11.32, keeps: .before)
        XCTAssertTrue(edge.clipped, "a cut in the closure cuts \"takes\" to \"ta\"")
        XCTAssertEqual(try XCTUnwrap(edge.gap), 0.04, accuracy: 0.015)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "the pause after the word is nearer than the one before it")
    }

    func testACutInAShortDipWithTheVoiceGoingOnIsClipped() throws {
        // Fluent speech: 60 ms between the words, too short for a pause. The
        // clip's last 25 ms is the quiet dip, but the sound can't tell that
        // from the closure inside "extract" or "because", and on the Ian
        // video (#64) those were most of the cuts a quiet kept side passed.
        // Voice going on past the edge, with no pause first, clips it.
        let dip = Take(words: [(10.6, 11.3), (11.36, 11.8), (12.4, 12.8)])
        let end = judge(dip, at: 11.33, keeps: .before)
        XCTAssertTrue(end.clipped, "the clip's last 25 ms is the dip, but the voice goes on")
        XCTAssertGreaterThan(try XCTUnwrap(end.margin), CutAudit.cleanFrom, "quiet beside the cut")
        XCTAssertEqual(try XCTUnwrap(end.gap), 0.06, accuracy: 0.015)
        XCTAssertTrue(judge(dip, at: 11.33, keeps: .after).clipped, "and the voice before the start of a clip there")

        // The same words run together, as cutting a filler or a repeat out
        // of running speech leaves them: the kept word is still sounding at
        // the cut, however exactly it sits on the word boundary (#64).
        let fluent = Take(words: [(10.6, 11.3), (11.3, 12.0), (12.6, 13.0)])
        let edge = judge(fluent, at: 11.3, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertLessThan(try XCTUnwrap(edge.margin), CutAudit.clippedUnder)
        XCTAssertEqual(edge.fix, .nothingNearby, "no pause within reach either side")
    }

    func testTheFloorIsTakenFromTheSoundAroundTheEdge() {
        // A take that gets louder: its noise floor 20 dB up in the second
        // half. A floor from the whole take would call the louder room's
        // soft syllables quiet; the floor beside each edge doesn't.
        var samples = Take(length: 10, words: [(11.0, 11.5)]).samples
        for i in (samples.count / 2)..<samples.count { samples[i] *= 10 }
        let energy = SpeechEnergy(samples: samples, sampleRate: Take.rate, start: 10)
        let placer = CutPlacer(energy, levels: SpeechLevels(of: [energy]))
        let quiet = placer.around(11.25), loud = placer.around(18)
        XCTAssertEqual(loud.floor - quiet.floor, 20, accuracy: 3)
        XCTAssertEqual(loud.quiet - loud.floor, CutAudit.overFloor, accuracy: 0.01, "floor + 9 dB, with no cap from the loud end")
    }

    func testCuttingTheLastOfAWordWhileItsSoundingClipsIt() throws {
        // Only 30 ms of the word either side, but the cut is through the
        // voice at full level, so it's heard as chopped.
        let take = Take(words: [(11.0, 11.6), (12.0, 12.5)])
        let end = judge(take, at: 11.57, keeps: .before)
        XCTAssertTrue(end.clipped, "30 ms of the word's tail cut off")
        XCTAssertEqual(try XCTUnwrap(end.suggestion), 11.64, accuracy: 0.015, "on past the tail into the pause")
        let start = judge(take, at: 11.57, keeps: .after)
        XCTAssertTrue(start.clipped, "a 30 ms fragment of the word left at the clip's start")
        XCTAssertEqual(try XCTUnwrap(start.suggestion), 11.64, accuracy: 0.015, "past the fragment")
    }

    func testACutInTheClosureBeforeAFinalTIsClipped() throws {
        // "extract": the vowel, the 50 ms closure before the "t", a 30 ms
        // burst, then a pause. The clip's last 25 ms is the quiet closure,
        // so its level says nothing; the short burst past the cut, with a
        // pause after it, is what gives it away: it belongs to the kept word.
        let take = Take(words: [(10.8, 11.3), (12.0, 12.4)], releases: [(11.35, 11.38)])
        let edge = judge(take, at: 11.33, keeps: .before)
        XCTAssertTrue(edge.clipped, "\"extract\" cut to \"extrac\"")
        XCTAssertGreaterThan(try XCTUnwrap(edge.margin), CutAudit.cleanFrom, "quiet beside the cut")
        let pause = try XCTUnwrap(edge.pause)
        XCTAssertEqual(pause.lowerBound, 11.38, accuracy: 0.015, "the pause after the burst")
        let to = try XCTUnwrap(edge.suggestion)
        XCTAssertGreaterThan(to, 11.38, "past the burst")
        XCTAssertEqual(to, 11.42, accuracy: 0.015)
        XCTAssertEqual(edge.fix, .trim(to: to))

        // The pause it moves into is in the cut material, but it's not a
        // word, so it may come back; the cut word after it may not.
        let cut = judge(take, at: 11.33, keeps: .before, removed: 11.33...12.6, words: [11.97...12.42])
        XCTAssertEqual(cut.fix, .trim(to: to))
    }

    func testTheKeptSidesLevelAgainstTheSpeechSaysHowCleanAJoinIs() throws {
        // A word whose last 130 ms trail off some dB under the speech, cut
        // 30 ms into that tail, with no pause within reach before it. What's
        // cut off is the rest of the soft tail, not speech, so only the
        // clip's side says how the join sounds.
        func join(under: Double) -> CutAudit.Edge {
            let take = Take(length: 6, words: [(10.5, 11.47), (13, 14)], softWords: [(11.47, 11.6, under)])
            return judge(take, at: 11.5, keeps: .before)
        }
        let chopped = join(under: 3)
        XCTAssertEqual(chopped.verdict, .clipped, "within 3 dB of the speech, like each of Mike's cut-offs")
        XCTAssertEqual(try XCTUnwrap(chopped.margin), 3, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(chopped.suggestion), 11.63, accuracy: 0.01, "past the tail, into the pause after it")
        let marginal = join(under: 12)
        XCTAssertEqual(marginal.verdict, .marginal)
        XCTAssertFalse(marginal.clipped, "marginal doesn't fail")
        XCTAssertEqual(try XCTUnwrap(marginal.margin), 12, accuracy: 2)
        XCTAssertNil(marginal.fix)
        let clean = join(under: 18)
        XCTAssertEqual(clean.verdict, .clean, "a clean join is 15 dB or more under")
        XCTAssertFalse(clean.clipped)
    }

    func testAFixNeverPutsARemovedWordBack() throws {
        // "that [because] ...": the kept word runs straight into a cut one,
        // and the only pause in reach is after the cut word.
        let take = Take(length: 6, words: [(10.5, 11.5), (11.5, 11.75), (14.5, 15)])
        let because = 11.53...11.72
        let near = judge(take, at: 11.5, keeps: .before, removed: 11.5...12.4, words: [because])
        XCTAssertTrue(near.clipped)
        XCTAssertNil(near.suggestion, "trimming into that pause brings \"because\" back")
        XCTAssertEqual(near.fix, .putBack, "0.9 s cut here: put it back, filler and all")
        let far = judge(take, at: 11.5, keeps: .before, removed: 11.5...14.0, words: [because])
        XCTAssertTrue(far.clipped)
        XCTAssertNil(far.suggestion)
        XCTAssertEqual(far.fix, .nothingNearby, "2.5 s is too much to put back")
        // With no transcript to say a word's there, the audio can't tell.
        XCTAssertEqual(try XCTUnwrap(judge(take, at: 11.5, keeps: .before, removed: 11.5...12.4).suggestion), 11.79, accuracy: 0.015)
    }

    // MARK: - Word boundaries from the transcript and the sound together

    func testADipInsideAWordWithNoWordBoundaryIsClipped() throws {
        // "time" with a 50 ms dip before its "m", and the transcript's word
        // running right over it: no word boundary there, so it's inside a
        // word, however quiet the clip's last 25 ms is.
        let take = Take(words: [(10.5, 10.9), (11.0, 11.2), (11.25, 11.4), (12.0, 12.4)])
        let words = [word("about", 10.5, 10.93), word("time", 11.0, 11.43), word("and", 12.1, 12.4)]
        let edge = judge(take, at: 11.22, keeps: .before, transcript: words)
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(try XCTUnwrap(edge.gap), 0.05, accuracy: 0.015)
        XCTAssertTrue(judge(take, at: 11.22, keeps: .after, transcript: words).clipped, "and the start of a clip there keeps the end of a word")
    }

    func testAGapBetweenTwoWordsIsCleanForTheSideKept() throws {
        // "convex. It's": 40 ms between the words, too short for a pause,
        // with the transcript's boundary there. Bark has "It's" starting
        // 110 ms late, as it does after a short gap.
        let take = Take(words: [(10.6, 11.3), (11.34, 11.8), (12.4, 12.8)])
        let words = [word("convex.", 10.6, 11.3), word("It's", 11.45, 11.8), word("true", 12.4, 12.8)]
        // The clip keeps "convex." and the cut takes "It's" away, or the
        // other way round: either way what's kept is whole.
        let end = judge(take, at: 11.32, keeps: .before, removed: 11.32...12.3, transcript: words)
        XCTAssertEqual(end.verdict, .clean, "\(end)")
        let start = judge(take, at: 11.32, keeps: .after, removed: 10.0...11.32, transcript: words)
        XCTAssertEqual(start.verdict, .clean, "\(start)")
        // The sound alone can't tell the gap from a closure inside a word.
        XCTAssertTrue(judge(take, at: 11.32, keeps: .before).clipped)
        // And a word boundary 0.2 s from the gap isn't this one.
        let off = [word("convex.", 10.6, 11.55), word("It's", 11.55, 11.8), word("true", 12.4, 12.8)]
        XCTAssertTrue(judge(take, at: 11.32, keeps: .before, transcript: off).clipped)
    }

    func testVoicePastAGapBetweenWordsIsntTheKeptWords() throws {
        // "convex." trails off 18 dB under the speech, and the clip ends
        // 10 ms before it's done. Past that tail is the 40 ms gap, then
        // "It's" at full voice: that's the next word's voice, not the kept
        // one's, so only the quiet tail says how the join sounds.
        let take = Take(words: [(10.6, 11.24), (11.34, 11.8), (12.4, 12.8)], softWords: [(11.24, 11.3, 18)])
        let words = [word("convex.", 10.6, 11.3), word("It's", 11.45, 11.8), word("true", 12.4, 12.8)]
        let edge = judge(take, at: 11.29, keeps: .before, removed: 11.29...12.3, transcript: words)
        XCTAssertFalse(edge.clipped, "\(edge)")
        // The sound alone hears the voice going on with no pause first.
        XCTAssertTrue(judge(take, at: 11.29, keeps: .before, removed: 11.29...12.3).clipped)

        // Cut while "convex." is still at full voice, it's clipped, and the
        // fix goes on into the gap before "It's", short as it is.
        let loud = Take(words: [(10.6, 11.3), (11.34, 11.8), (12.4, 12.8)])
        let chopped = judge(loud, at: 11.27, keeps: .before, removed: 11.27...12.3, transcript: words)
        XCTAssertTrue(chopped.clipped, "\(chopped)")
        XCTAssertEqual(try XCTUnwrap(chopped.suggestion), 11.32, accuracy: 0.015)
    }

    func testAFixInsideAWordMovesOnToTheGapBeforeTheNextWord() throws {
        // "lies about time. And": the clip ends in the dip inside "time",
        // and the cut takes "And" and on. The gap between "time." and "And"
        // is 70 ms, under a pause, but it's where the word ends: the fix
        // goes on into it, never back over "time".
        let take = Take(length: 6, words: [(10.5, 10.9), (11.0, 11.2), (11.25, 11.4), (11.47, 11.8), (11.85, 12.3), (13.6, 14)])
        let words = [
            word("about", 10.5, 10.93), word("time.", 11.0, 11.43), word("And", 11.58, 11.8), word("this", 11.85, 12.3), word("is", 13.6, 14)
        ]
        let edge = judge(take, at: 11.22, keeps: .before, removed: 11.22...13.6, transcript: words)
        XCTAssertTrue(edge.clipped, "\(edge)")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 11.40, "past the end of \"time.\"")
        XCTAssertLessThan(to, 11.47, "before \"And\"")
        XCTAssertEqual(to, 11.43, accuracy: 0.015, "nearer \"time.\", by the pad")
        XCTAssertEqual(edge.fix, .trim(to: to))
        let pause = try XCTUnwrap(edge.pause)
        XCTAssertEqual(pause.lowerBound, 11.40, accuracy: 0.015)
        XCTAssertEqual(pause.upperBound, 11.47, accuracy: 0.015)

        // The same for the start of a clip that keeps "And" on: back to the
        // gap after "time.", 30 ms before "And".
        let start = judge(take, at: 11.55, keeps: .after, removed: 10.0...11.55, transcript: words)
        XCTAssertTrue(start.clipped, "\(start)")
        XCTAssertEqual(try XCTUnwrap(start.suggestion), 11.44, accuracy: 0.015)
    }

    func testATrimThatWouldDropAKeptWordIsRefused() throws {
        // "time because": "time" is kept, cut 0.1 s before its end, and runs
        // straight into "because", which is cut. On is past "because";
        // back is before "time", which drops it. Neither: put the cut back,
        // and say it's "time" that a trim back would drop.
        let take = Take(length: 6, words: [(10.9, 11.4), (11.4, 11.75), (13.5, 14)])
        let words = [word("time", 10.9, 11.4), word("because", 11.42, 11.75), word("so", 13.5, 14)]
        let edge = judge(take, at: 11.3, keeps: .before, removed: 11.3...12.5, transcript: words)
        XCTAssertTrue(edge.clipped)
        XCTAssertNil(edge.suggestion, "\(edge)")
        XCTAssertEqual(edge.fix, .putBack)
        XCTAssertEqual(edge.drops, "time")
        // With no transcript the sound can't tell "because" from the rest
        // of "time", and goes on past it.
        XCTAssertEqual(try XCTUnwrap(judge(take, at: 11.3, keeps: .before, removed: 11.3...12.5).suggestion), 11.78, accuracy: 0.015)
    }

    func testAClipEndingJustBeforeTheLastWordOfItsSentenceIsClipped() throws {
        // "lies about [time.] And this": the clip ends in the 55 ms gap
        // between "about" and the "t" of "time", and the cut takes "time."
        // and on. To the ear the join is as clean as any, but the sentence
        // is left hanging, and on the Ian video Mike heard it cut off.
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        func words(_ kept: String, _ cut: String) -> [CutAudit.Word] {
            [word(kept, 10.5, 10.96), word(cut, 10.96, 11.25), word("And", 11.41, 11.6), word("this", 11.65, 12.0), word("is", 13.6, 14)]
        }
        let edge = judge(take, at: 10.93, keeps: .before, removed: 10.93...13.5, transcript: words("about", "time."))
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.lastWordCut, "time.")
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.25, accuracy: 0.015, "past \"time.\", into the gap before \"And\"")
        XCTAssertTrue(edge.betweenWords)

        // A word that doesn't end the sentence, after one that does, or a
        // filler Mike cuts: the gap between words is clean.
        for (kept, cut) in [("about", "time"), ("about,", "time."), ("you", "know.")] {
            let join = judge(take, at: 10.93, keeps: .before, removed: 10.93...13.5, transcript: words(kept, cut))
            XCTAssertEqual(join.verdict, .clean, "\(kept) [\(cut)]: \(join)")
            XCTAssertNil(join.lastWordCut)
        }
        // And it's only the end of a clip: a clip starting on "time." opens
        // on what's left of a cut sentence instead (`fragment`).
        let start = judge(take, at: 10.93, keeps: .after, removed: 9...10.93, transcript: words("about", "time."))
        XCTAssertNil(start.lastWordCut)
        XCTAssertEqual(start.fragment, "time.")
    }

    func testTheLastWordIsOnlyCutWhenNothingPlaysItNext() {
        // The same "about [time.]" join, but nothing says "time." is cut:
        // two clips of the take meeting at different speeds aren't a
        // through-edit, and the next one plays "time." whole. Only a cut
        // stretch the word's in, or a next clip that doesn't play it,
        // leaves the sentence hanging.
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        let words = [word("about", 10.5, 10.96), word("time.", 10.96, 11.25), word("And", 11.41, 11.6), word("this", 11.65, 12.0), word("is", 13.6, 14)]
        let unknown = judge(take, at: 10.93, keeps: .before, transcript: words)
        XCTAssertEqual(unknown.verdict, .clean, "\(unknown)")
        XCTAssertNil(unknown.lastWordCut)
        let playedNext = judge(take, at: 10.93, keeps: .before, cutAway: 11.6...Double.infinity, transcript: words)
        XCTAssertEqual(playedNext.verdict, .clean, "the next clip plays the file to 11.6: \(playedNext)")
        // Nothing plays it after the clip (another file follows, or none).
        let gone = judge(take, at: 10.93, keeps: .before, cutAway: 10.93...Double.infinity, transcript: words)
        XCTAssertTrue(gone.clipped, "\(gone)")
        XCTAssertEqual(gone.lastWordCut, "time.")
    }

    func testTheLastWordFixGoesPastTheWordFromInsideTheWordBefore() throws {
        // The clip ends 20 ms before "about" does, so the edge isn't in the
        // gap between "about" and "time." but before it. The fix has to go
        // past "time.", not stop in that gap and still cut it.
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        let words = [word("about", 10.5, 10.96), word("time.", 10.96, 11.25), word("And", 11.41, 11.6), word("this", 11.65, 12.0), word("is", 13.6, 14)]
        let edge = judge(take, at: 10.88, keeps: .before, removed: 10.88...13.5, transcript: words)
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.lastWordCut, "time.")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 11.22, "past \"time.\": \(edge)")
        XCTAssertLessThan(to, 11.29, "before \"And\": \(edge)")

        // With no gap or pause past "time." in reach, it says so: put the
        // short cut back rather than trim to the gap before the word.
        let long = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.47), (11.55, 11.8), (13.6, 14)])
        let longWords = [word("about", 10.5, 10.96), word("time.", 10.96, 11.5), word("And", 11.6, 11.8), word("is", 13.6, 14)]
        let far = judge(long, at: 10.88, keeps: .before, removed: 10.88...12.5, transcript: longWords)
        XCTAssertTrue(far.clipped, "\(far)")
        XCTAssertEqual(far.lastWordCut, "time.")
        XCTAssertNil(far.suggestion, "\(far)")
        XCTAssertEqual(far.fix, .putBack)
    }

    func testAClipEndingInAPauseBeforeTheLastWordIsClipped() throws {
        // "about [time.]" with 100 ms between the words: the clip ends in a
        // real pause, as clean as a join gets, and still stops one word
        // short of the end of the sentence.
        let take = Take(length: 6, words: [(10.5, 10.9), (11.0, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        func words(_ kept: String, _ cut: String) -> [CutAudit.Word] {
            [word(kept, 10.5, 10.9), word(cut, 11.0, 11.25), word("And", 11.41, 11.6), word("this", 11.65, 12.0), word("is", 13.6, 14)]
        }
        let edge = judge(take, at: 10.92, keeps: .before, removed: 10.92...13.5, transcript: words("about", "time."))
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.lastWordCut, "time.")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 11.22, "past \"time.\": \(edge)")
        XCTAssertLessThan(to, 11.29, "before \"And\": \(edge)")
        XCTAssertEqual(judge(take, at: 10.92, keeps: .before, removed: 10.92...13.5, transcript: words("about", "time")).verdict, .clean)
    }

    func testAClipStartingJustAfterTheFirstWordOfItsSentenceIsClipped() throws {
        // "start TS. [It's] like the time": the clip starts in the gap
        // between "It's" and "like", and the cut before it takes "It's",
        // the first word of the sentence the clip keeps. The join sounds
        // clean; the sentence reads "TS. like the time".
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        func words(_ before: String, _ cut: String) -> [CutAudit.Word] {
            [word(before, 10.5, 10.9), word(cut, 10.96, 11.25), word("like", 11.3, 11.6), word("the", 11.65, 12.0), word("time", 13.6, 14)]
        }
        let edge = judge(take, at: 11.26, keeps: .after, removed: 9.0...11.26, transcript: words("TS.", "It's"))
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.firstWordCut, "It's")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 10.9, "after \"TS.\": \(edge)")
        XCTAssertLessThan(to, 10.96, "before \"It's\": \(edge)")

        // Mid-sentence, a word that ends its own sentence, or an opener
        // Mike cuts ("So", "And"): a gap between words, clean.
        for (before, cut) in [("TS", "It's"), ("TS.", "Right."), ("TS.", "So"), ("TS.", "And")] {
            let join = judge(take, at: 11.26, keeps: .after, removed: 9.0...11.26, transcript: words(before, cut))
            XCTAssertEqual(join.verdict, .clean, "\(before) [\(cut)]: \(join)")
            XCTAssertNil(join.firstWordCut)
        }
        // Only when the word is really gone: nothing says it's cut here.
        XCTAssertEqual(judge(take, at: 11.26, keeps: .after, transcript: words("TS.", "It's")).verdict, .clean)
        // And only at the start of a clip.
        XCTAssertNil(judge(take, at: 11.26, keeps: .before, removed: 11.26...13.5, transcript: words("TS.", "It's")).firstWordCut)
    }

    func testAClipStartingInAPauseAfterTheFirstWordIsClipped() throws {
        // The same, with a real pause between "It's" and "like".
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.2), (11.32, 11.6), (11.65, 12.0), (13.6, 14)])
        let words = [word("TS.", 10.5, 10.9), word("It's", 10.96, 11.2), word("like", 11.33, 11.6), word("the", 11.65, 12.0), word("time", 13.6, 14)]
        let edge = judge(take, at: 11.27, keeps: .after, removed: 9.0...11.27, transcript: words)
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.firstWordCut, "It's")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertLessThan(to, 10.96, "before \"It's\": \(edge)")
    }

    func testAClipStartingOnTheLastWordOfACutSentenceIsClipped() throws {
        // "other places [do,] but I want": the clip starts in the closure
        // gap before "do,", the last word of the sentence the cut before it
        // takes, so the kept side opens on a fragment of it. The fix starts
        // the clip after "do,", in the gap before "but".
        let take = Take(length: 6, words: [(10.5, 10.9), (10.955, 11.22), (11.29, 11.6), (11.65, 12.0), (13.6, 14)])
        func words(_ cut: String, _ first: String) -> [CutAudit.Word] {
            [word(cut, 10.5, 10.9), word(first, 10.96, 11.22), word("but", 11.3, 11.6), word("I", 11.65, 12.0), word("want", 13.6, 14)]
        }
        let edge = judge(take, at: 10.93, keeps: .after, removed: 9.0...10.93, transcript: words("places", "do,"))
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.fragment, "do,")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 11.22, "past \"do,\": \(edge)")
        XCTAssertLessThan(to, 11.29, "before \"but\": \(edge)")

        // A sentence that ended before it, an opener ("Yeah,"), or a word
        // that doesn't end the clause: clean.
        for (cut, first) in [("places.", "do,"), ("places", "Yeah,"), ("places", "do")] {
            let join = judge(take, at: 10.93, keeps: .after, removed: 9.0...10.93, transcript: words(cut, first))
            XCTAssertEqual(join.verdict, .clean, "[\(cut)] \(first): \(join)")
            XCTAssertNil(join.fragment)
        }
    }

    func testACutOfAFillerAndTheWordBeforeItIsClipped() throws {
        // "And [the like,] challenge there": the cut was for the filler, but
        // took "the" with it, which runs straight into "like". The fix keeps
        // "the" (and the filler it runs into): past them, into the pause.
        let take = Take(length: 6, words: [(10.5, 10.9), (11.0, 11.3), (11.3, 11.6), (12.6, 13.0), (13.1, 13.4)])
        let words = [word("And", 10.5, 10.9), word("the", 11.0, 11.3), word("like,", 11.3, 11.6), word("challenge", 12.6, 13.0), word("there", 13.1, 13.4)]
        let edge = judge(take, at: 10.95, keeps: .before, removed: 10.95...12.55, transcript: words)
        XCTAssertTrue(edge.clipped, "\(edge)")
        XCTAssertEqual(edge.beforeFiller, "the")
        let to = try XCTUnwrap(edge.suggestion, "\(edge)")
        XCTAssertGreaterThan(to, 11.6, "past \"the, like,\": \(edge)")
        XCTAssertLessThan(to, 12.6, "before \"challenge\": \(edge)")

        // "the, like, the challenge": a false start Mike cuts, word and all.
        let restart = Take(length: 6, words: [(10.5, 10.9), (11.0, 11.3), (11.3, 11.6), (12.0, 12.3), (12.6, 13.0)])
        let restartWords = [word("And", 10.5, 10.9), word("the", 11.0, 11.3), word("like,", 11.3, 11.6), word("the", 12.0, 12.3), word("challenge", 12.6, 13.0)]
        let falseStart = judge(restart, at: 10.95, keeps: .before, removed: 10.95...12.55, transcript: restartWords)
        XCTAssertEqual(falseStart.verdict, .clean, "\(falseStart)")
        XCTAssertNil(falseStart.beforeFiller)
    }

    func testACutOfAFillerIsOnlyJudgedWhenTheTranscriptCoversAllOfIt() {
        // A long cut, 10.95 to 20, of "the like" and on to a false start
        // ("the old approach") at 15. With only the 3 s of transcript either
        // side of the edge, the cut looks like "the like" alone; it isn't.
        let take = Take(length: 24, words: [(10.5, 10.9), (11.0, 11.3), (11.3, 11.6), (15.0, 15.3), (15.4, 16.0), (20.6, 21.0)])
        let all = [word("And", 10.5, 10.9), word("the", 11.0, 11.3), word("like,", 11.3, 11.6), word("the", 15.0, 15.3), word("old", 15.4, 15.6),
                   word("approach", 15.6, 16.0), word("challenge", 20.6, 21.0)]
        let near = all.filter { $0.end >= 10.95 - CutAudit.around && $0.start <= 10.95 + CutAudit.around }
        let partial = judge(take, at: 10.95, keeps: .before, removed: 10.95...20.0, transcript: near)
        XCTAssertNil(partial.beforeFiller, "\(partial)")
        // All of it: the false start shows, so it's a cut on purpose.
        let whole = judge(take, at: 10.95, keeps: .before, removed: 10.95...20.0, transcript: all)
        XCTAssertNil(whole.beforeFiller, "\(whole)")
    }

    func testAnEdgeInARealPauseIsClean() {
        let take = Take(words: [(11.0, 11.5), (11.6, 12.0)])
        for side in [CutAudit.Side.before, .after] {
            let edge = judge(take, at: 11.55, keeps: side)
            XCTAssertEqual(edge.verdict, .clean)
            XCTAssertNil(edge.fix)
        }
    }

    func testEightyMillisecondsOfQuietIsAPause() {
        // #64 measured real pauses at 70 ms or more under floor + 9 dB, but
        // closures inside words on the Ian video ran to 95 ms.
        let take = Take(words: [(11.0, 11.5), (11.585, 12.0)])
        XCTAssertEqual(judge(take, at: 11.54, keeps: .before).verdict, .clean)
        XCTAssertEqual(judge(take, at: 11.54, keeps: .after).verdict, .clean)
        let closure = Take(words: [(11.0, 11.5), (11.565, 12.0)])
        XCTAssertTrue(judge(closure, at: 11.53, keeps: .before).clipped, "65 ms is a closure, with the word going on after it")
    }

    func testBreathInAPauseIsStillAPause() {
        // Breath and mouth noise reach above 4 kHz in a pause, well over the
        // floor there but far under an "s", so the pause is still a pause.
        let take = Take(words: [(11.0, 11.5), (12.0, 12.5)], breaths: [(11.6, 11.9)])
        let energy = take.energy
        let near = around(energy, 11.75)
        XCTAssertGreaterThan(energy.high[energy.index(of: 11.75)], near.highFloor + CutAudit.overFloor, "the breath is over floor + 9 dB")
        XCTAssertEqual(judge(take, at: 11.75, keeps: .before).verdict, .clean)
        XCTAssertEqual(judge(take, at: 11.75, keeps: .after).verdict, .clean)
    }

    func testAFinalSIsHeardAboveFourKilohertz() throws {
        let take = Take(words: [(11.0, 11.4)], esses: [(11.4, 11.5)])
        let energy = take.energy
        let near = around(energy, 11.42)
        XCTAssertLessThan(energy.full[energy.index(of: 11.45)], near.speech - CutAudit.runOnUnder, "the s is nowhere near speech level in the full band")
        XCTAssertGreaterThan(energy.high[energy.index(of: 11.45)], near.highQuiet)
        let edge = judge(take, at: 11.42, keeps: .before)
        XCTAssertTrue(edge.clipped, "the s is cut off")
        XCTAssertTrue(edge.highBandOnly)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.54, accuracy: 0.015)
    }

    func testAFragmentAtTheStartOfAClipIsDroppedWhenThatsNearer() throws {
        // The clip starts 80 ms before the end of a word that was cut out.
        let take = Take(words: [(11.0, 11.6), (12.0, 12.5)])
        let edge = judge(take, at: 11.52, keeps: .after)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(edge.kept, 0.08, accuracy: 0.015)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.64, accuracy: 0.015, "later, past the fragment")
    }

    func testTheStartOfAWordCutOffAtTheStartOfAClipMovesEarlier() throws {
        let take = Take(words: [(11.0, 11.6)])
        let edge = judge(take, at: 11.1, keeps: .after)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(try XCTUnwrap(edge.lost), 0.1, accuracy: 0.015)
        // 0.08 s before the word: before a word, the end of the quiet is
        // often its "p" or "t" bursting, after a silent closure.
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 10.92, accuracy: 0.015, "inside the pause before the word")
    }

    func testAPauseHalfASecondAwayIsInReach() throws {
        // The fixes that worked on the Ian video moved edges up to half a
        // second, into the pause after the word.
        let take = Take(words: [(11.0, 11.9), (12.5, 12.9)])
        let edge = judge(take, at: 11.5, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertEqual(try XCTUnwrap(edge.lost), 0.4, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(edge.suggestion), 11.93, accuracy: 0.01, "30 ms into the pause")
    }

    func testNoPauseInReachLeavesItToAPerson() {
        let take = Take(words: [(10.5, 12.5)])
        let edge = judge(take, at: 11.5, keeps: .before)
        XCTAssertTrue(edge.clipped)
        XCTAssertNil(edge.suggestion)
        XCTAssertNil(edge.lost, "no pause within reach past the cut")
        XCTAssertEqual(edge.fix, .nothingNearby)
    }

    func testATakeWithNoVoiceIsntJudged() {
        let silent = SpeechEnergy(samples: [Float](repeating: 0, count: 32_000), sampleRate: Take.rate, start: 0)
        XCTAssertFalse(SpeechLevels(of: [silent]).isVoice, "a screen recording's silent system sound")
        XCTAssertTrue(SpeechLevels(of: [Take(words: [(11.0, 11.6)]).energy]).isVoice)
    }

    func testReadsAFileInItsOwnTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speech-energy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("voice.wav")
        // Quiet to 3 s, a tone to 4 s, quiet to 6 s.
        try SyntheticMedia.writeAudioFile(to: url, segments: [(3, 0.0005), (1, 0.3), (2, 0.0005)], frequency: 300, sampleRate: 48_000, channels: 2)
        let energy = try await SpeechEnergy.read(url: url, from: 2, to: 5)
        XCTAssertEqual(energy.start, 2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(energy.full.count - 600), 1, "\(energy.full.count) frames")
        let quiet = around(energy, 3.5).quiet
        XCTAssertLessThan(energy.full[energy.index(of: 2.98)], quiet)
        XCTAssertGreaterThan(energy.full[energy.index(of: 3.02)], quiet)
        XCTAssertGreaterThan(energy.full[energy.index(of: 3.98)], quiet)
        XCTAssertLessThan(energy.full[energy.index(of: 4.02)], quiet)
    }
}
