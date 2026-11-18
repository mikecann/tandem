import XCTest
@testable import TandemCore

/// The proof list (`tandem claims`) and `tandem check`'s bareClaim note.
/// The lines are Mike's own, from the Convex Auth v2, 1.50.0 release, Exact
/// + Convex and Let's Build It videos, where his review asked for the thing
/// he named to be on screen ("Show these on screen, show per user billing
/// pricing", "show the actual request... while I'm talking about it").
final class ClaimsTests: XCTestCase {
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    static let screen = MediaItem(id: "med_screen", path: "take-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true)
    static let still = MediaItem(id: "med_still", path: "broll/clerk-pricing.png", kind: .image, role: .broll, duration: nil, width: 3840, height: 2160)

    /// Words 0.3 s apart from 0, a sentence a line, with a 0.6 s pause
    /// between lines.
    private func words(_ lines: [String]) -> [QualityCheck.Speech.Word] {
        var words: [QualityCheck.Speech.Word] = []
        var time = 0.0
        for line in lines {
            for word in line.split(separator: " ") {
                words.append(.init(text: String(word), start: t(time), end: t(time + 0.25)))
                time += 0.3
            }
            time += 0.6
        }
        return words
    }

    private func said(_ claims: [SpokenClaim]) -> [String] { claims.map(\.said) }

    static let auth = [
        "So, if you aren't familiar, Convex auth is auth that lives inside of your Convex backend.",
        "So no third party service to sign up for, and you know, no per user billing like you might get from clerk or work OS.",
        "So making sure you grab yourself a lovely cup of tea.",
        "You don't end up with half a user hanging around, which is great.",
        "So yeah, if you've used Clerk or WorkOS before, you might remember having to set up webhooks into Convex.",
        "Well, we don't need that anymore because all the information is already in the database.",
        "And it only works with React and Next.js at the moment."
    ]

    // MARK: - What counts

    func testNamesNumbersAndPricingAreClaimsAndChatIsnt() {
        let found = QualityCheck.claims(in: words(Self.auth))
        XCTAssertEqual(said(found), [
            Self.auth[0], Self.auth[1], Self.auth[4], Self.auth[6]
        ], "the cup of tea, half a user and the database line name nothing to show")
        XCTAssertTrue(found[1].because.contains("per user"), "\(found[1].because)")
        XCTAssertTrue(found[1].because.contains("billing"), "\(found[1].because)")
        // "clerk" in lower case is still Clerk: Bark wrote it capitalised later.
        XCTAssertTrue(found[1].because.contains("clerk"), "\(found[1].because)")
        XCTAssertEqual(found[3].because, ["React", "Next.js"])
    }

    func testTheVideosOwnSubjectCountsOnceAndARepeatWithinAMinuteIsTheSameProof() {
        // Convex in every line of a Convex video: only its first mention.
        let lines = [
            "Convex is the backend we use.",
            "The team at Convex built it today.",
            "I asked Convex support about it.",
            "Then Convex just fixed it for me.",
            "We moved our app onto Convex yesterday."
        ]
        let found = QualityCheck.claims(in: words(lines))
        XCTAssertEqual(said(found), [lines[0]], "the subject after its first mention isn't a claim on its own")
        // Clerk named twice in a few seconds is one thing to show.
        let twice = QualityCheck.claims(in: words(["We compared it with Clerk today.", "And Clerk was fine, honestly."]))
        XCTAssertEqual(twice.count, 1)
    }

    func testVersionsSaidOutLoudAndThingsToPointAt() {
        let lines = [
            "Right, convex1.50 is here, and the big one this time came straight from a request on ship, our feature request board.",
            "So from one dot five zero onwards, you're gonna get an actual error.",
            "So, if you spotted this warning in your logs, the fix is easy.",
            "There's a bug fix for npx convex dev dash dash once if you're using that.",
            "He says here, your agent has control over the clock.",
            "It is supposed to be much, much faster.",
            "If you want the mutation just to stop early, just return from it."
        ]
        let found = QualityCheck.claims(in: words(lines))
        XCTAssertEqual(said(found), Array(lines.dropLast()), "stopping early names nothing")
        XCTAssertTrue(found[0].because.contains("convex1.50"), "\(found[0].because)")
        XCTAssertTrue(found[0].because.contains("feature request"), "\(found[0].because)")
        XCTAssertEqual(found[1].because, ["one dot five"])
        XCTAssertEqual(found[2].because, ["this warning"])
        XCTAssertEqual(found[3].because, ["npx", "dash dash"])
        XCTAssertEqual(found[4].because, ["says here", "he says"])
        XCTAssertEqual(found[5].because, ["faster"])
    }

    func testAMissedFullStopIsntANameAndARunOfNamesIsOne() {
        // Bark ran on past a full stop: "For" isn't a name.
        let found = QualityCheck.claims(in: words([
            "Mutations that are already running didn't ever actually cancel them For a while now, it's just been logging the fact.",
            "Hey Josh, what should we change in Snake Math Rescue?"
        ]))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.because, ["Josh", "Snake Math Rescue"])
    }

    func testAWordMostlyWrittenInLowerCaseIsntAName() {
        // "Let's Build It" capitalises Build once; he says build forty times.
        let lines = ["This is Let's Build It, my app."] + Array(repeating: "We build it and we build it again.", count: 4)
        XCTAssertEqual(QualityCheck.claims(in: words(lines)), [])
    }

    func testAnIDComesFromTheWordsSoACutThatMovesTheLineKeepsIt() {
        let line = "No per user billing like you might get from Clerk."
        let first = QualityCheck.claims(in: words([line]))
        let moved = QualityCheck.claims(in: words(["So we sat down and had a nice long chat.", line]))
        XCTAssertEqual(first.first?.id, moved.last?.id)
        XCTAssertTrue(first.first?.id.hasPrefix("c") == true)
        XCTAssertEqual(first.first?.id.count, 7)
        // An um cut out of it doesn't change it either.
        let withUm = QualityCheck.claims(in: words(["No per user billing, um, like you might get from Clerk."]))
        XCTAssertEqual(withUm.first?.key, first.first?.key)
        // Said again two minutes later, the second gets its own ID.
        let later = words([line]).map { QualityCheck.Speech.Word(text: $0.text, start: $0.start + t(120), end: $0.end + t(120)) }
        let twice = QualityCheck.claims(in: words([line]) + later)
        XCTAssertEqual(twice.map(\.id), [first.first?.id ?? "", (first.first?.id ?? "") + "-2"])
    }

    // MARK: - What's on screen

    private func project(portrait: Bool = false, camera: VideoProperties? = nil, broll: [Clip] = [], name: String = "Convex Auth v2") -> Project {
        var project = Project.standard(name: name)
        project.settings.width = portrait ? 1080 : 3840
        project.settings.height = portrait ? 1920 : 2160
        project.media = [Self.camera, Self.screen, Self.still]
        project.videoTracks[0].clips = [Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(60))]
        project.videoTracks[1].clips = [Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(60), video: camera)]
        project.videoTracks[2].clips = broll
        return project
    }

    private func speech(_ lines: [String]) -> QualityCheck.Speech {
        QualityCheck.Speech(words: words(lines), clipIDs: ["clip_voice"])
    }

    func testWhatsOnScreenOverEachClaim() {
        let lines = [Self.auth[1], Self.auth[2], Self.auth[4]]
        let spoken = QualityCheck.claims(in: words(lines))
        let second = spoken[1]
        // The pricing page over the second claim, the first left bare.
        let shot = Clip(id: "clip_pricing", content: .media(mediaID: "med_still"), start: second.start, duration: second.end - second.start)
        let found = QualityCheck.claims(in: project(broll: [shot]), speech: speech(lines))
        XCTAssertEqual(found.map(\.shownClipIDs), [[], ["clip_pricing"]])
        XCTAssertEqual(found[0].bare, 1)
        XCTAssertEqual(found[0].cameraClipID, "clip_camera")
        XCTAssertEqual(found[1].bare, 0)
        // The screen recording with him in the corner shows the demo.
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5))
        let demo = QualityCheck.claims(in: project(camera: pip), speech: speech(lines))
        XCTAssertEqual(demo.map(\.shownClipIDs), [["clip_screen"], ["clip_screen"]])
        XCTAssertEqual(demo.map(\.bare), [0, 0])
    }

    func testAFinishedVideoPlayedInTheTakeIsntHimOnCamera() {
        // Let's Build It technical plays its launch video on the camera
        // track: that's something shown, not him talking.
        let lines = [Self.auth[1]]
        var played = project()
        played.media.append(MediaItem(id: "med_launch", path: "broll/announcement-full.mp4", kind: .video, role: .broll, duration: t(240), width: 3840, height: 2160, hasVideo: true, hasAudio: true))
        played.videoTracks[1].clips = [Clip(id: "clip_launch", content: .media(mediaID: "med_launch"), start: .zero, duration: t(60))]
        let found = QualityCheck.claims(in: played, speech: speech(lines))
        XCTAssertEqual(found.map(\.shownClipIDs), [["clip_launch"]])
        XCTAssertEqual(found.map(\.bare), [0])
    }

    func testTheProjectsNameIsTheSubjectHoweverBarkSpellsIt() {
        let lines = [
            "Today I'm showing you Threadbear, my agent app.",
            "I built Threadbare because my laptop kept sleeping.",
            "And one of the key things I wanted to build into Threadbear was patches."
        ]
        let found = QualityCheck.claims(in: words(lines), subject: "Threadbear Launch")
        XCTAssertEqual(said(found), [lines[0]])
    }

    // MARK: - Answers

    func testAnswersMatchBackByTheirWords() {
        let lines = [Self.auth[1], Self.auth[4], Self.auth[6]]
        let found = QualityCheck.claims(in: words(lines))
        let answers = [
            // Answered before a cut moved it 40 s earlier.
            ClaimAnswer(id: found[0].id, said: Self.auth[1], at: t(52), shot: "broll/clerk-pricing.png", link: "https://clerk.com/pricing"),
            // A cut since took "before" out of the line.
            ClaimAnswer(said: "So yeah, if you've used Clerk or WorkOS, you might remember having to set up webhooks into Convex.", skip: "the webhook diagram covers it"),
            // A line that's been cut.
            ClaimAnswer(said: "Pricing is twenty dollars a month for the pro plan.", shot: "pricing page")
        ]
        let matched = QualityCheck.match(found, answers: answers)
        XCTAssertEqual(matched.byClaim[found[0].id]?.shot, "broll/clerk-pricing.png")
        XCTAssertEqual(matched.byClaim[found[1].id]?.skip, "the webhook diagram covers it", "most of the words are the same")
        XCTAssertNil(matched.byClaim[found[2].id])
        XCTAssertEqual(matched.unmatched.map(\.shot), ["pricing page"])
        XCTAssertFalse(ClaimAnswer(said: "x", shot: "  ", link: "", skip: nil).isAnswered, "blanks are no answer")
    }

    /// A line said twice keeps each answer with its own saying when the
    /// first is cut: IDs number repeats in order, so time tells them apart.
    func testCuttingTheFirstOfALineSaidTwiceKeepsTheSecondsAnswer() {
        let line = "Check out the brand new Convex Auth v2."
        let key = QualityCheck.claimKey(line)
        // After the cut the second saying is the only one, and gets the base ID.
        let survivor = SpokenClaim(id: "cl_line", key: key, start: t(190), end: t(193), said: line, because: ["Convex Auth"])
        let answers = [
            ClaimAnswer(id: "cl_line", said: line, at: t(10), skip: "the title card says it"),
            ClaimAnswer(id: "cl_line-2", said: line, at: t(200), shot: "broll/auth-v2-docs.png", link: "https://docs.convex.dev/auth")
        ]
        let matched = QualityCheck.match([survivor], answers: answers)
        XCTAssertEqual(matched.byClaim["cl_line"]?.shot, "broll/auth-v2-docs.png")
        XCTAssertEqual(matched.unmatched.map(\.skip), ["the title card says it"])
    }

    /// A near match keeps the numbers and names: "ten dollars" isn't "twenty dollars".
    func testANearMatchNeedsTheSameNumbersAndNames() {
        let twenty = "I pay twenty dollars a month for the pro plan."
        let claim = SpokenClaim(id: "cl_twenty", key: QualityCheck.claimKey(twenty), start: t(30), end: t(33), said: twenty, because: ["twenty dollars"])
        let answers = [ClaimAnswer(said: "I pay ten dollars a month for the pro plan.", at: t(10), skip: "said on the pricing page already")]
        XCTAssertNil(QualityCheck.match([claim], answers: answers).byClaim["cl_twenty"])
        let named = "So yeah, if you've used Clerk before, you might remember the webhooks."
        let other = SpokenClaim(id: "cl_named", key: QualityCheck.claimKey(named), start: t(40), end: t(44), said: named, because: ["Clerk"])
        let renamed = [ClaimAnswer(said: "So yeah, if you've used WorkOS before, you might remember the webhooks.", skip: "covered")]
        XCTAssertNil(QualityCheck.match([other], answers: renamed).byClaim["cl_named"])
    }

    // MARK: - The check

    private func bare(_ project: Project, _ lines: [String], answers: [ClaimAnswer]? = nil, ranges: [TimeRange]? = nil) -> [CheckProblem] {
        QualityCheck.bareClaims(in: project, ranges: ranges ?? [TimeRange(start: .zero, end: project.duration)], speech: speech(lines), answers: answers)
    }

    func testABareClaimIsNotedUntilItsShownOrSkipped() {
        let lines = [Self.auth[1], Self.auth[2], Self.auth[6]]
        let found = bare(project(), lines)
        XCTAssertEqual(found.map(\.kind), [.bareClaim, .bareClaim])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.hasPrefix("Bare claim at 00:00.000: \"So no third party service"), message)
        XCTAssertTrue(message.contains("per user, billing"), message)
        XCTAssertTrue(message.contains("answer it in the claims list (tandem claims)"), message)
        XCTAssertEqual(found.first?.clipIDs, ["clip_camera"])
        XCTAssertTrue(CheckProblem.Kind.bareClaim.isNote)

        // Skipped with a reason: quiet. Planned but not placed: still noted, saying so.
        let spoken = QualityCheck.claims(in: words(lines))
        let answered = bare(project(), lines, answers: [
            ClaimAnswer(said: Self.auth[1], skip: "he's holding up the pricing page on his phone"),
            ClaimAnswer(said: Self.auth[6], shot: "React and Next.js logos")
        ])
        XCTAssertEqual(answered.map(\.start), [spoken[1].start])
        XCTAssertTrue(answered.first?.message.contains("plans \"React and Next.js logos\" for it, but nothing is over the camera there yet") ?? false, answered.first?.message ?? "")

        // Shown: quiet.
        let shots = spoken.map { Clip(id: "clip_\($0.id)", content: .media(mediaID: "med_still"), start: $0.start, duration: $0.end - $0.start) }
        XCTAssertEqual(bare(project(broll: shots), lines), [])
        // check --changed: only the claims in the stretches checked.
        XCTAssertEqual(bare(project(), lines, ranges: [TimeRange(start: spoken[1].start, end: spoken[1].end)]).map(\.start), [spoken[1].start])
    }

    func testAShortAndAConversationArentChecked() {
        let lines = [Self.auth[1], Self.auth[6]]
        XCTAssertEqual(bare(project(portrait: true), lines), [], "a Short's picture has its own rules")
        XCTAssertEqual(bare(project(name: "Databased podcast"), lines), [], "in a conversation the people are the picture")
    }
}
