import CoreVideo
import Foundation
import VideoToolbox

/// HDR video (an iPhone's HLG, PQ) brought down to SDR BT.709 for the
/// compositor, the same way in every path.
///
/// Left to AVFoundation, each path converted it its own way: an
/// AVAssetReader (exports, `tandem check`) decodes it straight to BT.709,
/// while the player and frame grabs got a brighter conversion, so a paused
/// frame or `tandem frame` didn't look like the export (a warm grey came
/// out 154/116/78 in a still and 135/83/52 exported, 20 Nov 2026). So the
/// compositor takes HDR frames as they are (`supportsHDRSourceFrames`) and
/// converts them here with VideoToolbox, which lands within a level of
/// what exports have always shown.
final class HDRFrames: @unchecked Sendable {
    static let shared = HDRFrames()

    private let lock = NSLock()
    /// Sessions aren't for sharing between threads; the compositor renders
    /// several frames at once, so each takes one of its own for a frame.
    private var idle: [VTPixelTransferSession] = []
    private var pools: [String: CVPixelBufferPool] = [:]

    static let hdrTransfers: Set<String> = [
        kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
        kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    ]

    /// Whether a frame is tagged HLG or PQ.
    static func isHDR(_ buffer: CVPixelBuffer) -> Bool {
        guard let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String else { return false }
        return hdrTransfers.contains(transfer)
    }

    /// The frame in SDR BT.709 (8-bit 4:2:0 video range, as decoders hand
    /// the compositor SDR video), or the frame itself when it isn't HDR.
    /// Frames with alpha stay as they are: the conversion would drop it.
    func sdr(_ buffer: CVPixelBuffer) -> CVPixelBuffer {
        guard Self.isHDR(buffer), CVPixelBufferIsPlanar(buffer) else { return buffer }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard let session = take(), let pool = pool(width: width, height: height) else { return buffer }
        defer { give(session) }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made,
              VTPixelTransferSessionTransferImage(session, from: buffer, to: out) == noErr else { return buffer }
        return out
    }

    private func take() -> VTPixelTransferSession? {
        if let session = lock.withLock({ idle.popLast() }) { return session }
        var made: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &made) == noErr, let session = made else { return nil }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationTransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        return session
    }

    private func give(_ session: VTPixelTransferSession) {
        lock.withLock { if idle.count < 8 { idle.append(session) } }
    }

    private func pool(width: Int, height: Int) -> CVPixelBufferPool? {
        let key = "\(width)x\(height)"
        return lock.withLock {
            if let pool = pools[key] { return pool }
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            if pools.count > 8 { pools.removeAll() }
            pools[key] = made
            return made
        }
    }
}
