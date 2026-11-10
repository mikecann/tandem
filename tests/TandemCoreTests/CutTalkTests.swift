import XCTest
@testable import TandemCore

/// `tandem check`'s notes on talk cut from a take and on how much B-roll
/// covers the camera. The lines are the Exact + Convex demo's (10 Nov 2026):
/// the first hand-back's cuts Mike asked to have back, and the cuts he kept
/// in the 4:08 video he shipped.
final class CutTalkTests: XCTestCase {
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    static let screen = MediaItem(id: "med_screen", path: "take-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3840, height: 2160, hasVideo: true)
    static let still = MediaItem(id: "med_still", path: "broll/post.png", kind: .image, role: .broll, duration: nil, width: 3840, height: 2160)

    private func project(name: String = "Exact Convex demo", portrait: Bool = false) -> Project {
        var project = Project.standard(name: name)
        project.settings.width = portrait ? 1080 : 3840
        project.settings.height = portrait ? 1920 : 2160
        project.media = [Self.camera, Self.screen, Self.still]
        return project
    }

    /// The take's words, 0.3 s each, in pieces kept or cut; kept words play
    /// back to back on the timeline from 0.
    private func take(_ pieces: [(String, kept: Bool)], mediaID: String = "med_camera") -> QualityCheck.Speech.Take {
        var words: [QualityCheck.Speech.Take.Word] = []
        var source = 0.0, timeline = 0.0
        for (text, kept) in pieces {
            for word in text.split(separator: " ") {
                words.append(.init(text: String(word), start: t(source), end: t(source + 0.25), played: kept ? t(timeline) : nil, clipID: kept ? "clip_voice" : nil))
                source += 0.3
                if kept { timeline += 0.3 }
            }
        }
        return QualityCheck.Speech.Take(mediaID: mediaID, words: words)
    }

    private func notes(_ take: QualityCheck.Speech.Take, project: Project? = nil, ranges: [TimeRange] = [TimeRange(start: .zero, end: t(600))]) -> [CheckProblem] {
        QualityCheck.cutTalk(in: project ?? self.project(), ranges: ranges, speech: QualityCheck.Speech(takes: [take]))
    }

    static let kept = "so when i saw they put out a new thing called exact i wanted to take a bit of a closer look. It's super early days, like pre-alpha, pre pre-alpha, but the idea is that you write your UI once in their own little typed language. then it runs natively on your phone, Mac, and the web."
    static let more = "anyways, of course, I had to give it a go with Convex, Let's take a look. This is the native Mac version. I can say hello from native. Send that, and it goes across. Then also, I have the mobile version here. I can say hello from phone. And then it goes across."
    static let signOff = "So yeah, anyways, super early days for exact, but Convex already plays nicely with it, so that's nice."

    // MARK: - Cuts that are noted

    func testTheOpenerCutForTimeIsNoted() {
        // The first hand-back: the opener cut to get under a minute.
        let found = notes(take([
            ("Hello, hello. I love Expo. I love Expo. Let's build it. My vibe coding app for kids is built on it.", false),
            (Self.kept, true), (Self.signOff, true)
        ]))
        XCTAssertEqual(found.map(\.kind), [.cutTalk])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("opening lines"), message)
        XCTAssertTrue(message.contains("My vibe coding app for kids is built on it."), message)
        XCTAssertFalse(message.contains("Hello, hello."), "a retake isn't quoted as talk: \(message)")
        XCTAssertEqual(found.first?.start, .zero)
        XCTAssertTrue(CheckProblem.Kind.cutTalk.isNote)
    }

    func testRealSentencesCutMidTakeAreNoted() {
        // "In the Expo vein", cut from the first hand-back.
        let found = notes(take([
            (Self.kept, true),
            ("So, very much kind of in the expo vein. It is supposed to be much, much faster and have a lot of. Things that are designed to make agentic development much, much better.", false),
            (Self.more, true), (Self.signOff, true)
        ]))
        XCTAssertEqual(found.map(\.kind), [.cutTalk])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.contains("3 sentences"), message)
        XCTAssertTrue(message.contains("in the expo vein"), message)
        // At the join: where the kept talk carries on.
        let joinedAt = Double(Self.kept.split(separator: " ").count) * 0.3
        XCTAssertEqual(found.first?.start.seconds ?? 0, joinedAt, accuracy: 0.001)
    }

    // MARK: - Cuts that aren't

    func testTheShippedCutsAreQuiet() {
        // What the 4:08 cut took out: a retake of the opener, a false start,
        // a redo, the thread said twice, and a fragment.
        let found = notes(take([
            ("Hello, hello. I love Expo.", false),
            ("I love Expo. Let's build it. My vibe coding app for kids is built on it.", true),
            (Self.kept, true),
            ("But anyway, I of course felt like I needed to. I but", false),
            (Self.more, true),
            ("they can do things like change the time of the system. so that uh let me just redo that bit", false),
            ("Yeah. So one of the things that had me interested is um Charlie, who's I think the CEO of Expo, he uh when he in his announcement kind of thread uh.", true),
            ("There's announcement, uh tweet thread, whatever it is, chain here.", false),
            ("He says here, In exact, your agent has control over the clock, which makes testing and prodding faster and easier.", true),
            ("If I just rearrange this little bit, move to the side. Editors now get rid of that. Ah fine struggling dragging. Can't drag windows at the moment for some reason. I can't drag Windows anymore.", false),
            (Self.signOff, true),
            ("i put the code in the reply if you want to have a go of yourself and let me know what you think cheerio", false)
        ]))
        XCTAssertEqual(found, [], found.map(\.message).joined(separator: "\n"))
    }

    func testOnlyJoinsInTheRangesChecked() {
        let cut = take([
            (Self.kept, true),
            ("So, very much kind of in the expo vein. It is supposed to be much, much faster and have a lot of. Things that are designed to make agentic development much, much better.", false),
            (Self.more, true)
        ])
        XCTAssertEqual(notes(cut, ranges: [TimeRange(start: t(40), end: t(60))]), [], "check --changed skips the cuts Mike has already seen")
    }

    func testAnExcerptAShortAndAConversationAreNotChecked() {
        let long = String(repeating: "We talked about agents and how they forget what they did yesterday. ", count: 40)
        let excerpt = take([(long, false), (Self.kept, true), (long, false), (Self.more, true)])
        XCTAssertEqual(notes(excerpt), [], "a social cut keeps a few lines of a long talk on purpose")

        let overCut = take([(Self.kept, true), ("So, very much kind of in the expo vein. It is supposed to be much, much faster and have a lot of. Things that are designed to make agentic development much, much better.", false), (Self.more, true)])
        XCTAssertEqual(notes(overCut, project: project(portrait: true)), [])
        XCTAssertEqual(notes(overCut, project: project(name: "Databased podcast")), [])
    }

    func testTwoMicsTalkingOverEachOtherAreAConversation() {
        // Databased S2E7: James's and Jamie's mics share one take ID and
        // play side by side for 48 minutes, under no B-roll at all.
        let james = take([(Self.kept, true), ("So, very much kind of in the expo vein. It is supposed to be much, much faster and have a lot of. Things that are designed to make agentic development much, much better.", false), (Self.more, true)])
        var jamie = take([(Self.more, true), (Self.kept, true)], mediaID: "med_jamie")
        jamie.words = jamie.words.map { var word = $0; word.played = word.played.map { $0 + t(1) }; return word }
        let speech = QualityCheck.Speech(words: [.init(text: "hello", start: .zero, end: t(0.3))], takes: [james, jamie])
        XCTAssertEqual(QualityCheck.cutTalk(in: project(name: "Databased S2E7"), ranges: [TimeRange(start: .zero, end: t(600))], speech: speech), [])
        let (talk, _) = talking()
        XCTAssertEqual(QualityCheck.littleBRoll(in: talk, ranges: [TimeRange(start: .zero, end: t(60))], speech: speech), [])
    }

    // MARK: - B-roll

    /// Mike on camera for `seconds`, the take's voice saying the kept lines,
    /// and `broll` over it.
    private func talking(_ seconds: Double = 60, broll: [Clip] = [], camera: VideoProperties? = nil, captions: [Clip] = []) -> (Project, QualityCheck.Speech) {
        var project = project()
        project.videoTracks[0].clips = [Clip(id: "clip_screen", content: .media(mediaID: "med_screen"), start: .zero, duration: t(seconds))]
        project.videoTracks[1].clips = [Clip(id: "clip_camera", content: .media(mediaID: "med_camera"), start: .zero, duration: t(seconds), video: camera)]
        project.videoTracks[2].clips = broll
        project.videoTracks[4].clips = captions
        let words = (Self.kept + " " + Self.more).split(separator: " ").enumerated().map { index, text in
            QualityCheck.Speech.Word(text: String(text), start: t(Double(index) * 0.5), end: t(Double(index) * 0.5 + 0.4))
        }
        return (project, QualityCheck.Speech(words: words, clipIDs: ["clip_voice"]))
    }

    private func broll(_ setup: (Project, QualityCheck.Speech)) -> [CheckProblem] {
        QualityCheck.littleBRoll(in: setup.0, ranges: [TimeRange(start: .zero, end: setup.0.duration)], speech: setup.1)
    }

    private func still(_ id: String, at start: Double, for seconds: Double) -> Clip {
        Clip(id: id, content: .media(mediaID: "med_still"), start: t(start), duration: t(seconds))
    }

    func testATalkingHeadWithNoBRollIsNoted() {
        let found = broll(talking())
        XCTAssertEqual(found.map(\.kind), [.littleBRoll])
        let message = found.first?.message ?? ""
        XCTAssertTrue(message.hasPrefix("No B-roll"), message)
        XCTAssertTrue(message.contains("\"so when i saw"), "quotes what he says where it's bare: \(message)")
        XCTAssertTrue(CheckProblem.Kind.littleBRoll.isNote)
    }

    func testTwoShotsOverAMinuteIsLittle() {
        // The first hand-back: two shots on the opener, the rest bare.
        let found = broll(talking(broll: [still("clip_a", at: 4, for: 3), still("clip_b", at: 10, for: 4)]))
        XCTAssertEqual(found.map(\.kind), [.littleBRoll])
        XCTAssertTrue(found.first?.message.hasPrefix("Little B-roll: 12% of the 60.0 s") ?? false, found.first?.message ?? "")
    }

    func testCoverLikeMikesEditsIsQuiet() {
        let shots = stride(from: 2.0, to: 58, by: 8).enumerated().map { still("clip_\($0.offset)", at: $0.element, for: 4) }
        XCTAssertEqual(broll(talking(broll: shots)), [])
    }

    func testCaptionsDontCountAndADemoIsntJudged() {
        let caption = Clip(id: "clip_caption", content: .text(TextContent(text: "so when i saw", words: [])), start: .zero, duration: t(60))
        XCTAssertEqual(broll(talking(captions: [caption])).first?.message.hasPrefix("No B-roll") ?? false, true)
        // The screen recording with Mike in the corner shows the demo.
        let pip = VideoProperties(transform: Transform(position: Point(x: 0.87, y: 0.77), scale: 0.5))
        XCTAssertEqual(broll(talking(camera: pip)), [])
    }
}
