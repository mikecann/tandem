import XCTest
@testable import TandemCore

final class StickerAnchorTests: XCTestCase {
    func testStickersLandWhereMikeSignedThemOff() {
        // The ESLint video's two stickers, at the sizes Mike approved there.
        let like = StickerAnchor.bottom.transform(sourceWidth: 1280, sourceHeight: 392, canvasWidth: 1920, canvasHeight: 1080)
        XCTAssertEqual(like.scale, 0.4, accuracy: 0.001, "40% of the frame's width")
        XCTAssertEqual(like.position.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(like.position.y, 0.841, accuracy: 0.001)
        let comment = StickerAnchor.bottom.transform(sourceWidth: 712, sourceHeight: 484, canvasWidth: 1920, canvasHeight: 1080)
        XCTAssertEqual(comment.scale, 0.3, accuracy: 0.001, "30% of the frame's height")
        XCTAssertEqual(comment.position.y, 0.8, accuracy: 0.001)
        let fourK = StickerAnchor.bottom.transform(sourceWidth: 712, sourceHeight: 484, canvasWidth: 3840, canvasHeight: 2160)
        XCTAssertEqual(fourK.scale, comment.scale, accuracy: 0.001, "the same share of a 4K frame")
    }

    func testCornersKeepTheSameGapToEveryEdge() {
        let (w, h) = (712.0, 484.0)
        let (cw, ch) = (1920.0, 1080.0)
        let fit = min(cw / w, ch / h)
        for anchor in [StickerAnchor.bottomRight, .topLeft] {
            let t = anchor.transform(sourceWidth: w, sourceHeight: h, canvasWidth: cw, canvasHeight: ch)
            let halfWidth = w * fit * t.scale / 2
            let halfHeight = h * fit * t.scale / 2
            let x = t.position.x * cw
            let y = t.position.y * ch
            let gaps = anchor == .bottomRight ? (cw - x - halfWidth, ch - y - halfHeight) : (x - halfWidth, y - halfHeight)
            XCTAssertEqual(gaps.0, 54, accuracy: 0.01, "\(anchor): 5% of the height from the side")
            XCTAssertEqual(gaps.1, 54, accuracy: 0.01, "\(anchor): and from the top or bottom")
        }
    }

    func testSmallStickersStaySharp() {
        let emoji = StickerAnchor.bottom.transform(sourceWidth: 64, sourceHeight: 64, canvasWidth: 1920, canvasHeight: 1080)
        let fit = 1080.0 / 64
        XCTAssertEqual(64 * fit * emoji.scale, 128, accuracy: 0.01, "twice its own pixels at most")
    }

    func testPopGoesInAndOut() {
        let keys = StickerAnchor.pop(scale: 0.4, duration: t(3))
        XCTAssertEqual(keys.map(\.time.seconds), [0, 0.15, 0.25, 2.7, 2.8, 2.95].map { $0 }, accuracy: 0.0001)
        XCTAssertEqual(keys.first?.value.number ?? 0, 0.004, accuracy: 0.0001)
        XCTAssertEqual(keys[1].value.number ?? 0, 0.44, accuracy: 0.0001, "overshoots a little")
        XCTAssertEqual(keys[2].value.number, 0.4)
        XCTAssertTrue(StickerAnchor.pop(scale: 0.4, duration: t(0.5)).isEmpty, "too short to pop both ways")
    }

    func testPlacingAStickerPutsItAtTheBottom() throws {
        let (_, c) = try Fixture.edited()
        let sticker = MediaItem(
            id: "med_like", path: "stickers/like.mov", kind: .video, role: .sticker, duration: t(3), frameRate: .fps30,
            width: 1280, height: 392, hasVideo: true, hasAudio: false, hasAlpha: true
        )
        try c.run("Add", .addMedia(item: sticker))
        try c.run("Place", .placeMedia(mediaIDs: ["med_like"], at: t(5)))
        let clip = try XCTUnwrap(c.project.track(named: "Graphics")?.clips.first)
        let settings = c.project.settings
        let expected = StickerAnchor.bottom.transform(sourceWidth: 1280, sourceHeight: 392, canvasWidth: Double(settings.width), canvasHeight: Double(settings.height))
        XCTAssertEqual(clip.video?.transform, expected)
        XCTAssertNil(clip.keyframes["video.transform.scale"], "no pop unless asked")

        try c.run("Place again", .placeMedia(mediaIDs: ["med_like"], at: t(10), anchor: .topRight, pop: true))
        let second = try XCTUnwrap(c.project.track(named: "Graphics")?.clips.last)
        XCTAssertEqual(second.video?.transform, StickerAnchor.topRight.transform(sourceWidth: 1280, sourceHeight: 392, canvasWidth: Double(settings.width), canvasHeight: Double(settings.height)))
        XCTAssertEqual(second.keyframes["video.transform.scale"]?.count, 6)
        assertValid(c.project)
    }

    func testOtherFilesStillFillTheFrameUnlessAnchored() throws {
        let (f, c) = try Fixture.edited()
        XCTAssertNil(f.clips("B-roll")[0].video, "B-roll fills the frame as before")
        try c.run("Place", .placeMedia(mediaIDs: ["med_broll"], at: t(40), duration: t(2), anchor: .bottomLeft))
        let anchored = try XCTUnwrap(c.project.track(named: "B-roll")?.clips.last)
        XCTAssertEqual(anchored.start, t(40))
        XCTAssertLessThan(anchored.video?.transform.scale ?? 1, 1)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
