import CoreImage
import CoreVideo
import XCTest
@testable import TandemRender

/// HDR frames come down to SDR BT.709 the way exports have always shown
/// them, whatever their format.
final class HDRFramesTests: XCTestCase {
    /// An HDR overlay with alpha (HEVC with alpha, ProRes 4444 tagged HLG)
    /// arrives as BGRA: it's converted too, and keeps its alpha.
    func testAnHDRFrameWithAlphaKeepsItAndIsConverted() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()] as CFDictionary, &made)
        let frame = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(frame)
        // The warm grey of the HLG tests, as its HLG signal, opaque on the
        // left and clear on the right.
        for y in 0..<64 { for x in 0..<64 {
            let o = y * row + x * 4
            if x < 32 { base[o] = 77; base[o + 1] = 115; base[o + 2] = 153; base[o + 3] = 255 } else { base[o] = 0; base[o + 1] = 0; base[o + 2] = 0; base[o + 3] = 0 }
        } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        XCTAssertTrue(HDRFrames.isHDR(frame))

        let sdr = HDRFrames.shared.sdr(frame)
        XCTAssertFalse(sdr === frame, "converted")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(sdr), kCVPixelFormatType_32BGRA)
        XCTAssertFalse(HDRFrames.isHDR(sdr))
        CVPixelBufferLockBaseAddress(sdr, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(sdr, .readOnly) }
        let out = CVPixelBufferGetBaseAddress(sdr)!.assumingMemoryBound(to: UInt8.self)
        let outRow = CVPixelBufferGetBytesPerRow(sdr)
        let opaque = 32 * outRow + 8 * 4
        let clear = 32 * outRow + 56 * 4
        XCTAssertEqual(Int(out[opaque + 3]), 255)
        XCTAssertEqual(Int(out[clear + 3]), 0, "the clear half stays clear")
        // As exports show that grey from a 4:2:0 HLG take: 135/83/52.
        XCTAssertEqual(Int(out[opaque + 2]), 135, accuracy: 8, "red")
        XCTAssertEqual(Int(out[opaque + 1]), 83, accuracy: 8, "green")
        XCTAssertEqual(Int(out[opaque]), 52, accuracy: 8, "blue")
    }

    func testSDRFramesPassStraightThrough() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let frame = try XCTUnwrap(made)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        XCTAssertTrue(HDRFrames.shared.sdr(frame) === frame)
    }
}
