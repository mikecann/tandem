import Foundation
import TandemCore
import TandemMedia

/// Clips levelled to a loudness (`audio.normalizeTo`) whose file isn't
/// measured yet. Levelling is a gain worked out from the file's measured
/// loudness, so until it's measured `RenderPlan` has nothing to level from
/// and the clip plays at the file's own level. On the Convex 1.50 video,
/// music beds patched to `normalizeTo: -45` played at -12.5 LUFS, as loud
/// as Mike's voice: the app was closed, so nothing measured the new files,
/// and neither `apply` nor `check` said so.
extension TandemService {
    struct Unlevelled {
        var clip: Clip
        var item: MediaItem
        var target: Double
    }

    /// How long `apply` waits for a file it just levelled to be measured.
    /// A music bed or sound effect reads in a second or two.
    static let measureWait: TimeInterval = 20

    /// The unmuted levelled clips (all of them, or those in `clipIDs`)
    /// whose file has sound and no loudness measurement.
    static func unlevelled(in project: Project, analysis: AnalysisSource, clipIDs: Set<String>? = nil) -> [Unlevelled] {
        var found: [Unlevelled] = []
        var measured: [String: Bool] = [:]
        for track in project.allTracks {
            for clip in track.clips where clipIDs?.contains(clip.id) ?? true {
                guard let audio = clip.audio, let target = audio.normalizeTo, !audio.muted,
                      let id = clip.mediaID, let item = project.media(id), item.hasAudio else { continue }
                let known = measured[id] ?? (analysis.loudness(for: item) != nil)
                measured[id] = known
                if !known { found.append(Unlevelled(clip: clip, item: item, target: target)) }
            }
        }
        return found
    }

    /// One line per file, for an edit's warnings.
    static func unlevelledWarnings(_ found: [Unlevelled]) -> [String] {
        let byFile = Dictionary(grouping: found, by: \.item.id)
        return byFile.keys.sorted().compactMap { id in
            guard let clips = byFile[id], let item = clips.first?.item else { return nil }
            let targets = Set(clips.map(\.target)).sorted().map { AudioLevels.number($0) }.joined(separator: " and ")
            let what = clips.count == 1 ? "its clip levelled to \(targets) LUFS plays" : "its \(clips.count) clips levelled to \(targets) LUFS play"
            return "\(item.path) isn't measured yet, so \(what) at the file's own level until it is."
                + " `tandem wait jobs --media \(item.id)` measures it, and `tandem loudness \(item.id)` shows the level."
        }
    }

    /// Measures the files of `found` and waits, up to `timeout`, for them.
    /// Returns what's still unmeasured.
    func measure(_ found: [Unlevelled], timeout: TimeInterval = TandemService.measureWait) async -> [Unlevelled] {
        guard !found.isEmpty else { return [] }
        var items: [MediaItem] = []
        for entry in found where !items.contains(where: { $0.id == entry.item.id }) { items.append(entry.item) }
        for item in items { analysis.request(.loudness, for: item, priority: .interactive) }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // Only while its job is queued or running: a file that failed,
            // or that nothing here can measure, won't be by waiting.
            let waiting = items.filter { item in
                guard analysis.loudness(for: item) == nil else { return false }
                switch analysis.state(of: AnalysisNeeds.Need(mediaID: item.id, kind: .loudness, priority: .interactive), for: item) {
                case .queued, .running: return true
                default: return false
                }
            }
            if waiting.isEmpty || Date() >= deadline || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return found.filter { analysis.loudness(for: $0.item) == nil }
    }

    /// `check`'s problem for each levelled clip whose file isn't measured,
    /// where `ranges` reach it.
    static func unlevelledProblems(in project: Project, analysis: AnalysisSource, ranges: [TimeRange]) -> [CheckProblem] {
        unlevelled(in: project, analysis: analysis).filter { entry in ranges.contains { $0.overlaps(entry.clip.range) } }.map { entry in
            CheckProblem(
                kind: .unlevelled, start: entry.clip.start, end: entry.clip.end,
                message: "Levelled to \(AudioLevels.number(entry.target)) LUFS, but \(entry.item.path) isn't measured yet, so it plays (and exports) at the file's own level."
                    + " `tandem wait jobs --media \(entry.item.id)` measures it.",
                clipIDs: [entry.clip.id]
            )
        }
    }
}
