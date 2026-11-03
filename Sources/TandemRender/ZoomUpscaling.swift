import CoreGraphics
import Foundation
import TandemCore
import TandemMedia

/// Which clips an export plays from a twice-the-size copy of their screen
/// recording (`UpscaleJob`), and making those copies first.
///
/// A clip gets one when a zoom draws its source pixels at least
/// `threshold` times their size at the export's size. Mike's 3200 px
/// recordings sit at 1.2x on a 4K timeline unzoomed, which the Lanczos
/// resample handles; zoomed in they go soft. A 1080p review render of the
/// same zoom draws them smaller, so it doesn't wait for copies it doesn't
/// need. The copy is of the clip's stretch of the file, a second past each
/// end (`margin`) so a transition's handles and a small trim stay inside it.
enum ZoomUpscaling {
    static let threshold = 1.3
    static let margin = Time(seconds: 1)

    /// The most `clip` ever scales its source, in output pixels per source
    /// pixel. Between two keyframes the scale eases from one to the other,
    /// so the most is at a keyframe or an end.
    static func maxScale(_ clip: Clip, item: MediaItem, canvas: CGSize, format: String?) -> Double {
        guard let width = item.width, let height = item.height, width > 0, height > 0 else { return 0 }
        var times: [Time] = [.zero, clip.duration]
        times += (clip.keyframes["video.transform.scale"] ?? []).map(\.time).filter { $0 > .zero && $0 < clip.duration }
        let source = CGSize(width: width, height: height)
        return times.compactMap { clip.resolvedVideo(at: $0, format: format) }
            .map { Double(LayerMath.totalScale(source: source, canvas: canvas, transform: $0.transform)) }
            .max() ?? 0
    }

    static func wants(_ clip: Clip, item: MediaItem, canvas: CGSize, format: String?) -> Bool {
        guard AnalysisKind.upscale.applies(to: item), clip.enabled, !clip.isHidden(inFormat: format) else { return false }
        return maxScale(clip, item: item, canvas: canvas, format: format) >= threshold
    }

    /// The stretch of the file `clip` shows, with the margin.
    static func span(for clip: Clip, item: MediaItem) -> UpscaleSpan {
        let start = clip.sourceStart + (item.pictureDelay ?? .zero)
        let length = clip.freezeFrame ? .zero : clip.duration.scaled(by: abs(clip.speed))
        return UpscaleSpan(covering: TimeRange(start: max(.zero, start - margin), end: start + length + margin))
    }

    /// The copies an export of `range` (all of it when nil) needs: each
    /// zoomed clip's span, joined where they overlap or nearly meet. A take
    /// cut tightly into several zoomed clips then makes one copy rather than
    /// several that each redo the seconds they share.
    static func wanted(_ context: RenderContext, range: TimeRange?) -> [(item: MediaItem, span: UpscaleSpan)] {
        let project = context.project
        let canvas = context.renderSize
        var spans: [String: [UpscaleSpan]] = [:]
        var items: [String: MediaItem] = [:]
        for track in project.videoTracks where !track.hidden {
            for clip in track.clips {
                guard let mediaID = clip.mediaID, let item = project.media(mediaID) else { continue }
                if let range, clip.end <= range.start || clip.start >= range.end { continue }
                guard wants(clip, item: item, canvas: canvas, format: context.format) else { continue }
                spans[item.id, default: []].append(span(for: clip, item: item))
                items[item.id] = item
            }
        }
        var wanted: [(item: MediaItem, span: UpscaleSpan)] = []
        for (id, list) in spans.sorted(by: { $0.key < $1.key }) {
            for span in joined(list) { wanted.append((items[id]!, span)) }
        }
        return wanted
    }

    /// Spans less than `joinGap` seconds apart become one: decoding a
    /// second between them costs less than starting another copy.
    static let joinGap = 2

    static func joined(_ spans: [UpscaleSpan]) -> [UpscaleSpan] {
        var result: [UpscaleSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, span.start <= last.end + joinGap {
                result[result.count - 1].end = max(last.end, span.end)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// The copy a picture segment plays from, when its clip wants one and
    /// a copy covering the segment has been made.
    static func copy(for segment: PlannedSegment, clip: Clip, item: MediaItem, context: RenderContext) -> URL? {
        guard context.upscalesZooms, wants(clip, item: item, canvas: context.renderSize, format: context.format) else { return nil }
        let length = segment.freeze ? .zero : segment.timeline.duration.scaled(by: abs(segment.speed))
        // A segment reaching further than any copy (a long transition)
        // plays the original.
        return context.assets?.upscaledURL(for: item, covering: TimeRange(start: max(.zero, segment.sourceStart), end: segment.sourceStart + length))
    }

    static func missingCopies(_ context: RenderContext, range: TimeRange?) -> [(item: MediaItem, span: UpscaleSpan)] {
        guard context.upscalesZooms, let analysis = context.analysis else { return [] }
        return wanted(context, range: range).filter { analysis.upscaledURL(for: $0.item, covering: $0.span.timeRange) == nil }
    }

    /// Makes the copies an export of `range` needs, one after another, and
    /// waits for them. `progress` goes from 0 to 1 over the ones missing.
    /// Returns what couldn't be made.
    static func prepare(_ context: RenderContext, range: TimeRange?, progress: @escaping @Sendable (Double) -> Void) async -> [String] {
        guard context.upscalesZooms, let analysis = context.analysis else { return [] }
        let missing = missingCopies(context, range: range)
        var notes: [String] = []
        for (index, copy) in missing.enumerated() {
            let done = Double(index), count = Double(missing.count)
            let state = await analysis.waitForUpscale(of: copy.item, span: copy.span) { fraction, _ in
                progress((done + fraction) / count)
            }
            if state != .ready {
                let why: String
                if case .failed(let reason) = state { why = reason } else { why = "it wasn't made" }
                notes.append("Couldn't sharpen \(copy.item.path) for its zoom (\(copy.span.start) to \(copy.span.end) s): \(why). That stretch plays from the original.")
            }
            progress(Double(index + 1) / count)
        }
        return notes
    }
}
