import Foundation
import TandemCore

/// Which analyses a project needs, worked out from what its edit uses.
///
/// Every file in the project folder shows up in the media browser, and a
/// video folder can hold hundreds (old renders, drafts, B-roll that never
/// made it in). So the cheap analyses (thumbnails, waveforms, loudness, and
/// the conversion of a file macOS can't decode) run for everything, the
/// transcript runs for every camera take so you can search what you said
/// before placing it, and the expensive ones only run for what the edit
/// uses:
///
/// - scrub proxies for large video on the timeline,
/// - a cutout matte for media with a clip whose cutout is on (in any format),
/// - isolated voice for media with a clip using voice isolation,
/// - a transcript for anything on a speech track (the unmuted `cut` audio
///   tracks, like Voice), and for any file someone asked for one of
///   (`MediaItem.transcribe`, set by `tandem transcribe`).
///
/// Placing a take or turning on its cutout queues the rest.
public enum AnalysisNeeds {
    public struct Need: Equatable, Sendable {
        public var mediaID: String
        public var kind: AnalysisKind
        public var priority: JobPriority
        /// Set for mattes: the cutout mode the clips ask for.
        public var matteMode: CutoutMode?
        /// Set for mattes: the stretches of the file the cutout clips play,
        /// first on the timeline first (`MatteSpans`). They're matted before
        /// the rest of the file, so the corner is cut out in minutes rather
        /// than once a long take is done.
        public var matteSpans: [UpscaleSpan]

        public init(mediaID: String, kind: AnalysisKind, priority: JobPriority, matteMode: CutoutMode? = nil, matteSpans: [UpscaleSpan] = []) {
            self.mediaID = mediaID
            self.kind = kind
            self.priority = priority
            self.matteMode = matteMode
            self.matteSpans = matteSpans
        }
    }

    public static func needs(for project: Project, settings: AnalysisSettings = .standard) -> [Need] {
        var onTimeline = Set<String>()
        var onSpeech = Set<String>()
        var cutoutModes: [String: Set<CutoutMode>] = [:]
        var cutoutSpans: [String: [CutoutMode: [MatteSpans.Placed]]] = [:]
        let mediaByID = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var isolated = Set<String>()
        let speechTracks = Set(speechTrackIDs(project))
        for track in project.allTracks {
            for clip in track.clips {
                guard let mediaID = clip.mediaID else { continue }
                onTimeline.insert(mediaID)
                if speechTracks.contains(track.id) { onSpeech.insert(mediaID) }
                if track.kind == .video, let cutout = clip.video?.cutout {
                    let overridden = clip.video?.formatOverrides.values.contains { $0.cutout == true } ?? false
                    if cutout.enabled || overridden {
                        cutoutModes[mediaID, default: []].insert(cutout.mode)
                        let handles = track.transitions.map(\.duration).max() ?? .zero
                        let span = MatteSpans.span(for: clip, pictureDelay: mediaByID[mediaID]?.pictureDelay ?? .zero, handles: handles)
                        cutoutSpans[mediaID, default: [:]][cutout.mode, default: []].append(.init(timelineStart: clip.start, span: span))
                    }
                }
                if track.kind == .audio, (clip.audio?.voiceIsolation ?? 0) > 0 { isolated.insert(mediaID) }
            }
        }

        var needs: [Need] = []
        // Timeline media first, so its work is queued ahead of the rest.
        let ordered = project.media.filter { onTimeline.contains($0.id) } + project.media.filter { !onTimeline.contains($0.id) }
        for item in ordered {
            let used = onTimeline.contains(item.id)
            let priority: JobPriority = used ? .timeline : .background
            // A file macOS can't decode is converted first, used or not, so
            // the browser can show it; its picture analyses follow the copy.
            for kind in [AnalysisKind.converted, .thumbnails, .waveform, .loudness] where kind.applies(to: item) {
                needs.append(Need(mediaID: item.id, kind: kind, priority: priority))
            }
            let asked = item.transcribe == true
            if AnalysisKind.transcript.applies(to: item) && (item.role == .camera || onSpeech.contains(item.id) || asked) {
                // Someone asked for it, so it goes ahead of the folder's idle work.
                needs.append(Need(mediaID: item.id, kind: .transcript, priority: asked ? max(priority, .timeline) : priority))
            }
            guard used else { continue }
            if AnalysisKind.proxy.applies(to: item), let width = item.width, let height = item.height,
               width > settings.proxyMaxWidth || height > settings.proxyMaxHeight {
                needs.append(Need(mediaID: item.id, kind: .proxy, priority: .timeline))
            }
            if AnalysisKind.matte.applies(to: item) {
                for mode in (cutoutModes[item.id] ?? []).sorted(by: { $0.rawValue < $1.rawValue }) {
                    let spans = MatteSpans.ordered(cutoutSpans[item.id]?[mode] ?? [], duration: item.duration)
                    needs.append(Need(mediaID: item.id, kind: .matte, priority: .timeline, matteMode: mode, matteSpans: spans))
                }
            }
            if isolated.contains(item.id) && AnalysisKind.isolatedVoice.applies(to: item) {
                needs.append(Need(mediaID: item.id, kind: .isolatedVoice, priority: .timeline))
            }
        }
        return needs
    }

    /// The unmuted audio tracks that ripple with the take (Voice), or every
    /// unmuted audio track when none do. The same rule the transcript tools
    /// use to find what's said.
    static func speechTrackIDs(_ project: Project) -> [String] {
        let audio = project.audioTracks.filter { !$0.muted }
        let take = audio.filter { $0.rippleMode == .cut }
        return (take.isEmpty ? audio : take).map(\.id)
    }
}

/// The stretches of a take its cutout clips play, which are matted first.
///
/// An 8 minute 4K take with a minute and a half of it in the corner took
/// over an hour and a half to matte on a busy Mac, and every clip showed
/// the whole camera frame until the end. Now each stretch a clip plays is
/// its own matte (`MediaAnalysis.submitMatteSpan`), made first on the
/// timeline first, and the clip is cut out as soon as its stretch is done;
/// the whole file follows in the background, for clips placed later.
public enum MatteSpans {
    /// Room either side of what a clip plays, so a small trim stays inside
    /// its matte, and RVM's recurrent state has settled by the clip's first
    /// frame.
    public static let margin = Time(seconds: 1)
    /// Stretches closer than this many seconds become one: a take cut
    /// tightly into several clips mattes once, and each stretch starts its
    /// own clean plate and settling.
    public static let joinGap = 2

    public struct Placed: Equatable, Sendable {
        public var timelineStart: Time
        public var span: UpscaleSpan
    }

    /// The file's media time a clip's picture plays, transition handles
    /// (at most `handles` of timeline either side) and `margin` included.
    /// The planner plays a webcam's picture `pictureDelay` later in the
    /// file, so the stretch moves with it.
    public static func span(for clip: Clip, pictureDelay: Time, handles: Time) -> UpscaleSpan {
        let rate = abs(clip.speed)
        let start = clip.sourceStart + pictureDelay
        let end = start + (clip.freezeFrame ? .zero : clip.duration.scaled(by: rate))
        let reach = (clip.freezeFrame ? .zero : handles.scaled(by: rate)) + margin
        return UpscaleSpan(covering: TimeRange(start: max(.zero, min(start, end) - reach), end: max(start, end) + reach))
    }

    /// Joined where they overlap or nearly meet, cut to the file's
    /// length, in the order their first clip plays.
    public static func ordered(_ placed: [Placed], duration: Time?) -> [UpscaleSpan] {
        var joined: [Placed] = []
        for next in placed.sorted(by: { $0.span.start < $1.span.start }) {
            if let last = joined.last, next.span.start <= last.span.end + joinGap {
                joined[joined.count - 1].span.end = max(last.span.end, next.span.end)
                joined[joined.count - 1].timelineStart = min(last.timelineStart, next.timelineStart)
            } else {
                joined.append(next)
            }
        }
        let end = duration.map { Int($0.seconds.rounded(.up)) }
        return joined.sorted { $0.timelineStart == $1.timelineStart ? $0.span.start < $1.span.start : $0.timelineStart < $1.timelineStart }
            .compactMap { placed in
                guard let end else { return placed.span }
                guard placed.span.start < end else { return nil }
                return UpscaleSpan(start: placed.span.start, end: min(placed.span.end, end))
            }
    }
}

extension MediaAnalysis {
    /// Queues what `project` needs (see `AnalysisNeeds`). Cheap to call after
    /// every edit: work that's cached or already queued isn't repeated.
    public func requestNeeded(for project: Project) {
        let settings = self.settings
        let byID = Dictionary(project.media.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var wantedSpans = Set<String>()
        for need in AnalysisNeeds.needs(for: project, settings: settings) {
            guard let item = byID[need.mediaID] else { continue }
            var needSettings: AnalysisSettings?
            if let mode = need.matteMode, mode != settings.matteMode {
                var custom = settings
                custom.matteMode = mode
                needSettings = custom
            }
            guard need.kind == .matte else {
                submit(need.kind, for: item, priority: need.priority, settings: needSettings)
                continue
            }
            // The stretches the clips play first, in timeline order, then
            // the whole file behind them, for clips placed later.
            let spans = need.matteSpans.compactMap { submitMatteSpan(for: item, span: $0, priority: need.priority, settings: needSettings) }
            wantedSpans.formUnion(spans)
            submit(.matte, for: item, priority: need.matteSpans.isEmpty ? need.priority : .background, settings: needSettings)
        }
        dropUnwantedMatteSpans(keeping: wantedSpans)
    }
}
