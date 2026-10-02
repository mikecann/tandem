import XCTest
@testable import TandemCore

/// Mike's comments: markers of kind `comment`, added, changed and cleared
/// by `CommentEdits`.
final class CommentTests: XCTestCase {
    private func apply(_ batch: EditBatch, to project: inout Project) throws {
        var context = EditContext()
        for command in batch.commands { try Editing.apply(command, to: &project, context: &context) }
    }

    func testACommentIsTidiedAndNothingIsntAComment() throws {
        let batch = try XCTUnwrap(CommentEdits.add("  cut the umm here \n", at: Time(seconds: 12), id: "mk_c"))
        XCTAssertEqual(batch.label, "Add comment")
        var project = Project(name: "Comments")
        try apply(batch, to: &project)
        XCTAssertEqual(project.comments.map(\.name), ["cut the umm here"])
        XCTAssertEqual(project.comments.first?.kind, .comment)
        XCTAssertEqual(project.comments.first?.time, Time(seconds: 12))
        XCTAssertNil(CommentEdits.add(" \n ", at: .zero), "nothing to say, no comment")
    }

    func testChangingACommentAndEmptyingIt() throws {
        let comment = Marker(id: "mk_c", time: Time(seconds: 3), name: "B-roll here", kind: .comment)
        XCTAssertNil(CommentEdits.edit(comment, to: " B-roll here "), "unchanged")
        XCTAssertEqual(CommentEdits.edit(comment, to: "The servers B-roll")?.label, "Edit comment")
        XCTAssertEqual(CommentEdits.edit(comment, to: "")?.commands, [.removeMarker(markerID: "mk_c")], "emptied, it goes")
    }

    func testOnlyCommentsAreComments() {
        var project = Project(name: "Comments")
        project.markers = [
            Marker(id: "mk_late", time: Time(seconds: 30), name: "later", kind: .comment),
            Marker(id: "mk_section", time: Time(seconds: 10), name: "Section 2", kind: .section),
            Marker(id: "mk_early", time: Time(seconds: 5), name: "sooner", kind: .comment)
        ]
        XCTAssertEqual(project.comments.map(\.id), ["mk_early", "mk_late"], "earliest first")
    }

    func testCommentsMoveWithTheEditsAroundThem() throws {
        var project = Project(name: "Comments")
        project.media = [MediaItem(id: "med_take", path: "take.mov", kind: .video, role: .camera, duration: Time(seconds: 60), hasVideo: true, hasAudio: true)]
        // The take: a cut out of it ripples everything after it, comments too.
        project.videoTracks = [Track(id: "trk_cam", kind: .video, name: "Camera", clips: [
            Clip(id: "clip_take", content: .media(mediaID: "med_take"), start: .zero, duration: Time(seconds: 60))
        ], rippleMode: .cut)]
        project.markers = [Marker(id: "mk_c", time: Time(seconds: 20), name: "too long a pause", kind: .comment)]
        try apply(EditBatch(label: "Cut", commands: [.rippleDeleteRange(range: TimeRange(start: Time(seconds: 5), end: Time(seconds: 8)))]), to: &project)
        XCTAssertEqual(project.comments.first?.time, Time(seconds: 17))
    }

    func testAKindFromANewerTandemReadsAsAPlainMarker() throws {
        let data = try JSONEncoder().encode(Marker(id: "mk_c", time: Time(seconds: 1), name: "note", kind: .comment))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(try JSONDecoder().decode(Marker.self, from: data).kind, .comment)
        let newer = Data(json.replacingOccurrences(of: "\"comment\"", with: "\"pin\"").utf8)
        XCTAssertEqual(try JSONDecoder().decode(Marker.self, from: newer).kind, .marker, "the project still opens")
    }

    func testACommentOnOneLine() {
        XCTAssertEqual(CommentEdits.oneLine("B-roll here\n\n  the servers one "), "B-roll here / the servers one")
    }
}
