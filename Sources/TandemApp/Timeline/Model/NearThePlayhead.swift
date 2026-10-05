import Foundation
import TandemCore

/// What's near the playhead, for the sidebar while nothing's selected: the
/// markers, to-dos and comments just before and after it, and the agent
/// edits at it. It changes only when the playhead passes one of them, so
/// the sidebar doesn't redraw on every frame of playback.
struct NearThePlayhead: Equatable {
    struct Item: Equatable, Identifiable {
        var marker: Marker
        var strip: MarkerStrip
        /// The playhead is on it: inside its stretch, or just past a point.
        var isHere: Bool
        var id: String { marker.id }
    }

    /// Earliest first.
    var items: [Item] = []
    /// The agent edits whose changes are at the playhead, oldest first.
    var edits: [TimelineReview.Edit] = []

    static let empty = NearThePlayhead()
    /// How many it lists either side of the playhead.
    static let before = 2
    static let after = 4
    /// How long a point stays "here" once the playhead reaches it.
    static let lingers = Time(seconds: 1.5)

    static func at(_ time: Time, in project: Project, review: TimelineReview) -> NearThePlayhead {
        let all = project.markers.sorted { $0.time < $1.time }
        let split = all.firstIndex { $0.time > time } ?? all.count
        let shown = all[..<split].suffix(before) + all[split...].prefix(after)
        let items = shown.map { marker in
            let end = marker.time + max(marker.duration, lingers)
            return Item(marker: marker, strip: MarkerStrip.of(marker), isHere: marker.time <= time && time < end)
        }
        return NearThePlayhead(items: items, edits: review.edits(at: time))
    }
}

extension MarkerStrip {
    /// The strip a marker shows in.
    static func of(_ marker: Marker) -> MarkerStrip {
        allCases.first { $0.holds(marker) } ?? .markers
    }
}
