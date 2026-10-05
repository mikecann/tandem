import XCTest
@testable import TandemApp
import TandemCore

/// The sidebar's list of what's near the playhead.
final class NearThePlayheadTests: XCTestCase {
    private func project() -> Project {
        var project = Project(name: "Near")
        project.markers = [
            Marker(id: "mk_intro", time: t(0), name: "Intro", kind: .section),
            Marker(id: "mk_title", time: t(2), name: "Title: the question word by word", kind: .todo, note: "Big type, fast camera moves"),
            Marker(id: "mk_umm", time: t(10), name: "Cut the umm", kind: .comment),
            Marker(id: "mk_demo", time: t(20), duration: t(8), name: "Demo", kind: .marker),
            Marker(id: "mk_late", time: t(40), name: "Louder", kind: .comment),
            Marker(id: "mk_end", time: t(60), name: "Outro", kind: .section),
            Marker(id: "mk_after", time: t(70), name: "After", kind: .marker)
        ]
        return project
    }

    func testTwoBeforeAndFourAfterWithTheOneItsOn() {
        let near = NearThePlayhead.at(t(10.5), in: project(), review: .empty)
        XCTAssertEqual(near.items.map(\.id), ["mk_title", "mk_umm", "mk_demo", "mk_late", "mk_end", "mk_after"])
        XCTAssertEqual(near.items.filter(\.isHere).map(\.id), ["mk_umm"], "just past a comment, it's here")
        XCTAssertEqual(near.items.first { $0.id == "mk_title" }?.strip, .todos)
        XCTAssertEqual(near.items.first { $0.id == "mk_umm" }?.strip, .comments)
        XCTAssertEqual(near.items.first { $0.id == "mk_intro" }, nil, "only two before")
    }

    func testAStretchIsHereThroughoutAndAPointOnlyBriefly() {
        XCTAssertEqual(NearThePlayhead.at(t(25), in: project(), review: .empty).items.filter(\.isHere).map(\.id), ["mk_demo"])
        XCTAssertTrue(NearThePlayhead.at(t(12), in: project(), review: .empty).items.allSatisfy { !$0.isHere }, "moved on from the comment")
    }

    func testItOnlyChangesWhenThePlayheadPassesSomething() {
        let a = NearThePlayhead.at(t(13), in: project(), review: .empty)
        let b = NearThePlayhead.at(t(17), in: project(), review: .empty)
        XCTAssertEqual(a, b, "nothing passed between 13 s and 17 s, so no redraw")
        XCTAssertNotEqual(b, NearThePlayhead.at(t(21), in: project(), review: .empty))
    }
}
