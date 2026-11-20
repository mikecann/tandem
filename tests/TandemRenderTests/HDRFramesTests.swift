import CoreImage
import CoreVideo
import XCTest
@testable import TandemRender

/// HDR frames come down to SDR BT.709 the way exports have always shown
/// them, whatever their format.
final class HDRFramesTests: XCTestCase {
    /// The warm grey of the HLG tests as its HLG signal (blue, green, red),
    /// and as exports show it from a 4:2:0 HLG take.
    let signal: [Double] = [77, 115, 153]
    let exported: [Double] = [52, 83, 135]

    /// A 64x64 HLG BGRA frame: opaque on the left, half transparent in the
    /// middle, clear on the right.
    func frame(straight: Bool, tagsCarryOver: Bool = true) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()] as CFDictionary, &made)
        let frame = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(frame, [])
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<64 { for x in 0..<64 {
            let o = y * row + x * 4
            let alpha: Double = x < 21 ? 255 : x < 42 ? 128 : 0
            for c in 0..<3 { base[o + c] = UInt8((straight || alpha == 255 ? signal[c] : signal[c] * alpha / 255).rounded()) }
            base[o + 3] = UInt8(alpha)
        } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let mode: CVAttachmentMode = tagsCarryOver ? .shouldPropagate : .shouldNotPropagate
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, mode)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, mode)
        if straight {
            CVBufferSetAttachment(frame, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        } else if !tagsCarryOver {
            // Said outright, as ProRes 4444 and HEVC with alpha do.
            CVBufferSetAttachment(frame, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        }
        return frame
    }

    /// An HDR overlay with alpha (HEVC with alpha, ProRes 4444 tagged HLG)
    /// arrives as BGRA: it's converted too, keeps its alpha, and a half
    /// transparent pixel gets the same colour as an opaque one, whether its
    /// colour is premultiplied by its alpha or not.
    func testAnHDRFrameWithAlphaKeepsItAndIsConverted() throws {
        // Twice over, so the second pass gets buffers the first one used.
        for (straight, carry) in [(false, true), (true, true), (false, false), (false, true), (true, true), (false, false)] {
            let what = (straight ? "straight" : "premultiplied") + (carry ? "" : ", tags set not to carry over")
            let sdr = HDRFrames.shared.sdr(try frame(straight: straight, tagsCarryOver: carry))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(sdr), kCVPixelFormatType_32BGRA, what)
            XCTAssertFalse(HDRFrames.isHDR(sdr), what)
            let mode = CVBufferCopyAttachment(sdr, kCVImageBufferAlphaChannelModeKey, nil) as? String
            XCTAssertEqual(mode, (straight ? kCVImageBufferAlphaChannelMode_StraightAlpha : kCVImageBufferAlphaChannelMode_PremultipliedAlpha) as String, what)
            CVPixelBufferLockBaseAddress(sdr, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(sdr, .readOnly) }
            let out = CVPixelBufferGetBaseAddress(sdr)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(sdr)
            for (x, alpha) in [(8, 255.0), (32, 128.0), (56, 0.0)] {
                let o = 32 * row + x * 4
                XCTAssertEqual(Double(out[o + 3]), alpha, accuracy: 1, "\(what) alpha at \(x)")
                guard alpha > 0 else { continue }
                for c in 0..<3 {
                    // Back to full opacity to compare.
                    let shown = straight ? Double(out[o + c]) : Double(out[o + c]) * 255 / alpha
                    XCTAssertEqual(shown, exported[c], accuracy: 8, "\(what) channel \(c) at \(x)")
                }
            }
        }
    }

    func testSDRFramesPassStraightThrough() throws {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &made)
        let frame = try XCTUnwrap(made)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        XCTAssertTrue(HDRFrames.shared.sdr(frame) === frame)
    }
}
