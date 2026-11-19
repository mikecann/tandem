import XCTest
@testable import TandemMedia

/// `CutEvidence`: the levels, the transcript's rules and listening weighed
/// together at a heard join. The cases are joins from Mike's published
/// Tandem video, judged by reading them again, and the Ian whiteboard video's
/// joins Mike heard clipped.
final class CutEvidenceTests: XCTestCase {
    private func join(_ said: String, _ heard: String, _ findings: [CutListen.Finding] = []) -> CutListen.Join {
        CutListen.Join(time: 10, said: said, heard: heard, findings: findings)
    }

    private func extra(_ text: String, at time: Double = 9.8, slip: Bool = false) -> CutListen.Finding {
        CutListen.Finding(kind: .extra, heard: text, time: time, slip: slip, why: "heard right at the join")
    }

    func testALevelFlagOnAJoinHeardWholeIsDismissed() {
        // 9:06: "bad takes, | So I have", 27 dB under, the voice running on.
        let heard = join("it's gonna remove the bad takes, | So I have like", "It's gonna remove the bad takes. | So I have like the")
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 27.4)], cut: [])
        XCTAssertEqual(verdict.dismissed, [0: "levels flagged it, but every kept word is heard whole"])
        XCTAssertFalse(verdict.heardCutOff)
    }

    func testALevelFlagNearSpeechLevelStandsWhateverIsHeard() {
        // Ian heard-05: 2.8 dB under, and the engine filled in what was cut.
        let heard = join("Yeah, but we need to do that | to keep it deterministic.", "Yeah, but we need to do that | to keep it deterministic.")
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 2.8)], cut: [])
        XCTAssertEqual(verdict.dismissed, [:])
        XCTAssertEqual(verdict.tooClose, [0: 2.8], "heard whole, but too close to the speech for listening to clear it")
    }

    func testALastWordCutThatIsHeardIsDismissed() {
        // 9:01: the transcript has "that." cut; the engine hears it, and
        // "Um," heard as "that." is the same word.
        let finding = CutListen.Finding(kind: .heardAs, said: "Um,", heard: "that.", time: 10.05, slip: true, why: "a name")
        let heard = join("and stuff like | Um, so me. what it needs", "and stuff like that. | So, what it needs", [finding])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 36.2, lastWordCut: "that.")], cut: ["that.", "Um,"])
        XCTAssertEqual(verdict.dismissed, [0: "\"that.\" is heard, so the cut keeps it"])
        XCTAssertNotNil(verdict.explained[0])
    }

    func testALastWordCutNotHeardStands() {
        // 13:17 (real): "go back and | Reflection pass" loses "a".
        let heard = join("i'll probably go back and | Reflection pass, and", "I'll probably go back and do | reflection pass, and", [extra("do", slip: true)])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 7, beforeFiller: "a")], cut: ["do", "a"])
        XCTAssertEqual(verdict.dismissed, [:])
    }

    func testAFlagWithAListeningFindingStandsAndTheFindingConfirmsIt() {
        // 14:59 (real): "weeks" isn't heard, and the last-word rule fired.
        let finding = CutListen.Finding(kind: .notHeard, said: "weeks", time: 9.95, slip: false, why: "nothing heard for it")
        let heard = join("up until until a few a weeks few weeks | Hi, so I've", "up until a few | Hi. So I've", [finding])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 0.5, lastWordCut: "released.")], cut: ["ago", "released."])
        XCTAssertEqual(verdict.dismissed, [:])
        XCTAssertEqual(verdict.confirming, [0], "said twice, but not heard at all")
        XCTAssertTrue(verdict.heardCutOff)
    }

    func testASlipOnTheKeptWordAtTheJoinKeepsTheLevelFlag() {
        // 11:09 (real): "it's" heard as "is", at speech level.
        let finding = CutListen.Finding(kind: .heardAs, said: "it's", heard: "is", time: 9.8, slip: true, why: "a near spelling")
        let heard = join("programme called Formula. and it's | Yeah, I'm not sure", "program called For More. And is | Yeah, I'm not sure", [finding])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 6.5)], cut: ["been", "a"])
        XCTAssertEqual(verdict.dismissed, [:])
        XCTAssertEqual(verdict.confirming, [0])
        XCTAssertFalse(verdict.heardCutOff)
    }

    func testASlipOnTheOtherSideOfTheJoinDoesntKeepTheLevelFlag() {
        // The workbench short (19 Nov 2026): "in like | the first wood
        // project", with "the first time" cut on purpose. The engine left
        // out "like", before the join; the levels flagged the start of the
        // clip after it, 19 dB under, and the flag's fix put the cut back.
        let finding = CutListen.Finding(kind: .notHeard, said: "like", time: 9.9, slip: true, why: "a short or filler word the engine often leaves out")
        let heard = join(
            "annoying i didn't discover that until i was like a little bit further in like | the first wood project didn't make any mistakes",
            "Annoying. I didn't discover that until I was like a little bit further in. | The first wood project didn't make any mistakes,", [finding]
        )
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .after, margin: 19)], cut: ["the", "first", "time"])
        XCTAssertEqual(verdict.confirming, [])
        XCTAssertEqual(verdict.dismissed, [0: "levels flagged it, but every kept word is heard whole"])
        XCTAssertFalse(verdict.heardCutOff)

        // The same slip does back up a flag on its own side.
        let before = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 6.5)], cut: ["the", "first", "time"])
        XCTAssertEqual(before.confirming, [0])

        // With a flag either side, it backs up its own, and the other is
        // judged on what's heard after the join.
        let both = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 6.5), .init(keeps: .after, margin: 19)], cut: ["the", "first", "time"])
        XCTAssertEqual(both.confirming, [0])
        XCTAssertEqual(both.dismissed, [1: "levels flagged it, but every kept word is heard whole"])
    }

    func testACutWordHeardWholeIsExplainedAndDismissesTheLevels() {
        // 9:42: the transcript has "see" just past the edge.
        let heard = join("and we should hopefully | the first pass edit", "and we should hopefully see | the first pass edit,", [extra("see")])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 21.5)], cut: ["see", "the"])
        XCTAssertNotNil(verdict.explained[0])
        XCTAssertFalse(verdict.heardCutOff)
        XCTAssertEqual(verdict.dismissed.count, 1)
    }

    func testAWordHeardThatIsntACutWordStands() {
        // 20:05 (real): "pub" is left of a word the take cuts.
        let heard = join("every video I've made in the | comfortable, and let's", "every video i've made in the pub | comfortable and let's", [extra("pub")])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .before, margin: 7.7)], cut: ["past", "couple"])
        XCTAssertEqual(verdict.explained, [:])
        XCTAssertTrue(verdict.heardCutOff)
        XCTAssertEqual(verdict.dismissed, [:])
    }

    func testAPieceOfACutWordIsntWhole() {
        XCTAssertFalse(CutEvidence.sameWord("extract", "extra"))
        XCTAssertTrue(CutEvidence.sameWord("mistakes,", "mistakes"))
        XCTAssertTrue(CutEvidence.sameWord("mistake", "mistakes"))
        let heard = join("maybe you can | hey, what was", "maybe you can extra | hey, what was", [extra("extra")])
        XCTAssertTrue(CutEvidence.judge(heard, flags: [], cut: ["extract", "like"]).heardCutOff)
    }

    func testWordsThatSoundTheSameAreExplained() {
        let finding = CutListen.Finding(kind: .heardAs, said: "mic.", heard: "Mike.", time: 9.4, slip: false, why: "a different word")
        let verdict = CutEvidence.judge(join("Anyway, back to pass mic. | so", "Anyway, back to Pass Mike. |", [finding]), flags: [], cut: [])
        XCTAssertNotNil(verdict.explained[0])
        XCTAssertFalse(CutEvidence.soundsAlike("new", "nude"))
    }

    func testAWordHeardBesideTheOneItWasLinedUpWithIsExplained() {
        // 9:54: "etc" heard as "etcetera", then "Anyway," which the take cut.
        let findings = [
            CutListen.Finding(kind: .extra, heard: "etcetera.", time: 9.69, slip: true, why: "away from the join"),
            CutListen.Finding(kind: .heardAs, said: "etc", heard: "Anyway,", time: 9.73, slip: false, why: "a different word"),
        ]
        let heard = join("get rid of the bad takes etc | let's just let's just", "get rid of the bad takes, etcetera. | Anyway, let's just", findings)
        let verdict = CutEvidence.judge(heard, flags: [], cut: ["i", "mean", "um", "anyway"])
        XCTAssertNotNil(verdict.explained[1])
        XCTAssertFalse(verdict.heardCutOff)
    }

    func testNothingHeardOnASideIsTheTranscriptsNotACutOff() {
        // 10:39: the take's words over silence before "I'm back with tea".
        let finding = CutListen.Finding(kind: .notHeard, said: "again.", time: 9.93, slip: false, why: "nothing heard for it")
        let verdict = CutEvidence.judge(join("Let me just enter again. | and i'm back with tea", "| and i'm back with tea", [finding]), flags: [], cut: [])
        XCTAssertNotNil(verdict.explained[0])
        XCTAssertFalse(verdict.heardCutOff)
    }

    func testAWordTheTakeHasTwiceAndIsHeardOnceIsExplained() {
        // 11:00: "Every Just about every video", heard "Just about every video".
        let finding = CutListen.Finding(kind: .notHeard, said: "Every", time: 10.6, slip: false, why: "nothing heard for it")
        let heard = join("and watch it. | Every Just about every video I've", "and watch it. | Just about every video I've", [finding])
        let verdict = CutEvidence.judge(heard, flags: [.init(keeps: .after, margin: 6.3)], cut: [])
        XCTAssertNotNil(verdict.explained[0])
        XCTAssertEqual(verdict.dismissed.count, 1)
    }

    func testAFragmentIsntDismissedByHearingIt() {
        // Ian approved-27: "| do, but I wanna", which Mike heard as wrong.
        let heard = join("have been filled out, | do, but I wanna start", "have been filled out, | do, but I wanna start")
        XCTAssertEqual(CutEvidence.judge(heard, flags: [.init(keeps: .after, margin: 22.3, fragment: "do,")], cut: []).dismissed, [:])
    }
}
