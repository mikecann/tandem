import XCTest
@testable import TandemCore

/// `tandem check`'s note for a music swell that no longer sits under its
/// section card, laid out like the Threadbear launch video: 3.2 s cards, each
/// at the end of a music bed that swells 14 dB from the card's start.
final class SwellOffCardTests: XCTestCase {
    static let music = MediaItem(id: "med_music", path: "bed.wav", kind: .audio, role: .music, duration: t(600), hasAudio: true)

    private let cardStarts: [Double] = [94, 329, 698, 808]

    /// A bed ending with each card, swelling `late` seconds after the card
    /// starts (by card index), and running `over` seconds past its card.
    private func project(late: [Int: Double] = [:], over: [Int: Double] = [:], bare: Set<Int> = [], cards count: Int = 4) -> Project {
        var project = Project.standard(name: "Swells")
        project.media = [Self.music]
        var cards: [Clip] = []
        var beds: [Clip] = []
        var bedStart = 0.0
        for (index, start) in cardStarts.prefix(count).enumerated() {
            cards.append(Clip(id: "clip_card\(index)", content: SectionCard.content(SectionCard.Props(title: "Part \(index + 1)")), start: t(start), duration: t(3.2)))
            let end = start + 3.2 + (over[index] ?? 0)
            let rise = start - bedStart + (late[index] ?? 0)
            let keys = bare.contains(index) ? [] : [
                Keyframe(time: .zero, value: .number(-2.5)),
                Keyframe(time: t(rise), value: .number(-2.5)),
                Keyframe(time: t(rise + 0.7), value: .number(11.5)),
                Keyframe(time: t(rise + 2.9), value: .number(11.5))
            ]
            beds.append(Clip(
                id: "clip_bed\(index)", content: .media(mediaID: "med_music"), start: t(bedStart), duration: t(end - bedStart),
                keyframes: keys.isEmpty ? [:] : ["audio.gainDB": keys]
            ))
            bedStart = end
        }
        project.videoTracks[3].clips = cards
        project.audioTracks[1].clips = beds
        return project
    }

    private func notes(_ p: Project) -> [CheckProblem] {
        QualityCheck.swellsOffCards(in: p, ranges: [TimeRange(start: .zero, end: t(900))])
    }

    func testSwellsUnderTheirCardsAreFine() {
        XCTAssertEqual(notes(project()), [])
    }

    func testASwellACutLeftLateIsNoted() {
        // Mike's Delete 3 clips + Close gap left card 2's swell 0.44 s late.
        let found = notes(project(late: [1: 0.44]))
        XCTAssertEqual(found.map(\.kind), [.swellOffCard])
        XCTAssertEqual(found.first?.clipIDs, ["clip_bed1", "clip_card1"])
        XCTAssertTrue(found.first?.message.contains("0.44 s later") ?? false, found.first?.message ?? "")
        XCTAssertTrue(CheckProblem.Kind.swellOffCard.isNote, "a swell can be off a card on purpose")
    }

    func testOnlyTheOddSwellOutIsNoted() {
        // With three cards, two agreeing make the usual place.
        let three = notes(project(late: [2: 0.44], cards: 3))
        XCTAssertEqual(three.map(\.clipIDs), [["clip_bed2", "clip_card2"]])
        // With two there's no telling which is off.
        XCTAssertEqual(notes(project(late: [1: 0.44], cards: 2)), [])
    }

    func testASwellRunningPastItsCardIsNoted() {
        let found = notes(project(over: [2: 1.5]))
        XCTAssertEqual(found.map(\.kind), [.swellOffCard])
        XCTAssertTrue(found.first?.message.contains("past the card's end") ?? false, found.first?.message ?? "")
    }

    func testASwellJustBesideABareCardIsNoted() {
        // Card 4's swell landed after it: the bed carries on past the card.
        var p = project(bare: [3])
        let bed = p.audioTracks[1].clips[3]
        p.audioTracks[1].clips[3].keyframes["audio.gainDB"] = [
            Keyframe(time: .zero, value: .number(-2.5)),
            Keyframe(time: bed.duration + t(1), value: .number(-2.5)),
            Keyframe(time: bed.duration + t(1.7), value: .number(11.5))
        ]
        p.audioTracks[1].clips[3].duration = bed.duration + t(4)
        let found = notes(p)
        XCTAssertEqual(found.map(\.kind), [.swellOffCard], "\(found.map(\.message))")
        XCTAssertTrue(found.first?.message.contains("nothing swells under the \"Part 4\" card") ?? false, found.first?.message ?? "")
    }
}
