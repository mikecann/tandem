import XCTest
@testable import TandemCore

/// `tandem check`'s notes on the outro: the "Comment below" and "Like and
/// subscribe" segments where he asks, and a wipe into the sign-off. The
/// lines are Convex Auth v2's (12 Nov 2026), whose finished edit has all
/// three.
final class OutroChecksTests: XCTestCase {
    static let camera = MediaItem(id: "med_camera", path: "take-camera.mov", kind: .video, role: .camera, duration: t(900), width: 3840, height: 2160, hasVideo: true, hasAudio: true)
    static let sticker = MediaItem(id: "med_comment", path: "/Library/Segments/Comment below/Comment below.mov", kind: .video, role: .broll, duration: t(2.5), width: 1280, height: 392, hasVideo: true)

    static let talk = "So that's how the new auth works. Sessions are stored in your own tables and the client keeps them fresh. "
    static let comments = "If you've got questions, drop me a comment down below. "
    static let signOff = "But anyways, I think that's all I got for you guys for now. Don't forget to drop me a like and sub. And until next time, thanks for watching. Cheerio."

    /// Mike on camera for 7 minutes in pieces of 30 s (a join every 30 s),
    /// saying `talk` again and again (or `middle` at 100 s), then `ending`
    /// from `endingAt`, half a second a word with a 0.8 s pause after each
    /// sentence.
    private func video(ending: String = OutroChecksTests.comments + OutroChecksTests.signOff, endingAt: Double = 400, middle: String? = nil, portrait: Bool = false, name: String = "Convex Auth v2") -> (Project, QualityCheck.Speech) {
        var project = Project.standard(name: name)
        project.settings.width = portrait ? 1080 : 3840
        project.settings.height = portrait ? 1920 : 2160
        project.media = [Self.camera, Self.sticker]
        project.videoTracks[1].clips = stride(from: 0.0, to: 420, by: 30).map {
            Clip(id: "clip_cam\(Int($0))", content: .media(mediaID: "med_camera"), start: t($0), duration: t(30), sourceStart: t($0))
        }
        var words: [QualityCheck.Speech.Word] = []
        func say(_ text: String, from: Double, until: Double) {
            var time = from
            for word in text.split(separator: " ") where time < until {
                words.append(.init(text: String(word), start: t(time), end: t(time + 0.4)))
                time += word.last.map { ".?!".contains($0) } == true ? 1.2 : 0.5
            }
        }
        var time = 0.0
        while time < endingAt - 20 {
            say(middle != nil && time == 100 ? middle! : Self.talk, from: time, until: endingAt)
            time += 20
        }
        say(ending, from: endingAt, until: 420)
        return (project, QualityCheck.Speech(words: words, clipIDs: ["clip_voice"]))
    }

    private func notes(_ setup: (Project, QualityCheck.Speech), ranges: [TimeRange]? = nil) -> [CheckProblem] {
        let all = ranges ?? [TimeRange(start: .zero, end: setup.0.duration)]
        return QualityCheck.outroStings(in: setup.0, ranges: all, speech: setup.1) + QualityCheck.outroWipe(in: setup.0, ranges: all, speech: setup.1)
    }

    /// The library segment's picture, as `tandem segments insert` puts it in.
    private func segment(_ name: String, at seconds: Double, length: Double = 2.5) -> Clip {
        var clip = Clip(id: "clip_\(name.prefix(4).lowercased())\(Int(seconds))", content: .solid(color: .black), start: t(seconds), duration: t(length))
        clip.tags = ["template:segment:\(name)"]
        return clip
    }

    private func word(_ text: String, in setup: (Project, QualityCheck.Speech)) -> Time {
        setup.1.words.first { $0.text.lowercased().hasPrefix(text) && $0.start > t(390) }?.start ?? .zero
    }

    // MARK: - Stings

    func testAsksWithNoSegmentAreNotedWithTheInsertThatAddsIt() {
        var setup = video()
        setup.0.markers = [Marker(time: t(60), name: "Setup", kind: .section)]
        setup.0.videoTracks[3].clips = [segment("Convex wipe", at: 405, length: 0.93)]
        let found = notes(setup)
        XCTAssertEqual(found.map(\.kind), [.outroSting, .outroSting])
        let comment = found[0].message
        XCTAssertTrue(comment.hasPrefix("No \"Comment below\" segment where he says \"comment down below\""), comment)
        let asked = word("comment", in: setup)
        XCTAssertEqual(found[0].start, asked)
        XCTAssertTrue(comment.hasSuffix("tandem segments insert \"Comment below\" --at \(asked - t(0.3))"), comment)
        XCTAssertTrue(found[1].message.contains("\"Like and subscribe\" segment where he says \"like and sub\""), found[1].message)
        XCTAssertTrue(CheckProblem.Kind.outroSting.isNote)
    }

    func testSegmentsNearTheAsksAreEnough() {
        var setup = video()
        setup.0.markers = [Marker(time: t(60), name: "Setup", kind: .section)]
        let comment = word("comment", in: setup), like = word("like", in: setup)
        setup.0.videoTracks[3].clips = [segment("Convex wipe", at: 405, length: 0.93), segment("Comment below", at: comment.seconds - 0.2)]
        // Placed by hand rather than from the library: its file says what it is.
        setup.0.videoTracks[2].clips = [Clip(id: "clip_like", content: .media(mediaID: "med_comment"), start: like + t(1), duration: t(2.5))]
        setup.0.media[1].path = "/Library/Segments/Like and subscribe/Like and subscribe button.mov"
        XCTAssertEqual(notes(setup), [])
    }

    func testSubscribeOnlyCountsNearTheEnd() {
        // Bark heard "like and sub" in the middle of the Auth v2 demo, and a
        // Convex client subscribes to queries; neither is the ask.
        let middle = "So here's a little notes app, like and sub and you can see it shows up. "
        let late = Self.talk + "The client will subscribe to the query and stays in sync. Cheerio."
        let setup = video(ending: late, endingAt: 400, middle: middle)
        XCTAssertTrue(setup.1.words.contains { $0.text == "sub" && $0.start < t(200) })
        XCTAssertEqual(QualityCheck.outroStings(in: setup.0, ranges: [TimeRange(start: .zero, end: setup.0.duration)], speech: setup.1), [])
        // "Make sure you subscribe." at the end is.
        let asked = video(ending: Self.talk + "Make sure you subscribe. Cheerio.", endingAt: 380)
        XCTAssertEqual(QualityCheck.outroStings(in: asked.0, ranges: [TimeRange(start: .zero, end: asked.0.duration)], speech: asked.1).map(\.kind), [.outroSting])
    }

    // MARK: - Wipe

    func testASignOffWithNoWipeIsNotedWithTheWipeAtItsCut() {
        var setup = video(ending: Self.signOff, endingAt: 400.6)
        setup.0.markers = [Marker(time: t(60), name: "Setup", kind: .section)]
        let stings = [segment("Like and subscribe", at: word("like", in: setup).seconds - 0.5, length: 3.47)]
        setup.0.videoTracks[3].clips = stings
        let found = notes(setup)
        XCTAssertEqual(found.map(\.kind), [.outroWipe])
        let message = found.first?.message ?? ""
        // "But anyways, I think..." starts at 400.6, 10 s into the take's
        // last piece, which starts at 390.
        XCTAssertEqual(found.first?.start, t(390), "the last join in the take before the sign-off sentence")
        XCTAssertTrue(message.contains("the sign-off (\"But anyways, I think that's all I got...\")"), message)
        XCTAssertTrue(message.contains("tandem segments insert \"Convex wipe\" --at \(t(390) - t(0.47))"), message)
        XCTAssertTrue(CheckProblem.Kind.outroWipe.isNote)

        // A Convex wipe, a section card or a wipe transition in the minute
        // before it is the wipe.
        var wiped = setup
        wiped.0.videoTracks[3].clips = stings + [segment("Convex wipe", at: 389.5, length: 0.93)]
        XCTAssertEqual(notes(wiped), [])
        var carded = setup
        carded.0.videoTracks[3].clips = stings + [Clip(id: "clip_card", content: .graphic(GraphicContent(template: SectionCard.template)), start: t(360), duration: t(3))]
        XCTAssertEqual(notes(carded), [])
        var transitioned = setup
        transitioned.0.videoTracks[1].transitions = [Transition(id: "tr_wipe", type: .wipe, duration: t(0.5), fromClipID: "clip_cam360", toClipID: "clip_cam390")]
        XCTAssertEqual(notes(transitioned), [])
    }

    func testOnlyAnEditWithSectionsWantsOne() {
        // Convex 1.50, three minutes in one piece, signs off with no wipe.
        var setup = video(ending: Self.signOff, endingAt: 400.6)
        setup.0.videoTracks[3].clips = [segment("Like and subscribe", at: word("like", in: setup).seconds - 0.5, length: 3.47)]
        XCTAssertEqual(notes(setup), [])
        // A wipe much earlier says it has sections.
        setup.0.videoTracks[3].clips.append(segment("Convex wipe", at: 120, length: 0.93))
        XCTAssertEqual(notes(setup).map(\.kind), [.outroWipe])
        // Outside the stretches checked, it isn't judged.
        XCTAssertEqual(notes(setup, ranges: [TimeRange(start: .zero, end: t(300))]), [])
    }

    func testNotInAShortOrAConversation() {
        var short = video(portrait: true)
        short.0.markers = [Marker(time: t(60), name: "Setup", kind: .section)]
        XCTAssertEqual(notes(short), [])
        var talk = video(name: "Databased podcast")
        talk.0.markers = [Marker(time: t(60), name: "Setup", kind: .section)]
        XCTAssertEqual(notes(talk), [])
    }
}
