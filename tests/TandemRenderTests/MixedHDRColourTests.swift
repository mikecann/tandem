import AVFoundation
import CoreImage
import XCTest
import TandemCore
import TandemMedia
@testable import TandemRender

/// SDR footage keeps its own colours in a project that also has HDR
/// footage in it, and the HDR footage still converts the way it always has.
///
/// Given an HLG clip anywhere in a composition, AVFoundation works in HLG
/// and, unless the compositor says it conforms colours itself, converts
/// every SDR frame into HLG before the compositor sees it. `HDRFrames` then
/// brought those frames back down to SDR, which is no round trip: in the
/// Sammy Cam video, with iPhone HDR clips on the timeline, Mike's untagged
/// full-range camera take came out pink-faced (a face patch 189/152/161
/// rendered 185/111/129) and the wall and sofa darker (25 Nov 2026).
///
/// The clips come from ffmpeg's software encoder, so the test skips without
/// ffmpeg.
final class MixedHDRColourTests: XCTestCase {
    /// Skin, a grey-blue wall, a dark sofa, an orange cushion and a light
    /// grey, as R'G'B'.
    static let patches: [[Int]] = [[190, 150, 160], [120, 132, 145], [50, 50, 48], [215, 110, 50], [220, 222, 226]]
    let size = CGSize(width: 1280, height: 720)

    enum Kind: String, CaseIterable {
        /// Mike's camera from 24 Nov on: full range with no colour tags.
        case untaggedFullRange
        /// His camera from 19 Nov: full range, tagged BT.601.
        case taggedFullRange601
        /// Ordinary video-range BT.709.
        case videoRange709
    }

    func ffmpeg() throws -> FFmpeg {
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        return ffmpeg
    }

    /// The patches as vertical bands, `seconds` long.
    func bands(_ colours: [[Int]], width: Int, height: Int, seconds: Double) -> [String] {
        let band = width / colours.count
        var arguments: [String] = []
        for (i, colour) in colours.enumerated() {
            let w = i == colours.count - 1 ? width - band * i : band
            arguments += ["-f", "lavfi", "-i", String(format: "color=c=0x%02X%02X%02X:s=%dx%d:d=%g:r=30", colour[0], colour[1], colour[2], w, height, seconds)]
        }
        return arguments
    }

    func sdrClip(_ kind: Kind, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("\(kind.rawValue).mov")
        let width = Int(size.width), height = Int(size.height)
        let stack = (0..<Self.patches.count).map { "[\($0)]" }.joined() + "hstack=\(Self.patches.count),format=rgb24"
        let encode: [String]
        switch kind {
        case .untaggedFullRange:
            // BT.709, as VideoToolbox guesses for an untagged HD file, and
            // no tags at all, like the camera's.
            encode = ["-filter_complex", stack + ",scale=out_color_matrix=bt709:out_range=pc,format=yuvj420p",
                      "-c:v", "libx265", "-pix_fmt", "yuvj420p"]
        case .taggedFullRange601:
            encode = ["-filter_complex", stack + ",scale=out_color_matrix=bt601:out_range=pc,format=yuvj420p",
                      "-c:v", "libx265", "-pix_fmt", "yuvj420p",
                      "-color_primaries", "smpte170m", "-color_trc", "bt709", "-colorspace", "smpte170m", "-color_range", "pc"]
        case .videoRange709:
            encode = ["-filter_complex", stack + ",scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
                      "-c:v", "libx265", "-pix_fmt", "yuv420p",
                      "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv"]
        }
        try ffmpeg().run(["-y", "-v", "error"] + bands(Self.patches, width: width, height: height, seconds: 1)
                         + encode + ["-x265-params", "log-level=error", "-preset", "ultrafast", "-tag:v", "hvc1", url.path])
        return url
    }

    /// A second of 10-bit HLG, as an iPhone records HDR: a warm grey, a
    /// saturated red and green, and a bright white, as the HLG signal.
    func hlgClip(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("hlg.mov")
        let colours = [[153, 115, 77], [200, 60, 40], [40, 180, 90], [230, 230, 240]]
        let stack = (0..<colours.count).map { "[\($0)]" }.joined() + "hstack=\(colours.count),format=rgb24"
        try ffmpeg().run(["-y", "-v", "error"] + bands(colours, width: 640, height: 360, seconds: 1) + [
            "-filter_complex", stack + ",scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le",
            "-c:v", "libx265", "-pix_fmt", "yuv420p10le", "-preset", "ultrafast",
            "-x265-params", "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-color_range", "tv",
            "-tag:v", "hvc1", url.path
        ])
        return url
    }

    func item(_ id: String, _ url: URL, width: Int, height: Int) -> MediaItem {
        MediaItem(id: id, path: url.path, kind: .video, role: .camera, duration: Time(seconds: 1),
                  frameRate: .fps30, width: width, height: height, hasVideo: true)
    }

    /// The SDR clip for the first second and, with `hlg`, the HLG clip for
    /// the next on a track of its own.
    func context(sdr: URL?, hlg: URL?, media: TestMedia) -> RenderContext {
        var items: [MediaItem] = []
        var tracks: [Track] = []
        if let sdr {
            items.append(item("med_sdr", sdr, width: Int(size.width), height: Int(size.height)))
            tracks.append(Track(kind: .video, name: "Camera", clips: [Clip(id: "clip_sdr", content: .media(mediaID: "med_sdr"), start: .zero, duration: t(1))]))
        }
        if let hlg {
            items.append(item("med_hlg", hlg, width: 640, height: 360))
            let start = sdr == nil ? t(0) : t(1)
            tracks.append(Track(kind: .video, name: "B-roll", clips: [Clip(id: "clip_hlg", content: .media(mediaID: "med_hlg"), start: start, duration: t(1))]))
        }
        let project = Project(name: "Mixed", settings: ProjectSettings(width: Int(size.width), height: Int(size.height), frameRate: .fps30),
                              media: items, videoTracks: tracks, audioTracks: [])
        return RenderContext(project: project, folder: media.projectFolder)
    }

    /// A file's own frame at `seconds`, as AVFoundation decodes it.
    func decoded(_ url: URL, at seconds: Double) async throws -> CVPixelBuffer {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        ])
        reader.add(output)
        reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "no frame at \(seconds) s")
        reader.cancelReading()
        return try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    }

    /// The frame an export reads at `seconds`: the composition through the
    /// compositor, as `Exporter` reads it, before encoding.
    func exportFrame(_ context: RenderContext, at seconds: Double) async throws -> CVPixelBuffer {
        let built = try await CompositionBuilder.build(context)
        let reader = try AVAssetReader(asset: built.composition)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 600), duration: CMTime(seconds: 0.1, preferredTimescale: 600))
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: try await built.composition.loadTracks(withMediaType: .video), videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.videoComposition = built.videoComposition
        reader.add(output)
        reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer(), "the export read nothing at \(seconds) s")
        reader.cancelReading()
        return try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
    }

    /// Mean R'G'B' of the middle of each of `count` bands.
    func bandValues(_ levels: Levels, count: Int) -> [[Double]] {
        (0..<count).map { i in
            let from = (Double(i) + 0.25) / Double(count), to = (Double(i) + 0.75) / Double(count)
            return levels.mean(from, 0.25, to, 0.75)
        }
    }

    func describe(_ values: [[Double]]) -> String {
        values.map { String(format: "%.0f/%.0f/%.0f", $0[0], $0[1], $0[2]) }.joined(separator: " ")
    }

    func assertClose(_ values: [[Double]], _ expected: [[Double]], within limit: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let worst = zip(values, expected).map { a, b in zip(a, b).map { abs($0 - $1) }.max()! }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, limit, "\(what): \(describe(values)) against \(describe(expected))", file: file, line: line)
    }

    func testSDRFootageKeepsItsColoursNextToHDRFootage() async throws {
        let media = try TestMedia()
        let hlg = try hlgClip(in: media.folder)
        let count = Self.patches.count
        for kind in Kind.allCases {
            let sdr = try sdrClip(kind, in: media.folder)
            let source = bandValues(Levels(try await decoded(sdr, at: 0.5), width: 160, height: 90), count: count)
            // The file as AVFoundation decodes it is the patches, near enough.
            assertClose(source, Self.patches.map { $0.map(Double.init) }, within: 4, "\(kind) as decoded")

            let mixed = context(sdr: sdr, hlg: hlg, media: media)
            let still = bandValues(Levels(try await FrameRenderer(context: mixed).image(at: t(0.5)), width: 160, height: 90), count: count)
            let playing = try await playerFrame(mixed, at: t(0.5))
            let played = (0..<count).map { i in playing[Int(size.width) * (2 * i + 1) / (2 * count), Int(size.height) / 2].prefix(3).map(Double.init) }
            let exported = bandValues(Levels(try await exportFrame(mixed, at: 0.5), width: 160, height: 90), count: count)
            assertClose(still, source, within: 3, "\(kind) paused, with an HDR clip in the project")
            assertClose(played, source, within: 3, "\(kind) playing, with an HDR clip in the project")
            assertClose(exported, source, within: 3, "\(kind) exported, with an HDR clip in the project")
        }
    }

    /// The HLG clip looks the same with SDR footage in the project as on
    /// its own, where `HDRFrames` converts it (see HDRFramesTests).
    func testHDRFootageNextToSDRFootageStillConvertsAsOnItsOwn() async throws {
        let media = try TestMedia()
        let hlg = try hlgClip(in: media.folder)
        let sdr = try sdrClip(.untaggedFullRange, in: media.folder)
        let alone = context(sdr: nil, hlg: hlg, media: media)
        let mixed = context(sdr: sdr, hlg: hlg, media: media)
        let expected = bandValues(Levels(try await FrameRenderer(context: alone).image(at: t(0.5)), width: 160, height: 90), count: 4)
        // Converted, not shown as its raw signal: the warm grey's signal is
        // 153/115/77, and SDR shows it darker and warmer.
        XCTAssertLessThan(expected[0][1], 105, "the HLG grey converted on its own: \(describe(expected))")
        let still = bandValues(Levels(try await FrameRenderer(context: mixed).image(at: t(1.5)), width: 160, height: 90), count: 4)
        let exported = bandValues(Levels(try await exportFrame(mixed, at: 1.5), width: 160, height: 90), count: 4)
        assertClose(still, expected, within: 2, "HLG paused, with SDR footage in the project")
        assertClose(exported, expected, within: 3, "HLG exported, with SDR footage in the project")
    }
}
