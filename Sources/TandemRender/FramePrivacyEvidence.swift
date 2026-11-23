import AVFoundation
import Foundation
import TandemCore

/// Input evidence for one composed frame. It travels on that output buffer,
/// so parallel readers requesting the same time cannot mix their evidence.
final class FramePrivacyEvidence {
    /// The source-pixel support of tandemLanczos's 6-by-6 reconstruction.
    static let samplingRadius: CGFloat = 3

    static func preservesPixelGrid(_ transform: CGAffineTransform) -> Bool {
        let values = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        guard values.allSatisfy({ $0.isFinite && abs($0 - $0.rounded()) < 1e-9 }) else { return false }
        let a = transform.a.rounded(), b = transform.b.rounded(), c = transform.c.rounded(), d = transform.d.rounded()
        return abs(a) + abs(b) == 1 && abs(c) + abs(d) == 1 && a * c + b * d == 0
    }

    struct Sources {
        var visible: Set<String> = []
        var unproven: Set<String> = []
        var unavailable: Set<String> = []
        var opaqueVideos: Set<String> { visible.subtracting(unproven) }
    }

    private enum Capture {
        case collecting(Sources)
        case complete(Sources)
        case uncertain
    }

    private var capture = Capture.collecting(Sources())
    private static let attachment = "com.mikerosoft.tandem.privacy.sources"

    func missing(_ clipID: String) {
        guard case .collecting(var sources) = capture else { return }
        if !sources.visible.contains(clipID) { sources.unavailable.insert(clipID) }
        capture = .collecting(sources)
    }

    func visible(_ clipID: String, opaqueVideo: Bool) {
        guard case .collecting(var sources) = capture else { return }
        sources.visible.insert(clipID)
        sources.unavailable.remove(clipID)
        if !opaqueVideo { sources.unproven.insert(clipID) }
        capture = .collecting(sources)
    }

    func uncertain() { capture = .uncertain }

    func complete() -> Sources? {
        switch capture {
        case .collecting(let sources): capture = .complete(sources); return sources
        case .complete(let sources): return sources
        case .uncertain: return nil
        }
    }

    static func clear(_ pixels: CVPixelBuffer) {
        CVBufferRemoveAttachment(pixels, attachment as CFString)
    }

    func attach(to pixels: CVPixelBuffer) {
        Self.clear(pixels)
        guard let sources = complete() else { return }
        let values = ["visible": Array(sources.visible), "opaque": Array(sources.opaqueVideos), "unavailable": Array(sources.unavailable)]
        CVBufferSetAttachment(pixels, Self.attachment as CFString, values as CFDictionary, .shouldPropagate)
    }

    static func read(_ pixels: CVPixelBuffer) -> Sources? {
        guard let value = CVBufferCopyAttachment(pixels, attachment as CFString, nil),
              let values = value as? [String: [String]], let visible = values["visible"],
              let opaque = values["opaque"], let unavailable = values["unavailable"] else { return nil }
        return Sources(visible: Set(visible), unproven: Set(visible).subtracting(opaque), unavailable: Set(unavailable))
    }

    /// Only recognized opaque loaded formats establish opacity. Alpha-capable
    /// and unknown formats stay uncertain, regardless of project metadata.
    static func provesOpaque(_ formats: [CMFormatDescription]) -> Bool {
        let opaque: Set<FourCharCode> = [
            kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, FourCharCode(0x6865_7631),
            kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ,
            kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy
        ]
        return !formats.isEmpty && formats.allSatisfy { format in
            let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
            return extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool != true
                && opaque.contains(CMFormatDescriptionGetMediaSubType(format))
        }
    }
}
