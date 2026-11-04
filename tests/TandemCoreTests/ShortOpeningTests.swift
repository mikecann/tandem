import XCTest
@testable import TandemCore

/// `tandem check`'s note on how a Short opens. Every Abstract Fireside Short
/// first went out starting on the answer, and Mike had to say three times
/// that a Short must stand on its own (20 Oct, 30 Oct, 4 Nov 2026). The
/// openings here are what those Shorts said, before and after the fix.
final class ShortOpeningTests: XCTestCase {
    static let talk = MediaItem(id: "med_talk", path: "source/Fireside Chat FULL TALK v2.mp4", kind: .video, role: .camera, duration: t(3600), hasVideo: true, hasAudio: true)
    static let tip = MediaItem(id: "med_tip", path: "source/take.mov", kind: .video, role: .camera, duration: t(3600), hasVideo: true, hasAudio: true)

    /// A Short (1080x1920) playing `media` from the start, saying `said` one
    /// word every 0.3 s.
    private func short(_ said: String, media: MediaItem = talk, name: String = "Fireside 1 Agents that forget", portrait: Bool = true) -> (Project, QualityCheck.Speech) {
        var project = Project.standard(name: name)
        if portrait {
            project.settings.width = 1080
            project.settings.height = 1920
        }
        project.media = [media]
        project.videoTracks[1].clips = [Clip(id: "clip_cam", content: .media(mediaID: media.id), start: .zero, duration: t(60))]
        let words = said.split(separator: " ").enumerated().map { index, text in
            QualityCheck.Speech.Word(text: String(text), start: t(Double(index) * 0.3), end: t(Double(index) * 0.3 + 0.25))
        }
        return (project, QualityCheck.Speech(words: words, clipIDs: ["clip_cam"]))
    }

    private func notes(_ setup: (Project, QualityCheck.Speech), ranges: [TimeRange] = [TimeRange(start: .zero, end: t(60))]) -> [CheckProblem] {
        QualityCheck.shortOpening(in: setup.0, ranges: ranges, speech: setup.1)
    }

    // MARK: - Openings that flag

    func testAnOpeningOnABackReferenceIsNoted() {
        // Fireside 5's first cut.
        let found = notes(short("And it's not to say that this isn't expanding the market for custom software. Like I think all of these tools ultimately have and do."))
        XCTAssertEqual(found.map(\.kind), [.shortOpening])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("\"And it's not to say that this"), message)
        XCTAssertTrue(message.contains("refers back"), message)
        XCTAssertTrue(CheckProblem.Kind.shortOpening.isNote, "a tip Short can open on a claim, so this never fails a check")
        XCTAssertEqual(found.first?.start, .zero)
    }

    func testAQAShortOpeningOnTheAnswerIsNoted() {
        // Fireside 1's first cut: no back-reference word, but no question.
        let found = notes(short("The biggest one that I think is like unsolved, and we talked about this a little bit too, is uh. Like Agent memory, and part of the reason"))
        XCTAssertEqual(found.map(\.kind), [.shortOpening])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("The biggest one that I think"), message)
        XCTAssertTrue(message.contains("no question"), message)
    }

    func testTheOtherAreaIsABackReference() {
        // Fireside 2's first cut: "the other" of what?
        let found = notes(short("The other area that I think is very much unsolved is agent identity."))
        XCTAssertTrue(found.first?.message.contains("refers back") ?? false, found.first?.message ?? "")
    }

    func testFillersBeforeTheBackReferenceDontHideIt() {
        XCTAssertEqual(notes(short("Um, so yeah, that's where memory comes in.", media: Self.tip, name: "Tip")).map(\.kind), [.shortOpening])
    }

    func testOtherBackReferencesFromTheSkill() {
        for opening in ["Like I said, the hard part is memory.", "As you're seeing here, it reloads.", "Shifting gears a little, what about identity?", "Yeah. It was a long day."] {
            XCTAssertEqual(notes(short(opening, media: Self.tip, name: "Tip")).map(\.kind), [.shortOpening], opening)
        }
    }

    // MARK: - Openings that stay quiet

    func testAQAShortOpeningOnTheQuestionIsQuiet() {
        // Fireside 1 as it went out again: the question first, then "So I think".
        XCTAssertEqual(notes(short("What are the new problems that are emerging? So I think there are a few big ones.")), [])
    }

    func testAQuestionWithNoQuestionMarkStillCounts() {
        // Fireside 7's transcript came back with no punctuation at all, and
        // Fireside 4's question is a "what if" in the middle of the setup.
        XCTAssertEqual(notes(short("what does developer infrastructure look like in five years um yeah i think that")), [])
        XCTAssertEqual(notes(short("A few months ago, you tweeted that very few people are builders and so what if we develop all these new abstractions")), [])
    }

    func testAnUnpunctuatedQuestionWithAnyVerbCounts() {
        XCTAssertEqual(notes(short("What changed in the API this year and who should care")), [])
    }

    func testAPunctuationOnlyFirstWordStillQuotesTheBackReference() {
        let found = notes(short("- And then it broke.", media: Self.tip, name: "Tip"))
        XCTAssertTrue(found.first?.message.contains("It starts on \"And\"") ?? false, found.first?.message ?? "")
    }

    func testAChangeJustPastTheOpeningIsQuiet() {
        // A change at 12.2 s, padded half a second by `check --changed`.
        XCTAssertEqual(notes(short("And it's not to say that this isn't expanding the market."), ranges: [TimeRange(start: t(11.7), end: t(13))]), [])
    }

    func testATipShortCanOpenOnAClaim() {
        // No interview in the name or the files: no question needed.
        XCTAssertEqual(notes(short("The biggest mistake I see with Convex is reading in a loop.", media: Self.tip, name: "Tip 3 Queries")), [])
    }

    func testALandscapeVideoIsNeverNoted() {
        XCTAssertEqual(notes(short("And so that's the end of part one.", portrait: false)), [])
    }

    func testAChangedStretchAfterTheOpeningIsQuiet() {
        // `check --changed` only says it again when the opening changed.
        XCTAssertEqual(notes(short("And it's not to say that this isn't expanding the market."), ranges: [TimeRange(start: t(30), end: t(40))]), [])
        XCTAssertEqual(notes(short("And it's not to say that this isn't expanding the market."), ranges: [TimeRange(start: t(5), end: t(8))]).count, 1)
    }

    func testNothingSaidIsQuiet() {
        let (project, _) = short("")
        XCTAssertEqual(QualityCheck.shortOpening(in: project, ranges: [TimeRange(start: .zero, end: t(60))], speech: QualityCheck.Speech()), [])
    }

    func testOnlyMediaThatPlaysMakesItAnInterview() {
        // The Seth Shorts carried the Fireside files in their media list
        // without playing them.
        var (project, speech) = short("The spreadsheet that became a personal app.", media: Self.tip, name: "Seth 4")
        project.media.append(Self.talk)
        XCTAssertEqual(QualityCheck.shortOpening(in: project, ranges: [TimeRange(start: .zero, end: t(60))], speech: speech), [])
    }

    func testTheOpeningRunsTwelveSeconds() {
        let words = (0..<60).map { "w\($0)" }.joined(separator: " ")
        let found = notes(short("And " + words))
        // One word every 0.3 s: 40 of them start inside 12 s.
        XCTAssertTrue(found.first?.message.contains("w38") ?? false, found.first?.message ?? "")
        // w39 starts at exactly 12 s, so it's the first word left out.
        XCTAssertFalse(found.first?.message.contains("w39") ?? true, found.first?.message ?? "")
    }
}
