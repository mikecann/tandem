import Foundation
import TandemCore

/// The review log as the timeline shows it now: the clips an agent added
/// or changed, the marks where it took something out, the stretches of
/// time with changes in them for the ruler's band, and the places the next
/// and previous change commands stop, so Mike watches only what changed.
struct TimelineReview: Equatable {
    /// One agent edit, for the band's tooltip.
    struct Edit: Equatable {
        var revision: Int
        var author: String
        var label: String
        var date: Date
    }

    /// One change: a clip, a transition, or a removal's moment.
    struct Span: Equatable {
        var start: Time
        var end: Time
        var edit: Edit
    }

    /// A stretch of the ruler's band: changes merged where they're close.
    struct Region: Equatable {
        var start: Time
        var end: Time
    }

    /// Where stepping lands: the start of a change, or of changes that
    /// start close together.
    struct Stop: Equatable {
        var time: Time
        /// Oldest first.
        var edits: [Edit]
    }

    /// Where a removal's mark is now.
    struct Removal: Equatable {
        var trackID: String
        var time: Time
    }

    var clipIDs: Set<String> = []
    var transitionIDs: Set<String> = []
    var removals: [Removal] = []
    /// By start.
    var spans: [Span] = []
    var regions: [Region] = []
    var stops: [Stop] = []
    /// Agent edits waiting for review, for the toolbar's chip.
    var editCount = 0

    static let empty = TimelineReview()

    /// Changes closer than this share a band, and starts closer than this
    /// share a stop.
    static let mergeGap = Time(seconds: 2)
    /// Stepping from a stop moves on to the next one.
    static let stepSlop = Time(seconds: 0.001)

    var isEmpty: Bool { editCount == 0 }

    static func make(log: ReviewLog, project: Project) -> TimelineReview {
        guard !log.isEmpty else { return .empty }
        var review = TimelineReview()
        review.editCount = log.entries.count
        var spans: [Span] = []
        for change in log.changes(in: project) {
            let entry = change.entry
            let edit = Edit(revision: entry.revision, author: entry.author, label: entry.label, date: entry.date)
            switch change.subject {
            case .clip(let id): review.clipIDs.insert(id)
            case .transition(let id): review.transitionIDs.insert(id)
            case .removal(let trackID): review.removals.append(Removal(trackID: trackID, time: change.start))
            }
            spans.append(Span(start: change.start, end: change.end, edit: edit))
        }
        review.spans = spans.sorted { ($0.start, $0.end, $0.edit.revision) < ($1.start, $1.end, $1.edit.revision) }
        for span in review.spans {
            if let last = review.regions.last, span.start <= last.end + mergeGap {
                review.regions[review.regions.count - 1].end = max(last.end, span.end)
            } else {
                review.regions.append(Region(start: span.start, end: span.end))
            }
            if let last = review.stops.last, span.start <= last.time + mergeGap {
                if !last.edits.contains(where: { $0.revision == span.edit.revision }) {
                    review.stops[review.stops.count - 1].edits.append(span.edit)
                }
            } else {
                review.stops.append(Stop(time: span.start, edits: [span.edit]))
            }
        }
        for index in review.stops.indices {
            review.stops[index].edits.sort { ($0.date, $0.revision) < ($1.date, $1.revision) }
        }
        return review
    }

    // MARK: - Stepping

    /// The next stop after `time`, for Next agent change.
    func stop(after time: Time) -> Stop? {
        stops.first { $0.time > time + Self.stepSlop }
    }

    /// The stop before `time`, for Previous agent change.
    func stop(before time: Time) -> Stop? {
        stops.last { $0.time < time - Self.stepSlop }
    }

    /// The edits whose changes are at `time`, reaching `slop` either side,
    /// for hovering the band. Oldest first.
    func edits(at time: Time, slop: Time = .zero) -> [Edit] {
        var found: [Edit] = []
        for span in spans where span.start - slop <= time && time <= span.end + slop {
            if !found.contains(where: { $0.revision == span.edit.revision }) { found.append(span.edit) }
        }
        return found.sorted { ($0.date, $0.revision) < ($1.date, $1.revision) }
    }

    // MARK: - Words

    /// "Claude · Add push · 14:32", a line an edit.
    static func tooltip(for edits: [Edit], now: Date = Date()) -> String {
        let limit = 8
        var lines = edits.prefix(limit).map { edit in
            "\(ActivityLog.displayName(edit.author)) · \(edit.label) · \(when(edit.date, now: now))"
        }
        if edits.count > limit { lines.append("and \(edits.count - limit) more") }
        return lines.joined(separator: "\n")
    }

    /// The time today, with the day before today: the log outlasts
    /// restarts, so an edit can be from yesterday.
    static func when(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "7 agent edits", for the toolbar's chip.
    var chipTitle: String {
        editCount == 1 ? "1 agent edit" : "\(editCount) agent edits"
    }
}
