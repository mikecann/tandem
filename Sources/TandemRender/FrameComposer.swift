import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import TandemCore
import TandemMedia

/// What the compositor knows about one clip, fixed when the composition is
/// built.
struct SceneClip {
    var clip: Clip
    var trackIndex: Int
    var media: MediaItem?
    /// Still images: the file to draw.
    var imageURL: URL?
    /// Preferred transform of the file on the clip's picture track.
    var pictureTransform: CGAffineTransform = .identity
    /// Preferred transform of the clip's matte file.
    var matteTransform: CGAffineTransform = .identity
    /// The files behind the picture and matte tracks, for decoding a frame
    /// directly when AVFoundation can't (see `FrameRecovery`).
    var picture: SourceTrack?
    var matte: SourceTrack?
    /// Timeline stretches where AVFoundation's frames for this clip are
    /// wrong: the clip starts on leading frames it can't decode, so it
    /// shows a stale frame or nothing until the next keyframe.
    var pictureRecovery: TimeRange?
    var matteRecovery: TimeRange?

    /// Media time shown at a timeline time, following speed and freezes.
    /// The file's time at a timeline time; before the file starts (a
    /// transition into a clip used from its first frame) that's its first
    /// frame, held. A file whose picture lags its sound shows its picture
    /// that much later (`MediaItem.pictureDelay`), as the plan does.
    func mediaTime(at time: Time) -> CMTime {
        let t = clip.freezeFrame ? clip.sourceStart : clip.sourceStart + (time - clip.start).scaled(by: clip.speed)
        return max(t + (media?.pictureDelay ?? .zero), .zero).cmTime
    }
}

/// Video properties the viewer is dragging, standing in for clips' own
/// until the edit is committed. The player reads them on every frame, so a
/// picture-in-picture moves under the pointer instead of only its outline.
/// Looks dragged in the Colour tab's whole take stand in for files' own the
/// same way (`setLook`).
public final class LiveVideoOverrides: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: VideoProperties] = [:]
    /// By media ID: the look shown, and the file's own look it was dragged
    /// from.
    private var looks: [String: (look: [Effect], base: [Effect])] = [:]

    public init() {}

    /// Clips' properties by clip ID. An empty set ends the preview, the
    /// looks' too.
    public func set(_ overrides: [String: VideoProperties]) {
        lock.withLock {
            values = overrides
            if overrides.isEmpty { looks = [:] }
        }
    }

    /// Shows `look` on every clip of `media` while the Colour tab's whole
    /// take is dragged, in place of any other file's preview. It's only
    /// used while the file's look is still the one it was dragged from
    /// (`look(for:)`), and goes with `clearLooks` or the next `set([:])`.
    public func setLook(_ look: [Effect], over media: MediaItem) {
        lock.withLock { looks = [media.id: (look, media.look)] }
    }

    public func clearLooks() {
        lock.withLock { looks = [:] }
    }

    public var isEmpty: Bool { lock.withLock { values.isEmpty && looks.isEmpty } }

    public var hasLooks: Bool { lock.withLock { !looks.isEmpty } }

    public func video(for clipID: String) -> VideoProperties? {
        lock.withLock { values[clipID] }
    }

    /// The look to draw `media` with, or nil for its own. A preview of a
    /// look the file no longer has never wins: once an edit from anywhere
    /// (an agent's `updateMedia`, an undo) changes it, the file's own
    /// shows (issue #60). It's ignored rather than dropped, since a drag
    /// can run ahead of the composition: it's dragged from the project's
    /// latest look while the cut on screen still has the one before.
    public func look(for media: MediaItem) -> [Effect]? {
        lock.withLock {
            guard let entry = looks[media.id], entry.base == media.look else { return nil }
            return entry.look
        }
    }
}

/// The fixed half of rendering: canvas, clips and effect definitions. Each
/// frame supplies the time, the stack and the decoded source frames.
final class RenderScene: @unchecked Sendable {
    let canvas: CGSize
    let frameDuration: Time
    let format: String?
    let clips: [String: SceneClip]
    let registry: EffectRegistry
    let folder: ProjectFolder
    /// Decodes frames AVFoundation couldn't; nil turns that off.
    let recovery: FrameRecovery?
    /// Properties being dragged in the viewer, used over the clips' own.
    let overrides: LiveVideoOverrides?

    init(canvas: CGSize, frameDuration: Time, format: String?, clips: [String: SceneClip], registry: EffectRegistry, folder: ProjectFolder, recovery: FrameRecovery? = nil, overrides: LiveVideoOverrides? = nil) {
        self.canvas = canvas
        self.frameDuration = frameDuration
        self.format = format
        self.clips = clips
        self.registry = registry
        self.folder = folder
        self.recovery = recovery
        self.overrides = overrides
    }

    var pixelScale: CGFloat { LayerMath.pixelScale(canvas: canvas) }
}

/// Decoded frames by composition track (video pool index).
protocol FrameSources {
    func frame(track: Int) -> CIImage?
}

/// Builds one output frame as a Core Image recipe. The compositor renders
/// it; tests render it straight to a bitmap.
///
/// Per layer, in order: source frame (the right way up), the media's look,
/// the clip's colour and utility effects, crop, cutout, rounded corners,
/// border, transform, drop shadow, opacity. Keyframes are evaluated at the
/// frame's clip-relative time.
struct FrameComposer {
    let scene: RenderScene
    /// Single frames (grabs) rather than a stream: every one is a seek, so
    /// any leading frame AVFoundation can't reach is decoded directly.
    var stills = false

    func compose(_ stack: [StackNode], at time: Time, sources: FrameSources) -> CIImage {
        let rect = CGRect(origin: .zero, size: scene.canvas)
        var result = CIImage(color: .black).cropped(to: rect)
        for node in stack {
            if let image = render(node, below: result, at: time, sources: sources) {
                result = image.composited(over: result)
            }
        }
        return result.cropped(to: rect)
    }

    /// One track's contribution, to composite over `below`.
    func render(_ node: StackNode, below: CIImage, at time: Time, sources: FrameSources) -> CIImage? {
        switch node {
        case .layer(let ref):
            return layer(ref, below: below, at: time, sources: sources)
        case .transition(let ref, let from, let to):
            let a = from.flatMap { render($0, below: below, at: time, sources: sources) }
            let b = to.flatMap { render($0, below: below, at: time, sources: sources) }
            if a == nil && b == nil { return nil }
            return TransitionRenderer.render(ref, from: a, to: b, at: time, canvas: scene.canvas, frameDuration: scene.frameDuration)
        }
    }

    func layer(_ ref: LayerRef, below: CIImage, at time: Time, sources: FrameSources) -> CIImage? {
        guard let sceneClip = scene.clips[ref.clipID] else { return nil }
        let clip = sceneClip.clip
        let clipTime = time - clip.start
        guard var video = clip.resolvedVideo(at: clipTime, format: scene.format) else { return nil }
        if let live = scene.overrides?.video(for: ref.clipID) { video = live }
        let canvas = scene.canvas
        let rect = CGRect(origin: .zero, size: canvas)

        // An adjustment layer applies its effects to everything below it,
        // mixed in by its opacity.
        if case .adjustment = clip.content {
            let env = EffectEnvironment(registry: scene.registry, folder: scene.folder, pixelsPerUnit: scene.pixelScale)
            return EffectRenderer.apply(video.effects, to: below, env).cropped(to: rect).tandemOpacity(video.opacity)
        }

        var fitToCanvas = true
        var opacity = video.opacity
        var image: CIImage
        switch clip.content {
        case .media:
            if let track = ref.pictureTrack {
                guard let frame = frame(track, sceneClip.picture, sceneClip.pictureRecovery, sceneClip, at: time, sources: sources) else { return nil }
                image = Self.oriented(frame, sceneClip.pictureTransform)
            } else if let url = sceneClip.imageURL, let still = ImageCache.shared.image(at: url) {
                image = still
            } else {
                return nil
            }
        case .solid(let color):
            image = CIImage(color: CIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)).cropped(to: rect)
        case .text(let content):
            let text = ResolvedText(content)
            if clip.video == nil, let position = text.position { video.transform.position = position }
            let state = TextAnimationState.at(clipTime, clipDuration: clip.duration, text: text)
            // Draw at the clip's own scale so a big title stays sharp;
            // animation scales from there.
            let staticScale = clip.video?.transform.scale ?? 1
            let renderScale = min(max(1, staticScale), 4)
            guard let drawn = textImage(text, clipTime: clipTime, state: state, renderScale: renderScale, staticScale: staticScale) else { return nil }
            image = drawn
            fitToCanvas = false
            video.transform.scale = video.transform.scale * state.scale / renderScale
            video.transform.position.y += state.offsetY
            opacity *= state.opacity
        case .graphic(let graphic):
            // Drawn at the canvas size, so it fits at scale 1 and the clip's
            // own placement, effects and opacity apply as to any picture.
            guard let drawn = BuiltInGraphics.image(graphic, clipTime: clipTime, clipDuration: clip.duration, canvas: canvas) else { return nil }
            image = drawn
        case .adjustment:
            return nil
        }
        guard opacity > 0 else { return nil }

        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let total = LayerMath.totalScale(source: size, canvas: canvas, transform: video.transform, fitToCanvas: fitToCanvas)
        guard total > 1e-4 else { return nil }
        // Source pixels per px@1080 unit, so sizes look the same on screen
        // whatever the layer's scale.
        let unit = scene.pixelScale / total
        let env = EffectEnvironment(registry: scene.registry, folder: scene.folder, pixelsPerUnit: unit)
        let look = sceneClip.media.flatMap { scene.overrides?.look(for: $0) } ?? sceneClip.media?.look ?? []
        image = EffectRenderer.apply(look + video.effects, to: image, env)

        if !video.crop.isIdentity {
            let visible = LayerMath.coreImageRect(LayerMath.cropRect(source: size, crop: video.crop), height: size.height)
            guard !visible.isEmpty else { return nil }
            image = image.cropped(to: visible)
        }

        var cutOut = false
        if let cutout = video.cutout, cutout.enabled, let track = ref.matteTrack,
           let matte = frame(track, sceneClip.matte, sceneClip.matteRecovery, sceneClip, at: time, sources: sources) {
            image = Self.cutout(image, matte: Self.oriented(matte, sceneClip.matteTransform), settings: cutout, displaySize: size, unit: unit, layerScale: total)
            cutOut = true
        }

        var cornerRadius: CGFloat = 0
        if let rounded = EffectRenderer.style("roundedCorners", in: video.effects, scene.registry) {
            cornerRadius = CGFloat(rounded["radius"]?.number ?? 0) * unit
            image = EffectRenderer.roundedCorners(image, radius: cornerRadius)
        }
        if let border = EffectRenderer.style("border", in: video.effects, scene.registry) {
            var colour = RGBA.white
            if case .color(let c)? = border["color"] { colour = c }
            image = EffectRenderer.border(image, width: CGFloat(border["width"]?.number ?? 0) * unit, color: colour, cornerRadius: cornerRadius, followsAlpha: cutOut)
        }

        let placement = LayerMath.placement(source: size, canvas: canvas, transform: video.transform, fitToCanvas: fitToCanvas)
        let transform = LayerMath.coreImage(placement, sourceHeight: size.height, canvasHeight: canvas.height)
        if !transform.isIdentity {
            // Scaling up (a 3200 px screen recording on a 4K canvas, and
            // more so zoomed in), Lanczos keeps small text crisp where
            // Core Image's bilinear filter goes soft.
            image = total > 1.001
                ? image.tandemLanczos(transform)
                : image.transformed(by: transform, highQualityDownsample: total < 0.75)
        }

        if let shadow = EffectRenderer.style("dropShadow", in: video.effects, scene.registry) {
            var colour = RGBA.black
            if case .color(let c)? = shadow["color"] { colour = c }
            let px = scene.pixelScale
            image = EffectRenderer.dropShadow(
                image,
                distance: CGFloat(shadow["distance"]?.number ?? 0) * px,
                angle: shadow["angle"]?.number ?? 135,
                blur: CGFloat(shadow["blur"]?.number ?? 0) * px,
                opacity: (shadow["opacity"]?.number ?? 0) / 100,
                color: colour
            )
        }
        return image.cropped(to: rect).tandemOpacity(opacity)
    }

    // MARK: - Pieces

    /// A layer's source frame. AVFoundation's, unless it's known to be wrong
    /// there (then decoded directly), or missing: a layer in the stack
    /// always has a frame to show, so an empty source means a decode failed
    /// (open-GOP leading frames), not a gap.
    func frame(_ track: Int, _ source: SourceTrack?, _ bad: TimeRange?, _ clip: SceneClip, at time: Time, sources: FrameSources) -> CIImage? {
        var direct = bad?.contains(time) ?? false
        if stills, !direct, let map = source?.leading {
            direct = map.window(containing: Time(cmTime: clip.mediaTime(at: time))) != nil
        }
        if direct, let image = recovered(source, clip, at: time) { return image }
        return sources.frame(track: track) ?? recovered(source, clip, at: time)
    }

    /// The frame at a clip's media time, decoded directly.
    func recovered(_ source: SourceTrack?, _ clip: SceneClip, at time: Time) -> CIImage? {
        guard let source, let recovery = scene.recovery,
              let pixels = recovery.frame(source, at: clip.mediaTime(at: time)) else { return nil }
        return CIImage(cvPixelBuffer: pixels)
    }

    /// A decoded frame turned the right way up, origin at 0, 0.
    static func oriented(_ frame: CIImage, _ preferred: CGAffineTransform) -> CIImage {
        var image = frame
        let origin = image.extent.origin
        if origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }
        guard !preferred.isIdentity else { return image }
        let natural = image.extent.size
        let (orientation, size) = LayerMath.orientation(natural: natural, preferredTransform: preferred)
        image = image.transformed(by: LayerMath.coreImage(orientation, sourceHeight: natural.height, canvasHeight: size.height))
        let o = image.extent.origin
        return image.transformed(by: CGAffineTransform(translationX: -o.x.rounded(), y: -o.y.rounded()))
    }

    /// Multiplies the layer by the person matte. Edge feather, choke and
    /// repair shapes are worked out at the matte's own resolution, which is
    /// usually lower than the camera's and so cheaper.
    static func cutout(_ image: CIImage, matte frame: CIImage, settings: Cutout, displaySize size: CGSize, unit: CGFloat, layerScale: CGFloat = 1) -> CIImage {
        let matteRect = frame.extent
        guard matteRect.width > 0, matteRect.height > 0 else { return image }
        let toMatte = matteRect.width / size.width
        var matte = frame

        for shape in settings.repairMasks {
            let r = CGRect(
                x: shape.rect.x * matteRect.width,
                y: matteRect.height - (shape.rect.y + shape.rect.height) * matteRect.height,
                width: shape.rect.width * matteRect.width,
                height: shape.rect.height * matteRect.height
            )
            var mask = repairShape(shape, rect: r, radius: CGFloat(shape.cornerRadius) * unit * toMatte)
                .composited(over: CIImage(color: .black))
                .cropped(to: matteRect)
            let feather = CGFloat(shape.feather) * unit * toMatte
            if feather > 0.25 {
                mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(feather)).cropped(to: matteRect)
            }
            switch shape.mode {
            case .include:
                matte = mask.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: matte])
            case .exclude:
                matte = mask.applyingFilter("CIColorInvert").applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: matte])
            }
        }

        let unchoked = matte
        let choke = CGFloat(settings.choke) * unit * toMatte
        if abs(choke) >= 0.5 {
            matte = matte.clampedToExtent()
                .applyingFilter(choke > 0 ? "CIMorphologyMinimum" : "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: abs(choke)])
                .cropped(to: matteRect)
        }
        // The edge setting is the soft edge's width, about four blur sigmas.
        // It used to be the sigma itself: the default 2 px blurred the matte
        // out over 8 px at 1080p, which spread alpha back over the wall that
        // `RVMMatte.cleanEdge` had just cut and left a glow round Mike in the
        // corner (a 4 px sigma on the PiP's own pixels at 4K).
        // Where the person's colour comes from: the matte before feathering,
        // and before a negative choke grows it over the wall (review).
        let solid = choke <= -0.5 ? unchoked : matte
        let feather = CGFloat(settings.edgeFeather) * unit * toMatte / 4
        if feather >= 0.25 {
            matte = matte.clampedToExtent().applyingGaussianBlur(sigma: Double(feather)).cropped(to: matteRect)
        }
        let toImage = CGAffineTransform(scaleX: size.width / matteRect.width, y: size.height / matteRect.height)
        if let cut = cutoutEdgeColour(image, matte: matte, solid: solid, feather: feather, choke: choke, matteRect: matteRect, toImage: toImage,
                                       detail: min(1, layerScale / toMatte)) {
            return cut.cropped(to: image.extent)
        }
        matte = matte.transformed(by: toImage)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.clear,
            kCIInputMaskImageKey: matte
        ]).cropped(to: image.extent)
    }

    /// The cut-out layer with its soft edge in the person's own colour.
    ///
    /// Under a soft matte edge the camera's pixels are part background: a
    /// light wall showed as a pale rim round Mike's cap over dark UI, and
    /// the orange sofa cushions as a warm one on his shoulders. So the
    /// colour where the matte is solid (`Kernels.cutoutCore`) is flooded
    /// outward and used wherever the matte is soft, fading back to the
    /// picture's own colour as alpha rises from `Kernels.cutoutKeepFrom`.
    /// Measured on the Threadbear launch take: the rim's extra light fell
    /// from 3.4 to about 0.9 (0 to 255, mean over the soft edge).
    ///
    /// The flood moves a pixel a step, never round a corner, through the
    /// matte as made (`solid`, before feathering or a negative choke), so it
    /// can't cross a clear gap to a finger or a prop that isn't the same
    /// colour: blurs did, even in small steps, and so did a flood through
    /// the feathered matte or with corner steps (reviews, 5 Nov 2026). Then
    /// it carries on into what the feather or the choke added, as far as
    /// they reach. It's made at the matte's size and scaled up. Nil if a
    /// kernel didn't compile; the caller then cuts out with the picture's
    /// own colours as before.
    static func cutoutEdgeColour(_ image: CIImage, matte: CIImage, solid: CIImage, feather: CGFloat, choke: CGFloat, matteRect: CGRect, toImage: CGAffineTransform, detail: CGFloat = 1) -> CIImage? {
        guard let coreKernel = Kernels.cutoutCoreKernel, let floodKernel = Kernels.cutoutFlood,
              let edgeKernel = Kernels.cutoutEdge else { return nil }
        let (low, high) = Kernels.cutoutCore
        // The flood runs at the size the layer is drawn, up to the matte's
        // own: a 4K export's corner is the matte's size, but the viewer and a
        // 720p review draw it a third as wide, and the flood at full size
        // made a review render three times slower. A gap too small to see
        // at that size closes up, which is fine: it can't be seen.
        let scale = detail < 0.95 ? max(detail, 0.1) : 1
        let toWork = CGAffineTransform(scaleX: scale, y: scale)
        let work = matteRect.applying(toWork).integral
        // Lanczos to shrink: plain sampling would skip pixels, and the edge
        // colour would crawl as he moves.
        func atWork(_ image: CIImage) -> CIImage {
            guard scale != 1 else { return image }
            return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
                .clampedToExtent().cropped(to: work)
        }
        let small = atWork(image.transformed(by: toImage.inverted()))
        let workMatte = atWork(matte), workSolid = atWork(solid)
        guard var flood = coreKernel.apply(extent: work, arguments: [small, workSolid, low, high]) else { return nil }
        // Through the matte as made: 16 matte pixels (about 11 on the
        // diagonal) is past RVM's soft edge, a few of its own pixels at any
        // matte size, and the soft hand of a fast gesture. Then into what
        // feathering (about two sigmas) and a negative choke added. Clamped:
        // the API takes any number, and a negative count would trap.
        let added = Int(min(64, max(0, (2 * feather * scale).rounded(.up) + max(0, -choke * scale).rounded(.up))))
        let plus = CIVector(values: [0, 0.2, 0, 0.2, 0.2, 0.2, 0, 0.2, 0], count: 9)
        for phase in [(steps: 16, added: Float(0)), (steps: added, added: Float(1))] {
            for _ in 0..<phase.steps {
                let around = flood.applyingFilter("CIConvolution3X3", parameters: ["inputWeights": plus, "inputBias": 0]).cropped(to: work)
                guard let next = floodKernel.apply(extent: work, arguments: [flood, around, workMatte, workSolid, phase.added]) else { return nil }
                flood = next
            }
        }
        let floodUp = flood.clampedToExtent().transformed(by: toWork.inverted().concatenating(toImage)).cropped(to: image.extent)
        return edgeKernel.apply(extent: image.extent, arguments: [
            image, floodUp, matte.transformed(by: toImage), solid.transformed(by: toImage),
            low, high, Kernels.cutoutKeepFrom
        ])
    }

    static func repairShape(_ shape: Mask, rect: CGRect, radius: CGFloat) -> CIImage {
        switch shape.shape {
        case .rectangle:
            return CIImage(color: .white).cropped(to: rect)
        case .roundedRectangle:
            return EffectRenderer.roundedRect(rect, radius: min(radius, min(rect.width, rect.height) / 2), color: .white)
                ?? CIImage(color: .white).cropped(to: rect)
        case .ellipse:
            let r = max(rect.height / 2, 1)
            let circle = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": max(r - 1, 0),
                "inputRadius1": r,
                "inputColor0": CIColor.white,
                "inputColor1": CIColor.clear
            ])?.outputImage ?? CIImage(color: .white)
            return circle
                .transformed(by: CGAffineTransform(scaleX: rect.width / (2 * r), y: 1))
                .transformed(by: CGAffineTransform(translationX: rect.midX, y: rect.midY))
                .cropped(to: rect)
        }
    }

    func textImage(_ text: ResolvedText, clipTime: Time, state: TextAnimationState, renderScale: Double, staticScale: Double) -> CIImage? {
        let px = Double(scene.pixelScale) * renderScale
        let style = text.style
        var visible: Int?
        if state.visibleFraction < 1 {
            let count = Int((Double(text.text.count) * state.visibleFraction).rounded())
            visible = String(text.text.prefix(count)).utf16.count
        }
        let request = TextRenderer.Request(
            text: text.text,
            font: style.font,
            size: style.size * px,
            weight: style.weight,
            color: style.color.components,
            strokeColor: style.strokeColor?.components,
            strokeWidth: style.strokeWidth * px,
            backgroundColor: style.backgroundColor?.components,
            alignment: style.alignment,
            shadow: style.shadow,
            lineSpacing: style.lineSpacing,
            maxWidth: Double(scene.canvas.width) * 0.9 * renderScale / max(staticScale, 0.01),
            highlight: text.currentWord(at: clipTime).flatMap { text.utf16Range(ofWord: $0) },
            highlightColor: text.highlightColor.components,
            visibleLength: visible,
            firstLineScale: text.firstLineScale,
            firstLineColor: text.firstLineColor?.components
        )
        return TextRenderer.shared.image(request)
    }
}

extension RGBA {
    var components: [Double] { [r, g, b, a] }
}

/// Still images, decoded once and turned the right way up.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private final class Box {
        let image: CIImage
        init(_ image: CIImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 64
        return cache
    }()

    func image(at url: URL) -> CIImage? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let raw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        var image = CIImage(cgImage: cg).oriented(CGImagePropertyOrientation(rawValue: raw) ?? .up)
        let origin = image.extent.origin
        image = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        cache.setObject(Box(image), forKey: key)
        return image
    }
}
