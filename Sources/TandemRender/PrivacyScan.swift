import AVFoundation
import CoreGraphics
import ImageIO
import TandemMedia
import CoreImage
import Foundation
import NaturalLanguage
import TandemCore
import Vision

/// A line of text Vision read off a frame of the timeline.
public struct ReadLine: Equatable, Sendable {
    public var text: String
    /// Where it is, in fractions of the frame from the top left.
    public var box: CGRect
    public var confidence: Double

    public init(text: String, box: CGRect, confidence: Double = 1) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// What could be read on one frame: its lines of text, and where any QR
/// code or barcode is (fractions of the frame from the top left).
public struct ReadFrame: Equatable, Sendable {
    public var time: Time
    public var lines: [ReadLine]
    public var codes: [CGRect]
    public var recognitionError: String?
    /// Media inputs omitted on this composed frame, including decoder gaps.
    /// Their metadata cannot establish the source of visible OCR pixels.
    public var unavailableClipIDs: Set<String> = []
    /// Drawn video inputs with an opaque loaded format and known sampling
    /// support. Attribution also checks the clip's alpha and sampling edge.
    public var opaqueVideoClipIDs: Set<String> = []
    /// Media inputs supplied on this frame, rather than inferred from a
    /// clip merely occupying that time in the timeline.
    public var visibleClipIDs: Set<String> = []
    /// Exact per-layer opacity for the OCR regions of this output frame.
    var inputCoverage: [FramePrivacyEvidence.Region] = []
    /// The composed sample's clock, which also places animated source pixels.
    var renderedTime: Time?

    public init(time: Time, lines: [ReadLine], codes: [CGRect] = [], recognitionError: String? = nil) {
        self.time = time
        self.lines = lines
        self.codes = codes
        self.recognitionError = recognitionError
    }
}

/// Renders frames of the timeline as export does (the blurs in place,
/// whatever scrolls past them) and reads them on this Mac with Vision.
public final class FrameTextReader: @unchecked Sendable {
    let context: RenderContext
    let renderer: FrameRenderer
    let size: CGSize
    private let lock = NSLock()
    private var readCount = 0
    private var built: Task<BuiltComposition, Error>?

    /// `width` is how wide frames are rendered to be read: 1920 reads the
    /// text a viewer of a 1080p video could.
    public init(context: RenderContext, width: Int) {
        var context = context
        context.useProxies = false
        let canvas = context.renderSize
        let height = Int((Double(width) * canvas.height / max(canvas.width, 1)).rounded())
        size = CGSize(width: width, height: max(2, height))
        context.sizeOverride = size
        context.collectPrivacyEvidence = true
        self.context = context
        renderer = FrameRenderer(context: context)
    }

    /// How many frames Vision has read (frames like the one before aren't).
    public var framesRead: Int { lock.withLock { readCount } }

    /// The frames at `times`. `sequential` reads them in one pass through
    /// the timeline, as export does, decoding every frame and reading the
    /// ones asked for: far faster than seeking to each in a 4K screen
    /// recording (5 s of video a second against 0.2). Otherwise each is a
    /// seek, for the few frames that find an edge.
    public func read(_ times: [Time], sequential: Bool) async throws -> [ReadFrame] {
        guard sequential else {
            var frames: [ReadFrame] = []
            var last: [UInt8]?
            var lastFrame: ReadFrame?
            for (time, image) in try await renderer.images(at: times, maxSize: size) {
                // A CGImage does not carry the compositor's input evidence.
                frames.append(annotated(read(image, at: time, last: &last, lastFrame: &lastFrame), with: nil))
            }
            return frames
        }
        let built = try await composition()
        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { return [] }
        // Pieces of up to 10 s, a few read at once like check's scan: most of
        // the time is Vision reading a frame full of text, about a second.
        var pieces: [[Time]] = []
        for time in times.sorted() {
            if let first = pieces.last?.first, let last = pieces.last?.last, time - first < Time(seconds: 10), time - last < Time(seconds: 2) {
                pieces[pieces.count - 1].append(time)
            } else {
                pieces.append([time])
            }
        }
        let source = Unchecked((built: built, tracks: tracks))
        let ranges = pieces.map { TimeRange(start: $0.first!, end: $0.last!) }
        let byStart = Dictionary(zip(ranges.map(\.start.flicks), pieces), uniquingKeysWith: { a, _ in a })
        let frames = try await FrameScanner.inParallel(ranges, limit: 4) { [self] range in
            try Task.checkCancellation()
            let wanted = byStart[range.start.flicks] ?? []
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try self.readNow(source.value.built, tracks: source.value.tracks, wanted: wanted))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        return frames
    }

    private func annotated(_ value: ReadFrame, with sources: FramePrivacyEvidence.Sources?, at time: Time? = nil) -> ReadFrame {
        var frame = value
        frame.unavailableClipIDs = sources?.unavailable ?? []
        frame.opaqueVideoClipIDs = sources?.opaqueVideos ?? []
        frame.visibleClipIDs = sources?.visible ?? []
        frame.inputCoverage = sources?.regions(frame.lines.map(\.box) + frame.codes) ?? []
        frame.renderedTime = time
        return frame
    }

    private func composition() async throws -> BuiltComposition {
        let task: Task<BuiltComposition, Error> = lock.withLock {
            if let built { return built }
            let context = self.context
            let task = Task { () async throws -> BuiltComposition in
                let (ready, _) = await ConvertedMedia.prepare(context)
                return try await CompositionAssembler.build(ready)
            }
            built = task
            return task
        }
        return try await task.value
    }

    /// Reads from the first of `wanted` to the last, and Vision reads the
    /// frame showing at each.
    private func readNow(_ built: BuiltComposition, tracks: [AVAssetTrack], wanted: [Time]) throws -> [ReadFrame] {
        guard let first = wanted.first, let last = wanted.last else { return [] }
        let rate = context.project.settings.frameRate
        let frame = rate.frameDuration
        func onFrame(_ time: Time) -> Time { Time.frames(time.frameIndex(at: rate), at: rate) }
        let reader = try AVAssetReader(asset: built.composition)
        let recovery = ExportPipeline.readStart(onFrame(first), composition: built.composition, instructions: built.videoComposition.instructions)
        // A held file edge can fall between output frames. Starting there
        // shifts the reader's entire frame grid across cuts and animations.
        let from = max(.zero, onFrame(recovery))
        reader.timeRange = CMTimeRange(start: from.cmTime, end: (last + frame).cmTime)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.videoComposition = built.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RenderError.export("couldn't start reading the timeline") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let held = Unchecked(reader)
        let watch = StallWatch(limit: FrameScanner.stallLimit) { held.value.cancelReading() }
        defer { watch.stop() }
        var frames: [ReadFrame] = []
        var next = 0
        var lastThumbnail: [UInt8]?
        var lastFrame: ReadFrame?
        // Drain this finite range to completion. Cancelling immediately
        // after the last wanted sample forces decoder teardown on every
        // short scan, while its borrowed sample storage is still in use.
        while let sample = output.copyNextSampleBuffer() {
            watch.noteProgress()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            // Release input recipes on skipped output frames too, so a
            // pooled buffer cannot keep decoder inputs until its next use.
            defer { FramePrivacyEvidence.clear(pixels) }
            guard next < wanted.count else { continue }
            let time = Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sample))
            guard time >= onFrame(wanted[next]) else { continue }
            guard time == onFrame(wanted[next]) else { throw RenderError.media("The privacy reader skipped an output frame at \(wanted[next]). Retry the scan.") }
            // The frame showing at each time asked for (one frame can be it
            // for more than one, when the composition holds a frame).
            var image: CGImage?
            let inputEvidence = FramePrivacyEvidence.read(pixels)
            while next < wanted.count, time == onFrame(wanted[next]) {
                if image == nil { image = Self.cgImage(pixels) }
                if let image { frames.append(annotated(read(image, at: wanted[next], last: &lastThumbnail, lastFrame: &lastFrame), with: inputEvidence, at: time)) }
                next += 1
            }
        }
        if watch.stalled {
            throw RenderError.media("AVFoundation stopped handing over frames while reading \(first) to \(last): nothing for \(Int(FrameScanner.stallLimit)) s, so I gave up on it.")
        }
        if reader.status == .failed { throw reader.error ?? RenderError.export("reading the timeline failed") }
        return frames
    }

    static func cgImage(_ pixels: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixels)
        return Self.ciContext.createCGImage(image, from: image.extent)
    }

    nonisolated(unsafe) static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Reads `image`, unless it's the same picture as the last one read.
    func read(_ image: CGImage, at time: Time, last: inout [UInt8]?, lastFrame: inout ReadFrame?) -> ReadFrame {
        let thumbnail = Self.thumbnail(image)
        if !thumbnail.isEmpty, let last, let previous = lastFrame, Self.alike(last, thumbnail) {
            var frame = previous
            frame.time = time
            return frame
        }
        let frame = Self.recognise(image, at: time)
        last = thumbnail
        lastFrame = frame
        lock.withLock { readCount += 1 }
        return frame
    }

    /// Vision's accurate text recognition, without language correction (it
    /// "corrects" emails, codes and keys into words), and its barcodes.
    static func recognise(_ image: CGImage, at time: Time) -> ReadFrame {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        // English only, rather than detecting the language every frame.
        text.automaticallyDetectsLanguage = false
        text.recognitionLanguages = ["en-US"]
        let codes = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([text, codes]) }
        catch { return ReadFrame(time: time, lines: [], recognitionError: error.localizedDescription) }
        // Vision's boxes are from the bottom left.
        func flipped(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height) }
        let lines = (text.results ?? []).compactMap { observation -> ReadLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return ReadLine(text: best.string, box: flipped(observation.boundingBox), confidence: Double(best.confidence))
        }
        let found = (codes.results ?? []).map { flipped($0.boundingBox) }
        return ReadFrame(time: time, lines: lines, codes: found)
    }

    /// Exact rendered pixels. A grey thumbnail can erase a brief line of
    /// private text, so only byte-identical frames may reuse OCR results.
    static func thumbnail(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : []
    }

    /// Only identical rendered pixels may reuse an OCR result.
    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        return a == b
    }
}

/// `tandem check --privacy`: reads every output frame of the video,
/// as export renders it, and finds text a viewer could read that looks
/// private (`PrivateText`), with when and where it shows and the `redact`
/// that hides it. A human sweep of the Threadbear launch video missed a
/// thread's answer listing Mike's projects three times over, readable for
/// 8 s each, and lines scrolling through a strip above a fixed blur.
public enum PrivacyCheck {
    /// Words of text a frame needs before its stretch is worth a look,
    /// private-looking or not.
    public static let readableWords = 40
    /// How sure Vision has to be of a line.
    static let minimumConfidence = 0.3

    /// Reads the frames at some times: `sequential` for many in order (a
    /// pass through the video), otherwise a few, each on its own.
    public typealias Reader = @Sendable (_ times: [Time], _ sequential: Bool) async throws -> [ReadFrame]

    /// Something private on one frame, on the picture of `mediaID` it's
    /// part of, at `rect` (fractions of the file's frame).
    struct Spot {
        var category: PrivateText.Category
        var text: String
        var mediaID: String
        var rect: CGRect
    }

    /// What a frame shows: the spots, and how many words each file shows.
    struct Seen {
        var time: Time
        var spots: [Spot]
        var words: [String: Int]
        var sample: [String: String]
    }

    /// `folder` lets a still with alpha be looked at where text was read
    /// over it (`AlphaProbe`); without it, alpha is taken as see-through.
    /// `format` reads an alternate output format (a Short's 9:16 layout)
    /// in its own frame, through each clip's layout for it; the frames
    /// `read` returns must be rendered in that format too.
    public static func run(
        project: Project, ranges: [TimeRange], folder: ProjectFolder?, format: String? = nil, read: Reader
    ) async throws -> (problems: [CheckProblem], notes: [CheckProblem]) {
        let probe = folder.map(AlphaProbe.init)
        let look = Look(probe: probe, format: format, plan: RenderPlanner.plan(project, format: format, assets: nil))
        let rate = project.settings.frameRate
        let step = rate.frameDuration
        let ranges = TimeRange.union(ranges.map { range in
            let from = max(.zero, Time.frames(range.start.frameIndex(at: rate), at: rate))
            let to = Time.frames((range.end + step - Time(flicks: 1)).frameIndex(at: rate), at: rate)
            return TimeRange(start: from, end: max(from, to))
        })
        var times: [Time] = []
        var segment: [Int] = []
        for (index, range) in ranges.enumerated() {
            var time = Time(flicks: (max(0, range.start.flicks) / rate.flicksPerFrame) * rate.flicksPerFrame)
            while time < range.end {
                times.append(time)
                segment.append(index)
                time += step
            }
        }
        let frames = try await read(times, true)
        guard frames.map(\.time).sorted() == times.sorted() else {
            throw RenderError.media("The privacy scan did not read every requested output frame. No clean result was recorded; retry the scan.")
        }
        if let failure = frames.first(where: { $0.recognitionError != nil }) {
            throw RenderError.media("Text recognition failed at \(failure.time): \(failure.recognitionError!). No clean privacy result was recorded.")
        }
        let seen = frames.map { frame in
            var frameLook = look
            frameLook.unavailableClipIDs = frame.unavailableClipIDs
            frameLook.opaqueVideoClipIDs = frame.opaqueVideoClipIDs
            frameLook.visibleClipIDs = frame.visibleClipIDs
            frameLook.inputCoverage = frame.inputCoverage
            return see(frame, in: project, look: frameLook)
        }
        // Which stretch each frame read is in (a frame that failed to
        // render is missing, so it's by time).
        let stretchOf = Dictionary(zip(times.map(\.flicks), segment), uniquingKeysWith: { first, _ in first })
        let segments = frames.map { stretchOf[$0.time.flicks] ?? 0 }
        var problems: [CheckProblem] = []
        var notes: [CheckProblem] = []

        for mediaID in Set(seen.flatMap { $0.spots.map(\.mediaID) }).sorted() {
            for run in runs(seen, segment: segments, where: { $0.spots.contains { $0.mediaID == mediaID } }) {
                let spots = run.flatMap { seen[$0].spots.filter { $0.mediaID == mediaID } }
                // To the frame each end: where the first one shows, and
                // the frame after the last one does.
                let first = seen[run.first!].time, last = seen[run.last!].time
                problems.append(problem(spots, mediaID: mediaID, range: TimeRange(start: first, end: last + step), project: project))
            }
        }

        // Lots of readable text, to look through whether or not anything
        // in it was flagged: the rules can't know a plan is internal.
        for mediaID in Set(seen.flatMap { $0.words.filter { $0.value >= readableWords }.keys }).sorted() {
            for run in runs(seen, segment: segments, where: { ($0.words[mediaID] ?? 0) >= readableWords }) {
                let start = seen[run.first!].time
                let end = min(seen[run.last!].time + step, ranges[segments[run.last!]].end)
                let most = run.map { seen[$0].words[mediaID] ?? 0 }.max() ?? 0
                let sample = run.compactMap { seen[$0].sample[mediaID] }.max { $0.count < $1.count } ?? ""
                let file = name(of: mediaID, in: project)
                notes.append(CheckProblem(
                    kind: .readableText, start: start, end: end,
                    message: "Readable text on \(file), up to \(most) words a frame (\"\(sample)\"). Look through it for anything private the scan can't know is: an internal plan, someone else's words, names.",
                    clipIDs: clipIDs(of: mediaID, in: TimeRange(start: start, end: end), project: project)
                ))
            }
        }
        return (problems.sorted { $0.start < $1.start }, notes.sorted { $0.start < $1.start })
    }

    /// Runs of consecutive frames, in the same stretch, that `match`.
    static func runs(_ seen: [Seen], segment: [Int], where match: (Seen) -> Bool) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for index in seen.indices {
            if match(seen[index]), current.last.map({ $0 == index - 1 && segment[$0] == segment[index] }) ?? true {
                current.append(index)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = match(seen[index]) ? [index] : []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func problem(_ spots: [Spot], mediaID: String, range: TimeRange, project: Project) -> CheckProblem {
        var byCategory: [(PrivateText.Category, [String])] = []
        for spot in spots {
            if let index = byCategory.firstIndex(where: { $0.0 == spot.category }) {
                if !byCategory[index].1.contains(spot.text) { byCategory[index].1.append(spot.text) }
            } else {
                byCategory.append((spot.category, [spot.text]))
            }
        }
        let found = byCategory.map { category, texts in
            let quoted = texts.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
            return "\(category.label) (\(quoted)\(texts.count > 3 ? " and \(texts.count - 3) more" : ""))"
        }.joined(separator: "; ")
        // Round everything flagged, with a little room: the lines round it
        // are often as private, so look at a frame and widen it.
        let union = spots.map(\.rect).reduce(spots[0].rect) { $0.union($1) }.insetBy(dx: -0.01, dy: -0.01)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = Rect(x: union.minX, y: union.minY, width: union.width, height: union.height)
        let file = name(of: mediaID, in: project)
        let unknownSource = project.media(mediaID) == nil
        let duringTransition = project.videoTracks.contains { track in
            track.transitions.contains { transition in
                transition.window(on: track)?.overlaps(range) == true
            }
        }
        let fix: EditCommand? = duringTransition || unknownSource ? nil : .redact(range: range, rect: rect, mediaID: mediaID, style: .blur, name: "private text")
        let message = unknownSource
            ? "Private text in the rendered frame: \(found). Its source could not be identified; inspect this frame before exporting."
            : duringTransition
            ? "Private text during a transition involving \(file): \(found). Inspect every contributing picture; the mixed frame cannot identify a single source for an automatic redaction."
            : "Private text on \(file): \(found). Look at a frame, then hide it (the redact below covers what was flagged; widen it to anything private round it)."
        return CheckProblem(
            kind: .privateText, start: range.start, end: range.end,
            message: message,
            clipIDs: clipIDs(of: mediaID, in: range, project: project), fix: fix
        )
    }

    // MARK: - One frame

    /// The private spots on a frame, and the words each picture shows.
    static func see(_ frame: ReadFrame, in project: Project, look: Look = Look()) -> Seen {
        var seen = Seen(time: frame.time, spots: [], words: [:], sample: [:])
        let renderedTime = frame.renderedTime ?? frame.time
        var linesBy: [String: [(line: ReadLine, rect: CGRect)]] = [:]
        for line in frame.lines where line.confidence >= minimumConfidence {
            let candidates = sources(of: line.box, text: line.text, at: renderedTime, in: project, look: look)
            // Authored text cannot prove where OCR's glyphs came from: a
            // title's transparent padding can sit over private footage.
            // Keep recognised private-looking text for review either way.
            if candidates.isEmpty {
                linesBy["unattributed", default: []].append((line, line.box))
                for hit in PrivateText.hits(in: line.text) {
                    seen.spots.append(Spot(category: hit.category, text: hit.text, mediaID: "unattributed", rect: line.box))
                }
            }
            for source in candidates {
                linesBy[source.mediaID, default: []].append((line, source.rect))
                for hit in PrivateText.hits(in: line.text) {
                    seen.spots.append(Spot(category: hit.category, text: hit.text, mediaID: source.mediaID, rect: source.rect))
                }
            }
        }
        for box in frame.codes {
            let candidates = sources(of: box, text: nil, at: renderedTime, in: project, look: look)
            if candidates.isEmpty { seen.spots.append(Spot(category: .code, text: "QR code", mediaID: "unattributed", rect: box)) }
            for source in candidates {
                seen.spots.append(Spot(category: .code, text: "QR code", mediaID: source.mediaID, rect: source.rect))
            }
        }
        for (mediaID, lines) in linesBy {
            // A line and the one under it, read as one: a narrow card wraps
            // "Collect the keys at 12" above "Harbour Rise", and neither
            // line alone is an address. Only what the pair adds counts.
            let frame = look.canvas(project)
            let aspect = Double(frame.width) / Double(max(frame.height, 1))
            for (upper, lower) in wrapped(lines.map(\.line), aspect: aspect) {
                // Only what neither line has alone: "12 Bank" over "Road" is
                // a new address even though "Bank" alone was money.
                let alone = PrivateText.hits(in: upper.text) + PrivateText.hits(in: lower.text)
                for hit in PrivateText.hits(in: upper.text + " " + lower.text) where !alone.contains(hit) {
                    let rects = lines.filter { $0.line == upper || $0.line == lower }.map(\.rect)
                    seen.spots.append(Spot(category: hit.category, text: hit.text, mediaID: mediaID, rect: rects.dropFirst().reduce(rects[0]) { $0.union($1) }))
                }
            }
            seen.words[mediaID] = lines.reduce(0) { $0 + $1.line.text.split(separator: " ").count }
            seen.sample[mediaID] = String(lines.map(\.line.text).joined(separator: " / ").prefix(80))
            let named = names(in: lines.map(\.line.text))
            if named.count >= 3 {
                let rects = lines.filter { line in named.contains { line.line.text.contains($0) } }.map(\.rect)
                let rect = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
                seen.spots.append(Spot(category: .names, text: named.prefix(4).joined(separator: ", "), mediaID: mediaID, rect: rect))
            }
        }
        return seen
    }

    /// Pairs of lines where the second sits right under the first, starting
    /// about where it starts: one paragraph wrapped. `aspect` is the frame's
    /// width over its height, so the starts are compared in line heights
    /// whatever the frame's shape.
    static func wrapped(_ lines: [ReadLine], aspect: Double = 16.0 / 9) -> [(ReadLine, ReadLine)] {
        var pairs: [(ReadLine, ReadLine)] = []
        for upper in lines {
            let below = lines.filter { lower in
                let gap = lower.box.minY - upper.box.maxY
                return lower != upper && gap > -upper.box.height * 0.3 && gap < upper.box.height * 1.2
                    && abs(lower.box.minX - upper.box.minX) * aspect < max(upper.box.height, 0.01) * 2
            }
            if let lower = below.min(by: { $0.box.minY < $1.box.minY }) { pairs.append((upper, lower)) }
        }
        return pairs
    }

    /// The people's names in some lines, each once.
    static func names(in lines: [String]) -> [String] {
        // Each line a sentence of its own: joined by line breaks, the tagger
        // reads a column of names as one run of words and finds none.
        let text = lines.joined(separator: ". ")
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = String(text[range])
            // A full name, not a lone word that might be a product.
            if tag == .personalName, name.contains(" "), !found.contains(name) { found.append(name) }
            return true
        }
        return found
    }

    static func authored(_ clip: Clip, content: TextContent, text: String, box: CGRect, at time: Time, canvas: CGSize, format: String?) -> Bool {
        let resolved = ResolvedText(content)
        guard resolved.text.caseInsensitiveCompare(text) == .orderedSame,
              resolved.style.color.a >= 0.999,
              var video = clip.resolvedVideo(at: time - clip.start, format: format), video.effects.isEmpty else { return false }
        let state = TextAnimationState.at(time - clip.start, clipDuration: clip.duration, text: resolved)
        guard state.opacity * video.opacity >= 0.999, state.visibleFraction >= 1,
              let image = FrameComposer.textImage(resolved, clipTime: time - clip.start, state: state, renderScale: 1, staticScale: clip.video?.transform.scale ?? 1, canvas: canvas) else { return false }
        if clip.video == nil, let position = resolved.position { video.transform.position = position }
        video.transform.scale *= state.scale
        video.transform.position.y += state.offsetY
        let placed = LayerMath.placement(source: image.extent.size, canvas: canvas, transform: video.transform, fitToCanvas: false)
        let bounds = LayerMath.cropRect(source: image.extent.size, crop: video.crop)
        let readBox = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
        guard !bounds.isEmpty, abs(placed.a * placed.d - placed.b * placed.c) > 1e-9 else { return false }
        let inverse = placed.inverted()
        return [CGPoint(x: readBox.minX, y: readBox.minY), CGPoint(x: readBox.maxX, y: readBox.minY),
                CGPoint(x: readBox.minX, y: readBox.maxY), CGPoint(x: readBox.maxX, y: readBox.maxY)]
            .allSatisfy { bounds.insetBy(dx: -2, dy: -2).contains($0.applying(inverse)) }
    }

    // Built-in grades keep coordinates and alpha; the crop-clamped utility
    // filters keep an opaque picture opaque, but can mix a still's alpha.
    static let grades: Set<String> = ["colorAdjust", "hsl", "colorWheels", "vignette", "sharpen", "lut"]
    static let boundedEffects = grades.union(["blur", "pixelate"])

    /// Effects can supply glyphs outside an ordinary layer rectangle. Use
    /// the renderer's shadow extent; other unknown coverage stays uncertain.
    static func possibleBounds(_ bounds: CGRect, effects: [Effect], canvas: CGSize) -> CGRect? {
        guard !bounds.isEmpty else { return bounds }
        var result = bounds
        for effect in effects where effect.enabled && !boundedEffects.contains(effect.type) {
            guard effect.type == "dropShadow", let definition = EffectRegistry.standard.definition(effect.type) else { return nil }
            let params = definition.resolvedParams(effect)
            let unit = LayerMath.pixelScale(canvas: canvas)
            let input = CIImage(color: .white).cropped(to: bounds)
            let shadow = EffectRenderer.dropShadow(input, distance: CGFloat(params["distance"]?.number ?? 0) * unit,
                angle: params["angle"]?.number ?? 135, blur: CGFloat(params["blur"]?.number ?? 0) * unit,
                opacity: (params["opacity"]?.number ?? 0) / 100, color: .black).extent
            guard !shadow.isInfinite, !shadow.isNull else { return nil }
            // Symmetric margins cover both Core Image and top-left axes.
            let margin = [0, bounds.minX - shadow.minX, shadow.maxX - bounds.maxX, bounds.minY - shadow.minY, shadow.maxY - bounds.maxY].max()!
            result = result.insetBy(dx: -margin, dy: -margin)
        }
        return result
    }

    static func titleOverlaps(_ clip: Clip, content: TextContent, box: CGRect, at time: Time, canvas: CGSize, format: String?) -> Bool {
        let text = ResolvedText(content)
        let state = TextAnimationState.at(time - clip.start, clipDuration: clip.duration, text: text)
        let visibleInk = text.style.color.a > 0 || (text.style.hasOutline && (text.style.strokeColor?.a ?? 0) > 0)
            || (text.style.backgroundColor?.a ?? 0) > 0 || (text.highlightColor?.a ?? 0) > 0 || (text.firstLineColor?.a ?? 0) > 0
        guard var video = clip.resolvedVideo(at: time - clip.start, format: format),
              state.opacity * video.opacity > 0, visibleInk, state.visibleFraction > 0,
              let image = FrameComposer.textImage(text, clipTime: time - clip.start, state: state, renderScale: 1, staticScale: clip.video?.transform.scale ?? 1, canvas: canvas) else { return false }
        let crop = LayerMath.cropRect(source: image.extent.size, crop: video.crop)
        guard !crop.isEmpty else { return false }
        if clip.video == nil, let position = text.position { video.transform.position = position }
        video.transform.scale *= state.scale
        video.transform.position.y += state.offsetY
        let placement = LayerMath.placement(source: image.extent.size, canvas: canvas, transform: video.transform, fitToCanvas: false)
        guard let visible = possibleBounds(crop.applying(placement), effects: video.effects, canvas: canvas) else { return true }
        let pixels = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
        return !visible.isEmpty && visible.intersects(pixels)
    }

    /// During a mix, OCR alone cannot name which contributor supplied a
    /// glyph. Retain all plausible contributors, including extended handles,
    /// and don't offer a source-specific automatic fix for the mixed frame.
    static func sources(of box: CGRect, text: String?, at time: Time, in p: Project, look: Look) -> [(mediaID: String, rect: CGRect)] {
        let plan = look.plan ?? RenderPlanner.plan(p, format: look.format, assets: nil)
        guard let instruction = plan.instructions.first(where: { $0.range.contains(time) }),
              instruction.stack.contains(where: { if case .transition = $0 { return true }; return false }) else {
            return source(of: box, text: text, at: time, in: p, look: look).map { [$0] } ?? []
        }
        let canvas = look.canvas(p)
        let pixels = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
        func layers(_ node: StackNode, outer: CGAffineTransform = .identity) -> [(LayerRef, CGAffineTransform)] {
            switch node {
            case .layer(let ref): return [(ref, outer)]
            case .transition(let ref, let from, let to):
                let progress = min(1, max(0, (time - ref.window.start).seconds / max(1e-9, ref.window.duration.seconds)))
                let type = ref.transition.type
                let offsets = TransitionRenderer.offsets(type, direction: ref.transition.direction, progress: progress)
                func side(_ node: StackNode?, incoming: Bool) -> [(LayerRef, CGAffineTransform)] {
                    guard let node else { return [] }
                    if type == .dissolve, incoming ? progress <= 0 : progress >= 1 { return [] }
                    if type == .fadeToBlack || type == .fadeFromBlack {
                        let levels = TransitionRenderer.dipLevels(progress: progress, hasFrom: from != nil, hasTo: to != nil)
                        if (incoming ? levels.to : levels.from) <= 0 { return [] }
                    }
                    var motion = CGAffineTransform.identity
                    if type == .push || type == .slide || type == .cutSlide {
                        let offset = incoming ? offsets.to : offsets.from
                        motion = CGAffineTransform(translationX: offset.dx * canvas.width, y: offset.dy * canvas.height)
                    } else if type == .zoom {
                        let e = TransitionRenderer.eased(type, progress)
                        let scale = CGFloat(incoming ? 2 - e : 1 + e)
                        motion = CGAffineTransform(translationX: -canvas.width / 2, y: -canvas.height / 2)
                            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                            .concatenating(CGAffineTransform(translationX: canvas.width / 2, y: canvas.height / 2))
                    }
                    return layers(node, outer: motion.concatenating(outer))
                }
                return side(from, incoming: false) + side(to, incoming: true)
            }
        }
        var found: [(mediaID: String, rect: CGRect)] = []
        for node in instruction.stack {
            for (ref, motion) in layers(node) {
                guard !look.unavailableClipIDs.contains(ref.clipID), let clip = p.clip(ref.clipID), let id = clip.mediaID,
                      let item = p.media(id), let width = item.width, let height = item.height,
                      let video = clip.resolvedVideo(at: time - clip.start, format: look.format), video.opacity > 0 else { continue }
                let size = CGSize(width: width, height: height)
                let placement = LayerMath.placement(source: size, canvas: canvas, transform: video.transform).concatenating(motion)
                guard abs(placement.a * placement.d - placement.b * placement.c) > 1e-9 else { continue }
                let mapped = pixels.applying(placement.inverted()).intersection(LayerMath.cropRect(source: size, crop: video.crop))
                guard !mapped.isNull, !mapped.isEmpty else { continue }
                let region = CGRect(x: mapped.minX / size.width, y: mapped.minY / size.height, width: mapped.width / size.width, height: mapped.height / size.height)
                found.append((id, region))
            }
        }
        return found
    }

    /// The picture a box of text read on the frame at `time` is part of: the
    /// file on top there (under any frame with alpha round it), and where
    /// in its frame the box is. Nil for a title or caption Tandem draws
    /// (Mike wrote those), or a box over nothing.
    static func source(of box: CGRect, text: String?, at time: Time, in project: Project, look: Look = Look()) -> (mediaID: String, rect: CGRect)? {
        attribution(of: box, text: text, at: time, in: project, look: look).source
    }

    /// A title only exempts OCR when no higher contributor can supply the
    /// glyphs. A picture whose bounds are unknown is uncertainty, never
    /// evidence that the title below it was visible.
    static func attribution(of box: CGRect, text: String?, at time: Time, in project: Project, look: Look) -> (source: (mediaID: String, rect: CGRect)?, authored: Bool) {
        let canvas = look.canvas(project)
        func overlaps(_ video: VideoProperties) -> Bool {
            guard video.opacity > 0 else { return false }
            let placement = LayerMath.placement(source: canvas, canvas: canvas, transform: video.transform)
            let base = LayerMath.cropRect(source: canvas, crop: video.crop).applying(placement)
            guard let shown = possibleBounds(base, effects: video.effects, canvas: canvas) else { return true }
            let pixels = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
            return !shown.isEmpty && shown.intersects(pixels)
        }
        // A picture with alpha over the text (a phone frame round a phone
        // recording, a camera cut out over the screen) is usually
        // see-through there: the text is in what's
        // under it, if anything is.
        var seeThrough: (mediaID: String, rect: CGRect)?
        let plan = look.plan ?? RenderPlanner.plan(project, format: look.format, assets: nil)
        let layers = plan.instructions.first { $0.range.contains(time) }?.stack.flatMap(\.layers) ?? []
        for ref in layers.reversed() {
            guard !look.unavailableClipIDs.contains(ref.clipID), project.videoTracks.indices.contains(ref.trackIndex), let clip = project.clip(ref.clipID) else { continue }
            let track = project.videoTracks[ref.trackIndex]
            switch clip.content {
            case .text(let content):
                // A caption or a title: its own words are Mike's. Only a
                // line that's part of its text, so a caption reading "email"
                // doesn't hide "Email: someone@example.com" elsewhere.
                if let text, authored(clip, content: content, text: text, box: box, at: time, canvas: canvas, format: look.format) {
                    return (nil, seeThrough == nil)
                }
                if titleOverlaps(clip, content: content, box: box, at: time, canvas: canvas, format: look.format) { return (nil, false) }
            case .graphic(let graphic):
                // Generated graphics can obscure a lower title. Without
                // pixel attribution, retain the OCR as unattributed text.
                if BuiltInGraphics.renders(graphic.template), let video = clip.resolvedVideo(at: time - clip.start, format: look.format), overlaps(video) { return (nil, false) }
            case .solid(let color):
                if color.a > 0, let video = clip.resolvedVideo(at: time - clip.start, format: look.format), overlaps(video) { return (nil, false) }
            case .adjustment:
                // Grades preserve source coordinates. Spatial/custom filters
                // can move glyphs even though they supply no separate image.
                if let video = clip.resolvedVideo(at: time - clip.start, format: look.format), video.opacity > 0,
                   video.effects.contains(where: { $0.enabled && !grades.contains($0.type) }) { return (nil, false) }
                continue
            case .media(let mediaID):
                // Read through a blur, it isn't readable; and the copy under
                // it is the same file anyway. A privacy copy with its blur
                // off isn't drawn.
                guard !track.isSwitchedOffRedaction(clip), let item = project.media(mediaID), item.hasVideo || item.kind == .image else { continue }
                let measured = look.inputCoverage.first { $0.box == box }?.clips[clip.id]
                if let measured {
                    switch measured.opacity {
                    case .transparent: continue
                    case .opaque:
                        guard measured.coordinatesKnown, seeThrough == nil else { return (nil, false) }
                    case .mixed:
                        guard measured.coordinatesKnown else { return (nil, false) }
                    case .unknown: return (nil, false)
                    }
                }
                // The format's own layout where it has one (a Short's top window).
                guard let video = clip.resolvedVideo(at: time - clip.start, format: look.format), video.opacity > 0 else { continue }
                let available: Bool? = measured == nil && item.kind == .image ? look.probe?.imageAvailable(item) : true
                if available == false { continue }
                guard let width = item.width, let height = item.height, width > 0, height > 0 else { return (nil, false) }
                let display = CGSize(width: width, height: height)
                let placement = LayerMath.placement(source: display, canvas: canvas, transform: video.transform)
                let shown = LayerMath.cropRect(source: display, crop: video.crop)
                guard shown.width > 0, shown.height > 0, abs(placement.a * placement.d - placement.b * placement.c) > 1e-9 else { continue }
                let pixels = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
                let effects = video.effects + item.look
                let altered = effects.contains { $0.enabled && !boundedEffects.contains($0.type) }
                if altered {
                    guard let possible = possibleBounds(shown.applying(placement), effects: effects, canvas: canvas) else { return (nil, false) }
                    if possible.intersects(pixels) { return (nil, false) }
                }
                let inFile = pixels.applying(placement.inverted()).intersection(shown)
                guard !inFile.isNull, !inFile.isEmpty else {
                    // Resampling can contribute outside the geometric crop.
                    // Actual overlapping pixels prevent a lower-source guess.
                    if measured != nil { return (nil, false) }
                    continue
                }
                if available == nil || !look.visibleClipIDs.contains(clip.id) { return (nil, false) }
                let found = (mediaID, CGRect(x: inFile.minX / display.width, y: inFile.minY / display.height, width: inFile.width / display.width, height: inFile.height / display.height))
                let inverse = placement.inverted()
                let radius = FramePrivacyEvidence.samplingRadius
                let opaqueInterior = shown.insetBy(dx: radius, dy: radius)
                let entireLine = !opaqueInterior.isEmpty && [CGPoint(x: pixels.minX, y: pixels.minY), CGPoint(x: pixels.maxX, y: pixels.minY),
                                  CGPoint(x: pixels.minX, y: pixels.maxY), CGPoint(x: pixels.maxX, y: pixels.maxY)]
                    .allSatisfy { opaqueInterior.contains($0.applying(inverse)) }
                if measured?.opacity == .opaque {
                    return (entireLine ? found : nil, false)
                }
                if measured?.opacity == .mixed {
                    // A known opaque format through our bounded Lanczos
                    // sampler also proves its interior independently of
                    // floating-point alpha roundoff. Never apply a numeric
                    // tolerance to an alpha video or a translucent layer.
                    let interiorProven = item.kind != .image && !item.hasAlpha
                        && look.opaqueVideoClipIDs.contains(clip.id) && video.opacity == 1
                        && video.cutout?.enabled != true && !altered
                    return (interiorProven && entireLine && seeThrough == nil ? found : nil, false)
                }
                // A camera cut out over the screen is see-through round the
                // person, like a frame with alpha.
                if item.kind == .image || item.hasAlpha || !look.opaqueVideoClipIDs.contains(clip.id) || video.cutout?.enabled == true || video.opacity < 1 || altered {
                    // A still is looked at where the text is: an opaque card
                    // with alpha round it holds its own text.
                    if video.opacity >= 1, video.cutout?.enabled != true, !effects.contains(where: { $0.enabled && !grades.contains($0.type) }) {
                        let support = found.1.insetBy(dx: -radius / display.width, dy: -radius / display.height)
                        switch look.probe?.coverage(item, in: support) {
                        case .transparent: continue
                        case .opaque: return (entireLine && seeThrough == nil ? found : nil, false)
                        default: break
                        }
                    }
                    if seeThrough == nil { seeThrough = found }
                    continue
                }
                return (entireLine && seeThrough == nil ? found : nil, false)
            }
        }
        return (nil, false)
    }

    static func name(of mediaID: String, in project: Project) -> String {
        project.media(mediaID).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? mediaID
    }

    /// The clips of `mediaID` there, not the privacy copies over them.
    static func clipIDs(of mediaID: String, in range: TimeRange, project: Project) -> [String] {
        project.videoTracks.flatMap(\.clips).filter { !$0.isRedaction && $0.mediaID == mediaID && $0.range.overlaps(range) }.map(\.id)
    }
}

/// How a frame is looked at: in which output format (nil for the main
/// one), and with what to read a still's alpha.
struct Look {
    var probe: AlphaProbe?
    var format: String?
    var plan: RenderPlan?
    var unavailableClipIDs: Set<String> = []
    var opaqueVideoClipIDs: Set<String>
    var visibleClipIDs: Set<String>
    var inputCoverage: [FramePrivacyEvidence.Region] = []

    init(probe: AlphaProbe? = nil, format: String? = nil, plan: RenderPlan? = nil, opaqueVideoClipIDs: Set<String> = [], visibleClipIDs: Set<String> = []) {
        self.probe = probe
        self.format = format
        self.plan = plan
        self.opaqueVideoClipIDs = opaqueVideoClipIDs
        self.visibleClipIDs = visibleClipIDs
    }

    /// The frame the text was read in: the format's, or the project's.
    func canvas(_ project: Project) -> CGSize {
        if let format, let alt = project.settings.alternateFormats.first(where: { $0.id == format }) {
            return CGSize(width: alt.width, height: alt.height)
        }
        return CGSize(width: project.settings.width, height: project.settings.height)
    }
}

/// Whether a still with alpha covers the complete OCR region, read once
/// (`PrivacyCheck.source`). Nil for a video with alpha, which isn't read.
final class AlphaProbe: @unchecked Sendable {
    enum Coverage { case opaque, transparent, mixed }
    let folder: ProjectFolder
    private let lock = NSLock()
    private var images: [String: CGImage?] = [:]
    private var available: [String: Bool] = [:]

    init(folder: ProjectFolder) { self.folder = folder }

    func imageAvailable(_ item: MediaItem) -> Bool {
        lock.withLock {
            if let cached = available[item.id] { return cached }
            let found = ImageCache.shared.image(at: folder.url(for: item)) != nil
            available[item.id] = found
            return found
        }
    }

    /// `rect` is in fractions of the picture from its top left. A centre
    /// pixel cannot establish which picture supplied the rest of a line.
    func coverage(_ item: MediaItem, in rect: CGRect) -> Coverage? {
        guard item.kind == .image else { return nil }
        let image: CGImage? = lock.withLock {
            if let cached = images[item.id] { return cached }
            let url = folder.url(for: item)
            // Turned the way it's shown (EXIF orientation), as the render
            // draws it: a phone photo is stored on its side.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil), raw.bitsPerComponent <= 8,
                  max(raw.width, raw.height) <= 4096 else {
                images[item.id] = .some(nil)
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(raw.width, raw.height)
            ]
            let loaded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            images[item.id] = .some(loaded)
            return loaded
        }
        guard let image else { return nil }
        let pixels = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                            width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !pixels.isEmpty, let crop = image.cropping(to: pixels) else { return nil }
        let width = crop.width, height = crop.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard drawn else { return nil }
        let alpha = stride(from: 3, to: rgba.count, by: 4)
        if alpha.allSatisfy({ rgba[$0] == 255 }) { return .opaque }
        if alpha.allSatisfy({ rgba[$0] == 0 }) { return .transparent }
        return .mixed
    }
}
