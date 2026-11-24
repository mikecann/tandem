import AVFoundation
import CoreImage
import XCTest
@testable import TandemRender

final class PrivacyPixelEvidenceTests: XCTestCase {
    let canvas = CGSize(width: 100, height: 100)

    func layer(_ image: CIImage) -> FramePrivacyEvidence.Layer {
        .init(image: image, canvas: canvas, coordinatesKnown: true)
    }

    func testRegionsUseTheRenderedTopLeftCoordinates() {
        let top = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        XCTAssertEqual(layer(top).opacity(in: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.3)), .opaque)
        XCTAssertEqual(layer(top).opacity(in: CGRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3)), .transparent)
        XCTAssertEqual(layer(top).opacity(in: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.2)), .mixed)
    }

    func testOpacityChecksEveryPixelRatherThanTheCentreOrCorners() {
        let left = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 100))
        let right = CIImage(color: .white).cropped(to: CGRect(x: 31, y: 0, width: 69, height: 100))
        let image = left.composited(over: right)
        XCTAssertEqual(layer(image).opacity(in: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)), .mixed)
    }

    func testAlmostOpaquePixelsCannotRoundIntoAnOpaqueProof() {
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.999999)).cropped(to: CGRect(origin: .zero, size: canvas))
        XCTAssertEqual(layer(image).opacity(in: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)), .mixed)
        XCTAssertEqual(layer(image).opacity(in: CGRect(x: -0.01, y: 0.1, width: 0.8, height: 0.8)), .unknown)
    }

    func testBufferEvidenceKeepsEachLayersOwnOpacityAndCoordinateTrust() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 50, 50, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let evidence = FramePrivacyEvidence()
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        evidence.visible("top", opaqueVideo: false, layer: layer(image))
        evidence.visible("unknown", opaqueVideo: false, layer: .init(image: image, canvas: canvas, coordinatesKnown: false))
        evidence.attach(to: buffer)
        let sources = try XCTUnwrap(FramePrivacyEvidence.read(buffer))
        let boxes = [CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.2), CGRect(x: 0.2, y: 0.7, width: 0.5, height: 0.2)]
        let regions = sources.regions(boxes)
        XCTAssertEqual(regions[0].clips["top"]?.opacity, .opaque)
        XCTAssertEqual(regions[1].clips["top"]?.opacity, .transparent)
        XCTAssertEqual(regions[0].clips["unknown"]?.coordinatesKnown, false)
        FramePrivacyEvidence.clear(buffer)
        XCTAssertNil(FramePrivacyEvidence.read(buffer), "a reused output buffer must never inherit prior-frame inputs")
    }
}
