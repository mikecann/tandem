import Foundation

/// Where a sticker sits when it's placed (`placeMedia`'s `anchor`).
///
/// Stickers come in all sizes, and fitting one to the frame the way a shot
/// is placed blew the ESLint video's "Comment below" (712 by 484) and "Like
/// and subscribe" (1280 by 392) up over Mike's face. Placed at an anchor, a
/// sticker fits a box at that edge of the frame instead. The box is the
/// size of the ones Mike signed off there.
public enum StickerAnchor: String, Codable, CaseIterable, Sendable {
    case bottom, bottomLeft, bottomRight, top, topLeft, topRight, centre
    /// Bottom left, inside the title-safe area, like a name.
    case lowerThird

    /// The most of the frame a sticker takes: 40% of its width and 30% of
    /// its height.
    public static let box = (width: 0.4, height: 0.3)
    /// The gap to the frame's edge, as a share of its height (the same
    /// number of pixels on every side).
    public static let margin = 0.05
    /// Small stickers grow to at most twice their own pixels, so they stay
    /// sharp.
    public static let maxUpscale = 2.0

    /// The transform that puts a source of this size at the anchor.
    public func transform(sourceWidth: Double, sourceHeight: Double, canvasWidth: Double, canvasHeight: Double) -> Transform {
        guard sourceWidth > 0, sourceHeight > 0, canvasWidth > 0, canvasHeight > 0 else { return Transform() }
        // Scale 1 fits the source inside the frame.
        let fit = min(canvasWidth / sourceWidth, canvasHeight / sourceHeight)
        let scale = min(
            Self.box.width * canvasWidth / (sourceWidth * fit),
            Self.box.height * canvasHeight / (sourceHeight * fit),
            Self.maxUpscale / fit
        )
        // Its size and margins as shares of the frame.
        let width = sourceWidth * fit * scale / canvasWidth
        let height = sourceHeight * fit * scale / canvasHeight
        let marginX = Self.margin * canvasHeight / canvasWidth
        let left = marginX + width / 2
        let right = 1 - marginX - width / 2
        let top = Self.margin + height / 2
        let bottom = 1 - Self.margin - height / 2
        let position: Point
        switch self {
        case .bottom: position = Point(x: 0.5, y: bottom)
        case .bottomLeft: position = Point(x: left, y: bottom)
        case .bottomRight: position = Point(x: right, y: bottom)
        case .top: position = Point(x: 0.5, y: top)
        case .topLeft: position = Point(x: left, y: top)
        case .topRight: position = Point(x: right, y: top)
        case .centre: position = Point(x: 0.5, y: 0.5)
        case .lowerThird: position = Point(x: 0.1 + width / 2, y: 0.9 - height / 2)
        }
        return Transform(position: position, scale: scale)
    }

    /// Scale keyframes that pop a sticker in over its first quarter second
    /// and out over its last, overshooting a little each way, as the ESLint
    /// stickers went out. Empty for a clip too short for both.
    public static func pop(scale: Double, duration: Time) -> [Keyframe] {
        let length = duration.seconds
        guard length >= 0.8 else { return [] }
        func key(_ time: Double, _ value: Double, _ interpolation: Interpolation) -> Keyframe {
            Keyframe(time: Time(seconds: time), value: .number(value), interpolation: interpolation)
        }
        let gone = scale * 0.01
        let over = scale * 1.1
        return [
            key(0, gone, .easeOut),
            key(0.15, over, .easeInOut),
            key(0.25, scale, .linear),
            key(length - 0.3, scale, .linear),
            key(length - 0.2, over, .easeIn),
            key(length - 0.05, gone, .linear)
        ]
    }
}
