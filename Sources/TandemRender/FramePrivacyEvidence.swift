import AVFoundation
import CoreImage
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
        var layers: [String: Layer] = [:]
        var opaqueVideos: Set<String> { visible.subtracting(unproven) }

        /// Measure the actual, filtered layer where OCR saw glyphs. Neither
        /// a file's alpha nor integer sampling proves its rendered opacity.
        /// Images stay on the current buffer only; ReadFrame keeps these
        /// small measurements, never decoder buffers or CIImage recipes.
        func regions(_ boxes: [CGRect]) -> [Region] {
            boxes.map { box in
                Region(box: box, clips: layers.mapValues { layer in
                    Measurement(opacity: layer.opacity(in: box), coordinatesKnown: layer.coordinatesKnown)
                })
            }
        }
    }

    enum Opacity: Equatable, Sendable { case opaque, transparent, mixed, unknown }

    struct Measurement: Equatable, Sendable {
        var opacity: Opacity
        var coordinatesKnown: Bool
    }

    struct Region: Equatable, Sendable {
        var box: CGRect
        var clips: [String: Measurement]
    }

    struct Layer {
        var image: CIImage
        var canvas: CGSize
        var coordinatesKnown: Bool

        func opacity(in box: CGRect) -> Opacity {
            guard [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite),
                  box.width > 0, box.height > 0,
                  box.minX >= 0, box.minY >= 0, box.maxX <= 1, box.maxY <= 1 else { return .unknown }
            let rect = CGRect(x: box.minX * canvas.width, y: (1 - box.maxY) * canvas.height,
                              width: box.width * canvas.width, height: box.height * canvas.height).integral
            guard rect.width > 0, rect.height > 0, rect.width * rect.height <= 16_777_216 else { return .unknown }
            // Float output preserves partial alpha and Lanczos overshoot.
            // An 8-bit bitmap could round an almost opaque layer to 255.
            let width = Int(rect.width), height = Int(rect.height)
            var rgba = [Float](repeating: .nan, count: width * height * 4)
            let clear = CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: canvas))
            rgba.withUnsafeMutableBytes { bytes in
                RenderEngine.context.render(image.composited(over: clear), toBitmap: bytes.baseAddress!, rowBytes: width * 16,
                                            bounds: rect, format: .RGBAf, colorSpace: nil)
            }
            guard rgba.allSatisfy(\.isFinite) else { return .unknown }
            if stride(from: 3, to: rgba.count, by: 4).allSatisfy({ rgba[$0] == 1 }) { return .opaque }
            if rgba.allSatisfy({ $0 == 0 }) { return .transparent }
            return .mixed
        }
    }

    private final class Attachment: NSObject {
        let sources: Sources
        init(_ sources: Sources) { self.sources = sources }
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

    func visible(_ clipID: String, opaqueVideo: Bool, layer: Layer) {
        guard case .collecting(var sources) = capture else { return }
        sources.visible.insert(clipID)
        sources.unavailable.remove(clipID)
        if !opaqueVideo { sources.unproven.insert(clipID) }
        sources.layers[clipID] = layer
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
        guard var sources = complete() else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        for (id, var layer) in sources.layers where layer.canvas != size {
            layer.image = layer.image.transformed(by: CGAffineTransform(scaleX: size.width / layer.canvas.width, y: size.height / layer.canvas.height), highQualityDownsample: true)
            layer.canvas = size
            sources.layers[id] = layer
        }
        CVBufferSetAttachment(pixels, Self.attachment as CFString, Attachment(sources), .shouldPropagate)
    }

    static func read(_ pixels: CVPixelBuffer) -> Sources? {
        (CVBufferCopyAttachment(pixels, attachment as CFString, nil) as? Attachment)?.sources
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
