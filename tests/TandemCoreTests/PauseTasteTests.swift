import XCTest
@testable import TandemCore

/// Mike's pause taste from his own trims (`PauseTaste`), and the check's
/// note on pauses longer than he leaves them (`QualityCheck.longPauses`).
final class PauseTasteTests: XCTestCase {
    private func trim(_ kind: SpokenPause.Kind, was: Double, left: Double, revision: Int = 1, project: String = "p") -> PauseTrim {
        PauseTrim(project: project, name: "Video", revision: revision, date: Date(timeIntervalSince1970: Double(revision)), at: t(10),
                  before: "words before.", after: "words after", kind: kind, was: was, left: left)
    }

    func testUnderFiveTrimsOfAKindTheUsualHolds() {
        let taste = PauseTaste(trims: [trim(.sentence, was: 0.8, left: 0.2), trim(.sentence, was: 0.9, left: 0.25)])
        let rule = taste.rule(for: .sentence)
        XCTAssertFalse(rule.learned)
        XCTAssertEqual(rule.leave, 0.35)
        XCTAssertEqual(rule.flag, 0.6)
        XCTAssertEqual(rule.trims, 2)
    }

    func testWhatHeLeavesIsTheMiddleOfHisTrims() {
        // His sentence trims landing at 0.25 to 0.35 s, as on the Threadbear
        // launch and the Examples Page.
        let lefts = [0.25, 0.28, 0.3, 0.32, 0.35]
        let taste = PauseTaste(trims: lefts.enumerated().map { trim(.sentence, was: 0.8, left: $1, revision: $0) })
        let rule = taste.rule(for: .sentence)
        XCTAssertTrue(rule.learned)
        XCTAssertEqual(rule.leave, 0.3)
        XCTAssertEqual(rule.flag, 0.48, accuracy: 1e-9, "1.6 times what he leaves")
        // A mid-sentence one he leaves at 0.1 is long from 0.25: never under
        // 0.15 s more than he leaves.
        let mid = PauseTaste(trims: (0..<5).map { trim(.mid, was: 0.3, left: 0.1, revision: $0) }).rule(for: .mid)
        XCTAssertEqual(mid.flag, 0.25, accuracy: 1e-9)
    }

    func testABeatHeKeptAndAPauseHeLengthenedDontSetTheLength() {
        var trims = (0..<5).map { trim(.mid, was: 0.4, left: 0.12, revision: $0) }
        // The eye-shift beat on the Examples Page, cut from 3.2 s to 2 s:
        // "out. | and if you" reads as mid-sentence.
        trims.append(trim(.mid, was: 3.2, left: 2.0, revision: 10))
        trims.append(trim(.mid, was: 1.5, left: 1.1, revision: 11))
        // And one he put back to show a shrug.
        trims.append(trim(.mid, was: 0.1, left: 0.57, revision: 12))
        let taste = PauseTaste(trims: trims)
        XCTAssertEqual(taste.rule(for: .mid).leave, 0.12)
        XCTAssertEqual(taste.rule(for: .mid).trims, 5)
        XCTAssertEqual(taste.beats.count, 2)
    }

    func testLearningAProjectAgainReplacesItsTrims() {
        var taste = PauseTaste()
        taste.add([trim(.sentence, was: 0.8, left: 0.3, revision: 5)], project: "p", through: 10)
        taste.add([trim(.sentence, was: 0.8, left: 0.28, revision: 5), trim(.comma, was: 0.5, left: 0.2, revision: 12)], project: "p", through: 14)
        taste.add([trim(.sentence, was: 0.9, left: 0.3, revision: 5, project: "q")], project: "q", through: 6)
        XCTAssertEqual(taste.trims.count, 3)
        XCTAssertEqual(taste.trims.filter { $0.project == "p" && $0.revision == 5 }.map(\.left), [0.28])
        XCTAssertEqual(taste.learned, ["p": 14, "q": 6])
    }

    // MARK: - Long pauses in the check

    private func pause(_ before: String, _ after: String, at start: Double, silence: Double) -> QualityCheck.HeardPause {
        QualityCheck.HeardPause(
            start: t(start + 0.2), end: t(start + 0.4), gap: TimeRange(start: t(start + 0.1), end: t(start + 0.5)), before: before, after: after,
            clipIDs: ["clip_voice"], silence: TimeRange(start: t(start), end: t(start + silence))
        )
    }

    private func notes(_ pauses: [QualityCheck.HeardPause], taste: PauseTaste = PauseTaste()) -> [CheckProblem] {
        var project = Project.standard(name: "Examples Page")
        project.settings.width = 3840
        project.settings.height = 2160
        return QualityCheck.longPauses(pauses, taste: taste, in: project, ranges: [TimeRange(start: .zero, end: t(600))], speech: QualityCheck.Speech())
    }

    func testTheGapsMikeCalledAwkwardSilenceAreLong() {
        // The Examples Page video's two gaps: 0.8 s of silence each, a low
        // bump in them, which "heard as" had called 0.2 s.
        let found = notes([
            pause("software engineering land.", "Over the past year", at: 67.7, silence: 0.835),
            pause("past year or so.", "So if I want", at: 70.0, silence: 0.77),
            // A sentence pause he'd leave, and a mid one under the line.
            pause("for a while now.", "And then", at: 80, silence: 0.4),
            pause("whatnot for that", "framework right", at: 90, silence: 0.2),
        ])
        XCTAssertEqual(found.map(\.kind), [.longPause, .longPause])
        XCTAssertEqual(found.map(\.start), [t(67.7), t(70.0)])
        XCTAssertTrue(CheckProblem.Kind.longPause.isNote)
        let message = found[0].message
        XCTAssertTrue(message.hasPrefix("Long pause: \"...software engineering land. [0.84 s of silence] Over the past year...\", after a sentence. Mike leaves 0.35 s there"), message)
        XCTAssertTrue(message.contains("tandem tighten --from 01:07.200 --to 01:09.035 --sentence 0.35 --comma 0.20 --mid 0.12 --min 0.2 --mid-min 0.15"), message)
    }

    func testTheLinesComeFromHisTrims() {
        // He leaves 0.15 s mid-sentence, so a 0.27 s hitch is long.
        let taste = PauseTaste(trims: (0..<5).map { trim(.mid, was: 0.3, left: 0.15, revision: $0) })
        let found = notes([pause("whatnot for that", "framework right", at: 38, silence: 0.27)], taste: taste)
        XCTAssertEqual(found.map(\.kind), [.longPause])
        XCTAssertTrue(found[0].message.contains("Mike leaves 0.15 s there (the middle of 5 of his own trims)"), found[0].message)
    }

    func testAPauseTheMidSentenceNoteHasIsLeftToIt() {
        // 0.6 s inside a sentence is the mid-sentence note's, with its own fix.
        let found = notes([pause("thing from scratch using.", "The latest and greatest", at: 12, silence: 0.6)])
        XCTAssertEqual(found.map(\.kind), [])
        let mid = QualityCheck.midSentencePauses(
            [pause("thing from scratch using.", "The latest and greatest", at: 12, silence: 0.6)],
            in: Project.standard(name: "x"), ranges: [TimeRange(start: .zero, end: t(600))], speech: QualityCheck.Speech()
        )
        XCTAssertEqual(mid.map(\.kind), [.midSentencePause])
    }

    func testABeatOverFourSecondsIsLeftToDeadAir() {
        XCTAssertTrue(notes([pause("and here it is.", "So that's", at: 30, silence: 4.5)]).isEmpty)
    }
}
