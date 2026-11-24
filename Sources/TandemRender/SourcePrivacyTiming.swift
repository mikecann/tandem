import Foundation
import TandemCore

/// Nominal rates can hide dropped frames. Privacy follows the actual
/// presentation table; an unreadable table keeps the whole region hidden.
enum SourcePrivacyTiming: Sendable {
    case allFrames
    case samples([Time])

    init(_ times: [Time]?) {
        guard let times, !times.isEmpty, times[0] >= .zero,
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 }) else {
            self = .allFrames
            return
        }
        self = .samples(times)
    }

    var protectsEveryFrame: Bool {
        if case .allFrames = self { return true }
        return false
    }

    private static func index(at time: Time, in samples: [Time]) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid] <= time { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    func source(at request: Time, delay: Time) -> Time? {
        guard case .samples(let times) = self, !times.isEmpty else { return nil }
        return times[Self.index(at: request + delay, in: times)] - delay
    }

    /// One actual sample's presentation interval. An output frame (or even
    /// a millisecond) can contain several samples in a fast source file.
    func slice(at request: Time, within available: TimeRange) -> TimeRange? {
        guard case .samples(let times) = self, !times.isEmpty else { return nil }
        let index = Self.index(at: request, in: times)
        let next = Self.index(at: times[index], in: times) + 1
        let start = max(available.start, times[index])
        let end = min(available.end, next < times.count ? times[next] : available.end)
        return end > start ? TimeRange(start: start, end: end) : nil
    }

    func expanding(_ ranges: [TimeRange], media: MediaItem, frame: Time) -> [TimeRange] {
        guard case .samples(let times) = self, !times.isEmpty else { return ranges }
        let delay = media.pictureDelay ?? .zero
        return TimeRange.union(ranges.map { range in
            let first = Self.index(at: range.start + delay, in: times)
            let last = Self.index(at: range.end + delay - Time(flicks: 1), in: times)
            let next = Self.index(at: times[last], in: times) + 1
            let end = next < times.count ? times[next] : max(media.duration ?? .zero, times.last! + frame)
            return TimeRange(start: min(range.start, times[first] - delay), end: max(range.end, end - delay))
        })
    }
}
