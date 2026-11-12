import XCTest
@testable import TandemCore

/// `tandem check`'s note on pauses left mid-sentence, and what a pause
/// follows by the words either side (`SpokenPause.kind`). The lines are the
/// Convex Auth v2 video's (12 Nov 2026), as Bark transcribed them, with the
/// gaps `tandem pauses` heard after `tighten --filmora`.
final class MidSentencePauseTests: XCTestCase {
    private func project(portrait: Bool = false, name: String = "Convex Auth v2") -> Project {
        var project = Project.standard(name: name)
        project.settings.width = portrait ? 1080 : 3840
        project.settings.height = portrait ? 1920 : 2160
        return project
    }

    private func pause(_ before: String, _ after: String, at start: Double, heard: Double) -> QualityCheck.HeardPause {
        QualityCheck.HeardPause(start: t(start), end: t(start + heard), before: before, after: after, clipIDs: ["clip_voice"])
    }

    private func notes(_ pauses: [QualityCheck.HeardPause], project: Project? = nil, ranges: [TimeRange] = [TimeRange(start: .zero, end: t(600))]) -> [CheckProblem] {
        QualityCheck.midSentencePauses(pauses, in: project ?? self.project(), ranges: ranges, speech: QualityCheck.Speech())
    }

    // MARK: - What a pause follows

    func testPunctuationStillDecidesMostPauses() {
        XCTAssertEqual(SpokenPause.kind(before: "talk about decision models."), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "is it?"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "wow!\""), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "and then..."), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "Well,"), .comma)
        XCTAssertEqual(SpokenPause.kind(before: "help you choose"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "two separate users.", next: "And we can put"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "for many months now", next: "And I built"), .sentence, "Bark capitalised And, so it heard a new sentence")
    }

    func testAFullStopAfterAWordNoSentenceEndsOnIsMidSentence() {
        // The pause Mike flagged: "There's weird pause here when it's mid sentence".
        XCTAssertEqual(SpokenPause.kind(before: "thing from scratch using.", next: "The latest and greatest"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "gonna get into the", next: "the details of the"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "users. And", next: "we can put two"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "and it's.", next: "Really simple"), .mid)
    }

    func testAQuestionOrAWordThatCanEndASentenceStillEndsOne() {
        // From the cross-lab review: only Bark's full stops are overridden.
        XCTAssertEqual(SpokenPause.kind(before: "What is it made of?", next: "This component"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "Look at the size of it!", next: "Okay"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "It works, though.", next: "Next"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "made of", next: "this"), .mid)
        // A stranded preposition ends one; after a noun it runs on.
        XCTAssertEqual(SpokenPause.kind(before: "the tool I'm using.", next: "Next we"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "where I'm coming from.", next: "Now"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "what it's made of.", next: "The"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "from scratch using.", next: "The latest"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "the components with.", next: "The"), .mid)
    }

    func testAFullStopBeforeALowercaseJoiningWordIsMidSentence() {
        XCTAssertEqual(SpokenPause.kind(before: "clerk or work OS.", next: "but more on that"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "components, type safety, etc.", next: "so you can just"), .mid)
        // Lowercase after a full stop on its own isn't enough: Bark writes
        // whole runs in lowercase, sentence breaks and all.
        XCTAssertEqual(SpokenPause.kind(before: "cook up for me.", next: "very simple very ugly"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "a proper video on.", next: "that's right it's off"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "the code anymore, right?", next: "but i do just"), .sentence, "a question mark is a sentence")
    }

    func testANameAfterNoFullStopStaysMidSentence() {
        XCTAssertEqual(SpokenPause.kind(before: "built it on", next: "Convex"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "and then", next: "I can sign in"), .mid)
        XCTAssertEqual(SpokenPause.kind(before: "a little bit later", next: "Out of the box,"), .sentence)
        XCTAssertEqual(SpokenPause.kind(before: "things like Google and GitHub, etc.", next: "Actually you know"), .sentence)
    }

    // MARK: - Notes

    func testTheFlaggedPauseIsNotedWithItsFix() {
        let found = notes([pause("entire thing from scratch using.", "The latest and greatest", at: 41.0, heard: 0.8)])
        XCTAssertEqual(found.map(\.kind), [.midSentencePause])
        XCTAssertTrue(CheckProblem.Kind.midSentencePause.isNote)
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("using. [0.80 s] The latest"), message)
        XCTAssertTrue(message.contains("full stop after \"using\""), message)
        XCTAssertTrue(message.contains("tandem tighten --filmora --from 00:40.500 --to 00:42.300 --mid-at 00:41.400"), message)
        XCTAssertEqual(found.first?.start, t(41.0))
        XCTAssertEqual(found.first?.clipIDs, ["clip_voice"])
    }

    func testAPauseMostlyBreathIsNoted() {
        // The real one: 0.653 s between "using." and "The" in the transcript,
        // only 0.185 s of it quiet as `tandem pauses` hears it; the rest is
        // an in-breath across the join.
        let breath = QualityCheck.HeardPause(
            start: t(41.358), end: t(41.543), gap: TimeRange(start: t(41.243), end: t(41.896)),
            before: "entire thing from scratch using.", after: "The latest and greatest", clipIDs: ["clip_a", "clip_b"]
        )
        let found = notes([breath])
        XCTAssertEqual(found.map(\.kind), [.midSentencePause])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("using. [0.65 s] The latest"), message)
        // tighten --filmora cuts by volume, so the breath goes with the quiet.
        XCTAssertTrue(message.contains("--from 00:40.743 --to 00:42.396 --mid-at 00:41.570"), message)
        XCTAssertEqual(found.first?.start, t(41.243))

        // Under 0.6 s between the words with little quiet is the words' tails.
        var tails = breath
        tails.gap = TimeRange(start: t(41.243), end: t(41.753))
        XCTAssertEqual(notes([tails]), [])
    }

    func testSentencePausesShortPausesAndBeatsArentNoted() {
        XCTAssertEqual(notes([
            pause("best principles.", "Like components, type safety,", at: 44.8, heard: 0.67),
            pause("for many months now", "And I built the", at: 37.7, heard: 0.685),
            pause("And we can", "put two separate", at: 61.8, heard: 0.47),
            pause("one for the", "core of convex auth", at: 70, heard: 3.5),
        ]), [])
    }

    func testCommasAndMidSentenceGapsAreNoted() {
        let found = notes([
            pause("visible in the dashboard,", "if you want to", at: 211.7, heard: 0.625),
            pause("very simple very ugly", "but yeah i can", at: 99.1, heard: 0.58),
        ])
        XCTAssertEqual(found.map(\.start), [t(99.1), t(211.7)], "by time")
        XCTAssertTrue(found[1].message.contains("after a comma"), found[1].message)
        XCTAssertFalse(found[1].message.contains("--mid-at"), "a comma's pause is one --filmora closes already: \(found[1].message)")
        XCTAssertTrue(found[0].message.contains("--mid-at"), found[0].message)
    }

    func testOnlyTheStretchesCheckedAndNotConversationsOrManyAtOnce() {
        let flagged = pause("thing from scratch using.", "The latest", at: 41.0, heard: 0.8)
        XCTAssertEqual(notes([flagged], ranges: [TimeRange(start: t(50), end: t(60))]), [])
        XCTAssertEqual(notes([flagged], project: project(name: "Databased podcast S2E7")), [], "a conversation's gaps are turns")

        let many = (0..<11).map { pause("and the", "thing", at: Double($0) * 10, heard: 0.7) }
        let found = notes(many)
        XCTAssertEqual(found.count, 9, "eight listed, then one for the rest")
        XCTAssertTrue(found[8].message.contains("3 more mid-sentence pauses"), found[8].message)
        XCTAssertTrue(found[8].message.contains("11 in all"), found[8].message)
        XCTAssertEqual(found[8].end, t(100.7))
        XCTAssertTrue(found[8].message.contains("tandem tighten --filmora --mid-at 01:20.350,01:30.350,01:40.350"), found[8].message)
    }
}
