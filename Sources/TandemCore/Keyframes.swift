import Foundation

// Keyframe evaluation. Keyframe times are relative to the clip start, and a
// segment eases with the interpolation of the keyframe it starts from.
//
// Animatable parameter paths:
//   video.transform.position   point
//   video.transform.scale      number
//   video.transform.rotation   number (degrees)
//   video.opacity              number 0...1
//   video.crop.left/top/right/bottom
//   video.effects.<effectID>.<param>
//   audio.gainDB               number
//   audio.effects.<effectID>.<param>

public enum AnimatableParameter {
    public static let fixed: [String] = [
        "video.transform.position",
        "video.transform.scale",
        "video.transform.rotation",
        "video.opacity",
        "video.crop.left",
        "video.crop.top",
        "video.crop.right",
        "video.crop.bottom",
        "audio.gainDB"
    ]

    public static func isKnown(_ path: String) -> Bool {
        fixed.contains(path) || path.hasPrefix("video.effects.") || path.hasPrefix("audio.effects.")
    }
}

public enum Easing {
    /// Maps linear progress 0...1 to eased progress.
    public static func apply(_ interpolation: Interpolation, _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch interpolation {
        case .linear: return t
        case .hold: return 0
        case .easeIn: return t * t * t
        case .easeOut:
            let u = 1 - t
            return 1 - u * u * u
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

extension ParamValue {
    /// Blends two values. Numbers, points and colours interpolate; bools and
    /// strings hold the first value until the second keyframe.
    public static func interpolate(_ a: ParamValue, _ b: ParamValue, _ t: Double) -> ParamValue {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return .number(x + (y - x) * t)
        case (.point(let p), .point(let q)):
            return .point(Point(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
        case (.color(let c), .color(let d)):
            return .color(RGBA(
                r: c.r + (d.r - c.r) * t,
                g: c.g + (d.g - c.g) * t,
                b: c.b + (d.b - c.b) * t,
                a: c.a + (d.a - c.a) * t
            ))
        default:
            return t < 1 ? a : b
        }
    }

    /// Blends two angles in degrees the short way round the circle, into
    /// 0..<360: from 350 to 10 passes 0, not 180.
    public static func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var delta = (b - a).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return ColourWheels.normalised(a + delta * t)
    }
}

extension Array where Element == Keyframe {
    /// The animated value at a clip-relative time. Before the first keyframe
    /// it holds the first value, after the last it holds the last. A
    /// `circular` value is an angle that blends the short way round.
    public func value(at time: Time, circular: Bool = false) -> ParamValue? {
        guard let first = first else { return nil }
        let sorted = self.sorted { $0.time < $1.time }
        if time <= first.time || sorted.count == 1 { return sorted[0].value }
        guard let last = sorted.last, time < last.time else { return sorted.last?.value }
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            if time >= a.time && time < b.time {
                let span = Double((b.time - a.time).flicks)
                let linear = span > 0 ? Double((time - a.time).flicks) / span : 1
                let eased = Easing.apply(a.interpolation, linear)
                if circular, case .number(let x) = a.value, case .number(let y) = b.value {
                    return .number(ParamValue.interpolateAngle(x, y, eased))
                }
                return ParamValue.interpolate(a.value, b.value, eased)
            }
        }
        return sorted.last?.value
    }
}

enum KeyframeEditing {
    static func shifted(_ keyframes: [String: [Keyframe]], by delta: Time) -> [String: [Keyframe]] {
        guard delta != .zero else { return keyframes }
        return keyframes.mapValues { list in
            list.map { var k = $0; k.time += delta; return k }
        }
    }

    static func scaled(_ keyframes: [String: [Keyframe]], by factor: Double) -> [String: [Keyframe]] {
        keyframes.mapValues { list in
            list.map { var k = $0; k.time = k.time.scaled(by: factor); return k }
        }
    }

    /// Keyframes that sit on the timeline rather than on a clip's content:
    /// sound ones are mixing (a music swell set under a section card), so
    /// when a ripple cut shortens a following clip they move with the
    /// timeline. Picture ones (a push across a still) stay with the content.
    static func followsTimeline(_ path: String) -> Bool {
        path.hasPrefix("audio.")
    }

    /// Re-times a clip's timeline keyframes through the removal of `range`,
    /// for a clip that ran from `oldStart` to `oldEnd` and now starts at
    /// `newStart` with its content unmoved from the head
    /// (`Track.followRemoval`). Keyframes before the cut stay, ones after it
    /// move left by its length and ones inside it go. Where the cut falls
    /// inside the keyed curve, a keyframe either side of it pins what played
    /// there, so the curve before the cut and after it are as they were
    /// (exactly for linear and hold segments; an eased segment the cut
    /// splits keeps its ends and its easing) and the value steps at the cut,
    /// as the picture does.
    static func followingRemoval(
        _ keyframes: [String: [Keyframe]],
        of range: TimeRange,
        oldStart: Time,
        oldEnd: Time,
        newStart: Time
    ) -> [String: [Keyframe]] {
        var result = keyframes
        for (path, list) in keyframes where followsTimeline(path) && !list.isEmpty {
            let sorted = list.sorted { $0.time < $1.time }
            let a = range.start - oldStart
            let b = range.end - oldStart
            // Each keyframe, and whether it's one pinned here.
            var before = sorted.filter { $0.time <= a }.map { ($0, false) }
            var after = sorted.filter { $0.time >= b }.map { ($0, false) }
            if let first = sorted.first, let last = sorted.last, a < last.time, b > first.time {
                // The clip has a piece before the cut only if it started
                // before it, and one after only if it ran past it.
                if oldStart < range.start, before.last?.0.time != a, let value = sorted.value(at: a) {
                    before.append((Keyframe(time: a, value: value, interpolation: .hold), true))
                }
                if oldEnd > range.end, after.first?.0.time != b, let value = sorted.value(at: b) {
                    // The segment playing at the end of the cut carries on.
                    let interpolation = sorted.last { $0.time <= b }?.interpolation ?? first.interpolation
                    after.insert((Keyframe(time: b, value: value, interpolation: interpolation), true), at: 0)
                }
            }
            after = after.map { var k = $0.0; k.time -= range.duration; return (k, $0.1) }
            var moved = before + after
            // A pinned keyframe on a flat stretch (the same value either
            // side of it) changes nothing, so a cut through a steady bed
            // leaves its keyframes as they were.
            var index = 0
            while index < moved.count {
                let value = moved[index].0.value
                let flatBefore = index == 0 || moved[index - 1].0.value == value
                let flatAfter = index == moved.count - 1 || moved[index + 1].0.value == value
                if moved[index].1, flatBefore, flatAfter, moved.count > 1 {
                    moved.remove(at: index)
                } else {
                    index += 1
                }
            }
            result[path] = moved.map { var k = $0.0; k.time += oldStart - newStart; return k }
        }
        return result
    }

    /// Drops keyframes that can't affect `0...duration`, keeping the nearest
    /// one on each side so the curve inside the clip is unchanged.
    static func pruned(_ keyframes: [String: [Keyframe]], duration: Time) -> [String: [Keyframe]] {
        var result: [String: [Keyframe]] = [:]
        for (path, list) in keyframes {
            let sorted = list.sorted { $0.time < $1.time }
            let before = sorted.last { $0.time < .zero }
            let after = sorted.first { $0.time > duration }
            var kept = sorted.filter { $0.time >= .zero && $0.time <= duration }
            if let before { kept.insert(before, at: 0) }
            if let after { kept.append(after) }
            if !kept.isEmpty { result[path] = kept }
        }
        return result
    }
}

extension Clip {
    /// Video properties at a time inside the clip (relative to its start)
    /// with keyframes applied. Clips without video properties get defaults.
    public func resolvedVideo(at clipTime: Time) -> VideoProperties {
        var video = self.video ?? VideoProperties()
        for (path, list) in keyframes where path.hasPrefix("video.") {
            guard let value = list.value(at: clipTime, circular: Self.isWheelHue(path, in: video)) else { continue }
            switch path {
            case "video.transform.position":
                if case .point(let p) = value { video.transform.position = p }
            case "video.transform.scale":
                if let n = value.number { video.transform.scale = n }
            case "video.transform.rotation":
                if let n = value.number { video.transform.rotation = n }
            case "video.opacity":
                if let n = value.number { video.opacity = n }
            case "video.crop.left":
                if let n = value.number { video.crop.left = n }
            case "video.crop.top":
                if let n = value.number { video.crop.top = n }
            case "video.crop.right":
                if let n = value.number { video.crop.right = n }
            case "video.crop.bottom":
                if let n = value.number { video.crop.bottom = n }
            default:
                let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
                if parts.count == 4, parts[1] == "effects",
                   let index = video.effects.firstIndex(where: { $0.id == parts[2] }) {
                    video.effects[index].params[parts[3]] = value
                }
            }
        }
        return video
    }

    /// True for a colour wheel's hue, an angle: a keyframe from 350 to 10
    /// should pass through red, not the rest of the wheel.
    static func isWheelHue(_ path: String, in video: VideoProperties) -> Bool {
        let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
        guard parts.count == 4, parts[1] == "effects", ColourWheels.Wheel.allCases.contains(where: { $0.hueKey == parts[3] }) else { return false }
        return video.effects.first { $0.id == parts[2] }?.type == "colorWheels"
    }

    /// Audio properties at a clip-relative time with keyframes applied.
    public func resolvedAudio(at clipTime: Time) -> AudioProperties {
        var audio = self.audio ?? AudioProperties()
        for (path, list) in keyframes where path.hasPrefix("audio.") {
            guard let value = list.value(at: clipTime) else { continue }
            if path == "audio.gainDB", let n = value.number {
                audio.gainDB = n
                continue
            }
            let parts = path.split(separator: ".", maxSplits: 3).map(String.init)
            if parts.count == 4, parts[1] == "effects",
               let index = audio.effects.firstIndex(where: { $0.id == parts[2] }) {
                audio.effects[index].params[parts[3]] = value
            }
        }
        return audio
    }
}
