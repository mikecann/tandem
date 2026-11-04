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

    public init(time: Time, lines: [ReadLine], codes: [CGRect] = []) {
        self.time = time
        self.lines = lines
        self.codes = codes
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
        let canvas = context.renderSize
        let height = Int((Double(width) * canvas.height / max(canvas.width, 1)).rounded())
        size = CGSize(width: width, height: max(2, height))
        context.sizeOverride = size
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
                frames.append(read(image, at: time, last: &last, lastFrame: &lastFrame))
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
        return try await FrameScanner.inParallel(ranges, limit: 4) { [self] range in
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
        let frame = context.project.settings.frameRate.frameDuration
        let reader = try AVAssetReader(asset: built.composition)
        let from = ExportPipeline.readStart(first, composition: built.composition, instructions: built.videoComposition.instructions)
        reader.timeRange = CMTimeRange(start: from.cmTime, end: (last + frame).cmTime)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
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
        let slack = Time(flicks: frame.flicks / 2)
        while next < wanted.count, let sample = output.copyNextSampleBuffer() {
            watch.noteProgress()
            let time = Time(cmTime: CMSampleBufferGetPresentationTimeStamp(sample))
            guard time + slack >= wanted[next], let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            // The frame showing at each time asked for (one frame can be it
            // for more than one, when the composition holds a frame).
            var image: CGImage?
            while next < wanted.count, time + slack >= wanted[next] {
                if image == nil { image = Self.cgImage(pixels) }
                if let image { frames.append(read(image, at: wanted[next], last: &lastThumbnail, lastFrame: &lastFrame)) }
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
        if let last, let previous = lastFrame, Self.alike(last, thumbnail) {
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
        try? handler.perform([text, codes])
        // Vision's boxes are from the bottom left.
        func flipped(_ box: CGRect) -> CGRect { CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height) }
        let lines = (text.results ?? []).compactMap { observation -> ReadLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return ReadLine(text: best.string, box: flipped(observation.boundingBox), confidence: Double(best.confidence))
        }
        let found = (codes.results ?? []).map { flipped($0.boundingBox) }
        return ReadFrame(time: time, lines: lines, codes: found)
    }

    /// A 64 by 36 grey thumbnail, to tell a frame that's changed.
    static func thumbnail(_ image: CGImage) -> [UInt8] {
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Whether two thumbnails are the same picture: no pixel more than a
    /// little off. A line of text scrolling in moves far more than that.
    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
    }
}

/// `tandem check --privacy`: reads the video's frames (every half second,
/// as export renders them) and finds text a viewer could read that looks
/// private (`PrivateText`), with when and where it shows and the `redact`
/// that hides it. A human sweep of the Threadbear launch video missed a
/// thread's answer listing Mike's projects three times over, readable for
/// 8 s each, and lines scrolling through a strip above a fixed blur.
public enum PrivacyCheck {
    /// How often a frame is read. Edges are then found to the frame.
    public static let step = Time(seconds: 0.5)
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
    public static func run(project: Project, ranges: [TimeRange], folder: ProjectFolder?, read: Reader) async throws -> (problems: [CheckProblem], notes: [CheckProblem]) {
        let probe = folder.map(AlphaProbe.init)
        let rate = project.settings.frameRate
        var times: [Time] = []
        var segment: [Int] = []
        for (index, range) in ranges.enumerated() {
            var time = range.start.roundedToFrame(rate)
            while time < range.end {
                times.append(time)
                segment.append(index)
                time = (time + step).roundedToFrame(rate)
            }
        }
        let frames = try await read(times, true)
        let seen = frames.map { see($0, in: project, probe: probe) }
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
                let range = ranges[segments[run.first!]]
                let before = first - step, after = last + step
                let start = try await edge(
                    from: max(range.start, before), to: first, mediaID: mediaID, rising: true, unread: before < range.start, project: project, probe: probe, read: read
                )
                let lastShown = try await edge(
                    from: last, to: min(range.end - rate.frameDuration, after), mediaID: mediaID, rising: false,
                    unread: after > range.end - rate.frameDuration, project: project, probe: probe, read: read
                )
                problems.append(problem(spots, mediaID: mediaID, range: TimeRange(start: start, end: lastShown + rate.frameDuration), project: project))
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

    /// The frame where `mediaID`'s private text starts showing (`rising`:
    /// the first with it, between `from`, without, and `to`, with) or stops
    /// (the last with it, between `from`, with, and `to`), found by halves.
    /// `unread`: the far end is the stretch's edge rather than a frame read
    /// without it, so it's read first.
    static func edge(from: Time, to: Time, mediaID: String, rising: Bool, unread: Bool, project: Project, probe: AlphaProbe?, read: Reader) async throws -> Time {
        let frame = project.settings.frameRate.frameDuration
        var without = rising ? from : to, with = rising ? to : from
        func shows(_ time: Time) async throws -> Bool {
            guard let frame = try await read([time], false).first else { return false }
            return see(frame, in: project, probe: probe).spots.contains { $0.mediaID == mediaID }
        }
        guard without != with else { return with }
        if unread, try await shows(without) { return without }
        while abs((with - without).flicks) > frame.flicks {
            let middle = Time(flicks: (with.flicks + without.flicks) / 2).roundedToFrame(project.settings.frameRate)
            guard middle != with, middle != without else { break }
            if try await shows(middle) { with = middle } else { without = middle }
        }
        return with
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
        let fix = EditCommand.redact(range: range, rect: rect, mediaID: mediaID, style: .blur, name: "private text")
        return CheckProblem(
            kind: .privateText, start: range.start, end: range.end,
            message: "Private text on \(file): \(found). Look at a frame, then hide it (the redact below covers what was flagged; widen it to anything private round it).",
            clipIDs: clipIDs(of: mediaID, in: range, project: project), fix: fix
        )
    }

    // MARK: - One frame

    /// The private spots on a frame, and the words each picture shows.
    static func see(_ frame: ReadFrame, in project: Project, probe: AlphaProbe? = nil) -> Seen {
        var seen = Seen(time: frame.time, spots: [], words: [:], sample: [:])
        var linesBy: [String: [(line: ReadLine, rect: CGRect)]] = [:]
        for line in frame.lines where line.confidence >= minimumConfidence {
            guard let source = source(of: line.box, text: line.text, at: frame.time, in: project, probe: probe) else { continue }
            linesBy[source.mediaID, default: []].append((line, source.rect))
            for hit in PrivateText.hits(in: line.text) {
                seen.spots.append(Spot(category: hit.category, text: hit.text, mediaID: source.mediaID, rect: source.rect))
            }
        }
        for box in frame.codes {
            guard let source = source(of: box, text: nil, at: frame.time, in: project, probe: probe) else { continue }
            seen.spots.append(Spot(category: .code, text: "QR code", mediaID: source.mediaID, rect: source.rect))
        }
        for (mediaID, lines) in linesBy {
            // A line and the one under it, read as one: a narrow card wraps
            // "Collect the keys at 12" above "Harbour Rise", and neither
            // line alone is an address. Only what the pair adds counts.
            let aspect = Double(project.settings.width) / Double(max(project.settings.height, 1))
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

    /// The picture a box of text read on the frame at `time` is part of: the
    /// file on top there (under any frame with alpha round it), and where
    /// in its frame the box is. Nil for a title or caption Tandem draws
    /// (Mike wrote those), or a box over nothing.
    static func source(of box: CGRect, text: String?, at time: Time, in project: Project, probe: AlphaProbe? = nil) -> (mediaID: String, rect: CGRect)? {
        let canvas = CGSize(width: project.settings.width, height: project.settings.height)
        let centre = CGPoint(x: box.midX * canvas.width, y: box.midY * canvas.height)
        // A picture with alpha over the text (a phone frame round a phone
        // recording, a camera cut out over the screen) is usually
        // see-through there: the text is in what's
        // under it, if anything is.
        var seeThrough: (mediaID: String, rect: CGRect)?
        for track in project.videoTracks.reversed() where !track.hidden {
            guard let clip = track.clip(at: time), clip.enabled else { continue }
            switch clip.content {
            case .text(let content):
                // A caption or a title: its own words are Mike's. Only a
                // line that's part of its text, so a caption reading "email"
                // doesn't hide "Email: someone@example.com" elsewhere.
                if let text, content.text.localizedCaseInsensitiveContains(text) { return nil }
            case .graphic:
                // A section card's wipe covers part of the frame, and what
                // shows round it is still the picture under it.
                continue
            case .solid, .adjustment:
                continue
            case .media(let mediaID):
                // Read through a blur, it isn't readable; and the copy under
                // it is the same file anyway.
                guard !clip.isObscured, let item = project.media(mediaID), item.hasVideo,
                      let width = item.width, let height = item.height, width > 0, height > 0 else { continue }
                let video = clip.resolvedVideo(at: time - clip.start)
                let display = CGSize(width: width, height: height)
                let placement = LayerMath.placement(source: display, canvas: canvas, transform: video.transform)
                let crop = video.crop
                let shown = CGRect(
                    x: crop.left * display.width, y: crop.top * display.height,
                    width: (1 - crop.left - crop.right) * display.width, height: (1 - crop.top - crop.bottom) * display.height
                )
                guard shown.width > 0, shown.height > 0, video.opacity > 0.05, shown.applying(placement).contains(centre) else { continue }
                let pixels = CGRect(x: box.minX * canvas.width, y: box.minY * canvas.height, width: box.width * canvas.width, height: box.height * canvas.height)
                let inFile = pixels.applying(placement.inverted()).intersection(shown)
                guard !inFile.isNull else { continue }
                let found = (mediaID, CGRect(x: inFile.minX / display.width, y: inFile.minY / display.height, width: inFile.width / display.width, height: inFile.height / display.height))
                // A camera cut out over the screen is see-through round the
                // person, like a frame with alpha.
                if item.hasAlpha || video.cutout?.enabled == true {
                    // A still is looked at where the text is: an opaque card
                    // with alpha round it holds its own text.
                    let centre = CGPoint(x: found.1.midX, y: found.1.midY)
                    if video.cutout?.enabled != true, let opaque = probe?.isOpaque(item, at: centre), opaque { return found }
                    if seeThrough == nil { seeThrough = found }
                    continue
                }
                return found
            }
        }
        return seeThrough
    }

    static func name(of mediaID: String, in project: Project) -> String {
        project.media(mediaID).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? mediaID
    }

    static func clipIDs(of mediaID: String, in range: TimeRange, project: Project) -> [String] {
        project.videoTracks.flatMap(\.clips).filter { $0.mediaID == mediaID && !$0.isObscured && $0.range.overlaps(range) }.map(\.id)
    }
}

/// Whether a still with alpha is opaque at a point, read from the file once
/// (`PrivacyCheck.source`). Nil for a video with alpha, which isn't read.
final class AlphaProbe: @unchecked Sendable {
    let folder: ProjectFolder
    private let lock = NSLock()
    private var images: [String: CGImage?] = [:]

    init(folder: ProjectFolder) { self.folder = folder }

    /// `point` is in fractions of the picture from its top left.
    func isOpaque(_ item: MediaItem, at point: CGPoint) -> Bool? {
        guard item.kind == .image else { return nil }
        let image: CGImage? = lock.withLock {
            if let cached = images[item.id] { return cached }
            let url = folder.url(for: item)
            // Turned the way it's shown (EXIF orientation), as the render
            // draws it: a phone photo is stored on its side.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ]
            let loaded = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            images[item.id] = loaded
            return loaded
        }
        guard let image else { return nil }
        // Draw the picture so the one pixel wanted lands on a 1 by 1 context.
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            let x = point.x * CGFloat(image.width), y = (1 - point.y) * CGFloat(image.height)
            context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return drawn ? pixel[3] > 128 : nil
    }
}
