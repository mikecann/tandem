import CoreGraphics
import Foundation
import TandemCore
import TandemMedia
import TandemRender

/// Where the service reads analysis results from. `MediaAnalysis` is the
/// real one; tests inject a fake so transcript tools can be tested without
/// the media module.
public protocol AnalysisSource: AnyObject, Sendable {
    func transcript(for item: MediaItem) -> Transcript?
    func loudness(for item: MediaItem) -> Loudness?
    /// True when a result for `kind` is cached and ready to use.
    func isReady(_ kind: AnalysisKind, for item: MediaItem) -> Bool
    /// Which matte the renderer would use for `item`, nil for none.
    func servedMatte(for item: MediaItem) -> String?
    var jobs: [JobStatus] { get }
    /// Calls `handler` whenever job status changes. Returns a token for
    /// `removeJobsObserver`.
    func observeJobs(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID
    func removeJobsObserver(_ token: UUID)
    /// Queues one analysis. Cheap when it's made or queued already.
    func request(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority)
    /// Queues what the project needs (`AnalysisNeeds`).
    func requestNeeded(for project: Project)
    /// What the project needs, with this analysis's settings.
    func needs(for project: Project) -> [AnalysisNeeds.Need]
    /// Where one needed analysis stands.
    func state(of need: AnalysisNeeds.Need, for item: MediaItem) -> MediaAnalysis.ResultState
}

extension AnalysisSource {
    /// Sources without mattes (test doubles) serve none.
    public func servedMatte(for item: MediaItem) -> String? { nil }

    public func needs(for project: Project) -> [AnalysisNeeds.Need] {
        AnalysisNeeds.needs(for: project)
    }

    /// From `isReady` and the job list, for sources that can't say more.
    public func state(of need: AnalysisNeeds.Need, for item: MediaItem) -> MediaAnalysis.ResultState {
        guard need.kind.applies(to: item) else { return .notApplicable }
        if isReady(need.kind, for: item) { return .ready }
        guard let job = jobs.last(where: { $0.mediaID == item.id && $0.kind == need.kind }) else { return .missing }
        switch job.state {
        case .queued: return .queued
        case .running: return .running(progress: job.progress)
        case .failed: return .failed(job.message ?? "failed")
        case .done, .cancelled: return .missing
        }
    }
}

/// The real analysis, through `MediaAnalysis`'s documented methods. An
/// adapter rather than an extension, so nothing here can clash with names
/// the media module adds.
public final class MediaAnalysisSource: AnalysisSource, @unchecked Sendable {
    public let analysis: MediaAnalysis

    public init(_ analysis: MediaAnalysis) {
        self.analysis = analysis
    }

    public func transcript(for item: MediaItem) -> Transcript? { analysis.transcript(for: item) }
    public func loudness(for item: MediaItem) -> Loudness? { analysis.loudness(for: item) }

    public func isReady(_ kind: AnalysisKind, for item: MediaItem) -> Bool {
        analysis.isCached(kind, for: item)
    }

    public func servedMatte(for item: MediaItem) -> String? { analysis.servedMatte(for: item) }

    public var jobs: [JobStatus] { analysis.jobs }

    public func observeJobs(_ handler: @escaping @Sendable ([JobStatus]) -> Void) -> UUID {
        analysis.observe(handler)
    }

    public func removeJobsObserver(_ token: UUID) {
        analysis.removeObserver(token)
    }

    public func request(_ kind: AnalysisKind, for item: MediaItem, priority: JobPriority) {
        analysis.request(kind, for: item, priority: priority)
    }

    public func requestNeeded(for project: Project) {
        analysis.requestNeeded(for: project)
    }

    public func needs(for project: Project) -> [AnalysisNeeds.Need] {
        AnalysisNeeds.needs(for: project, settings: analysis.settings)
    }

    public func state(of need: AnalysisNeeds.Need, for item: MediaItem) -> MediaAnalysis.ResultState {
        // A matte in another cutout mode than the default is its own result.
        var settings: AnalysisSettings?
        if let mode = need.matteMode, mode != analysis.settings.matteMode {
            var custom = analysis.settings
            custom.matteMode = mode
            settings = custom
        }
        // A matte is ready for the edit once the stretches its clips play
        // are, though the rest of the file is still being made.
        if need.kind == .matte { return analysis.matteState(for: item, settings: settings, spans: need.matteSpans) }
        return analysis.state(need.kind, for: item, settings: settings)
    }
}

/// A rendered frame and what the renderer couldn't do as the project asks.
public struct RenderedFrame: Sendable {
    public var png: Data
    /// For example "No cutout matte for source/take-camera.mov yet (clip
    /// clip_k3f9x2mq), showing the full frame."
    public var warnings: [String]

    public init(png: Data, warnings: [String] = []) {
        self.png = png
        self.warnings = warnings
    }
}

/// A finished export and the renderer's warnings for what it rendered.
public struct RenderedExport: Sendable {
    public var result: ExportResult
    public var warnings: [String]

    public init(result: ExportResult, warnings: [String] = []) {
        self.result = result
        self.warnings = warnings
    }
}

/// Frame grabs and exports. The default goes through `FrameRenderer` and
/// `Exporter`; tests inject a fake so the API plumbing (files, base64, MCP
/// image content, progress events, warnings) is tested without rendering.
public protocol RenderBackend: Sendable {
    func frame(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> RenderedFrame
    func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedExport
    /// Every frame of `ranges`, rendered `width` wide and measured, for
    /// `tandem check`; with `scanlines`, each frame's lines too.
    func scan(context: RenderContext, ranges: [TimeRange], width: Int, scanlines: Bool) async throws -> [FrameStats]
    /// The mix's loudness over `range` every `step`, for `tandem loudness
    /// --from --to`.
    func loudness(context: RenderContext, range: TimeRange, step: Time) async throws -> MixLoudness
    /// Whether each track's render follows its gain lane over `range`, for
    /// `tandem loudness --gains`.
    func checkGains(context: RenderContext, range: TimeRange, trackIDs: [String]) async throws -> [GainFollow]
}

public struct DefaultRenderBackend: RenderBackend {
    public init() {}

    public func scan(context: RenderContext, ranges: [TimeRange], width: Int, scanlines: Bool) async throws -> [FrameStats] {
        try await FrameScanner.scan(context, ranges: ranges, width: width, scanlines: scanlines)
    }

    public func loudness(context: RenderContext, range: TimeRange, step: Time) async throws -> MixLoudness {
        try await MixMeter.measure(context, range: range, step: step)
    }

    public func checkGains(context: RenderContext, range: TimeRange, trackIDs: [String]) async throws -> [GainFollow] {
        try await MixMeter.checkGains(context, range: range, trackIDs: trackIDs)
    }

    public func frame(context: RenderContext, at time: Time, maxSize: CGSize?) async throws -> RenderedFrame {
        let renderer = FrameRenderer(context: context)
        let png = try await renderer.pngData(at: time, maxSize: maxSize)
        // The composition is built by now, so this costs nothing.
        let warnings = (try? await renderer.warnings()) ?? []
        return RenderedFrame(png: png, warnings: warnings)
    }

    public func export(
        context: RenderContext,
        preset: ExportPreset,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RenderedExport {
        let exporter = Exporter(context: context, preset: preset, output: output)
        let result = try await exporter.run(progress: progress)
        return RenderedExport(result: result, warnings: exporter.warnings)
    }
}

/// Picks the render warnings that matter for part of the timeline. The
/// renderer warns about the whole project (every file still missing its
/// cutout matte, say), so a frame at 2:00 only keeps the lines about media
/// and clips that play around then. A line that names a clip goes by the
/// clip alone, even when it names its file too: a take matted stretch by
/// stretch has clips cut out and clips not yet, and a frame of one that
/// is shouldn't warn about one that isn't. Lines that name no media or clip
/// are always kept. Repeats are dropped.
public enum RenderWarnings {
    public static func relevant(_ warnings: [String], in project: Project, range: TimeRange?) -> [String] {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        guard let range else { return unique }
        let clips = project.allTracks.flatMap(\.clips)
        let playing = clips.filter { $0.range.overlaps(range) }
        let playingIDs = Set(playing.map(\.id))
        let playingMedia = Set(playing.compactMap(\.mediaID))
        let paths = project.media.map { ($0.id, $0.path) }
        return unique.filter { line in
            let mentionedClips = clips.map(\.id).filter { line.contains($0) }
            let mentionedMedia = paths.filter { line.contains($0.1) }.map(\.0)
            if !mentionedClips.isEmpty { return mentionedClips.contains(where: playingIDs.contains) }
            if mentionedMedia.isEmpty { return true }
            return mentionedMedia.contains(where: playingMedia.contains)
        }
    }
}

/// Export presets by name, forgiving about case, spaces and punctuation, so
/// `youtube4k`, `YouTube 4K` and `youtube-4k` all work, and `review` and
/// `short` find their presets.
public enum PresetNames {
    public static func find(_ name: String) -> ExportPreset? {
        let wanted = slug(name)
        return ExportPreset.all.first { slug($0.name) == wanted || slug($0.name).hasPrefix(wanted) }
    }


    static func slug(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
