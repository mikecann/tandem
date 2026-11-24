import AVFoundation
import XCTest
import TandemCore
@testable import TandemRender

/// A timeline that ends part way through a frame: 2.981 s at 30 fps is
/// 89.43 frames, so frame 89 starts at 2.9667 s and the video ends 14 ms
/// into it. Export writes that frame, so every reader of the timeline has
/// to get it too.
final class PartFrameEndTests: XCTestCase {
    let length = Time(seconds: 2.981)

    /// One clip of `length` on a film of numbered frames, with sound, and
    /// the fade to black the real project ended on.
    func fixture(fade: Bool = true) async throws -> (TestMedia, Project) {
        let media = try TestMedia()
        try await media.movie("index.mov", seconds: 4, draw: { TestMedia.drawIndex($0, $1) }, sound: { _ in 0.1 })
        let item = media.item("med_i", "index.mov", seconds: 4, audio: true)
        let picture = Clip(id: "clip_i", content: .media(mediaID: item.id), start: .zero, duration: length)
        let sound = Clip(id: "clip_s", content: .media(mediaID: item.id), start: .zero, duration: length)
        let fades = fade ? [Transition(type: .fadeToBlack, duration: t(0.5), fromClipID: picture.id, toClipID: nil)] : []
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [picture], transitions: fades)],
            audio: [Track(kind: .audio, name: "A1", clips: [sound])],
            media: [item]
        )
        return (media, project)
    }

    func privacyFrames(_ project: Project, _ media: TestMedia, range: TimeRange) async throws -> [Time] {
        let reader = FrameTextReader(context: RenderContext(project: project, folder: media.projectFolder), width: 320)
        let times = LockedTimes()
        _ = try await PrivacyCheck.run(project: project, ranges: [range], folder: media.projectFolder) { wanted, sequential in
            let frames = try await reader.read(wanted, sequential: sequential)
            if sequential { times.set(frames.map(\.time)) }
            return frames
        }
        return times.value
    }

    /// The check rounds the end of what it reads up to a whole frame, 3 s
    /// here, and the reader used to read to there: past the last
    /// instruction, which AVFoundation refuses whole (-11841).
    func testPrivacyCheckReadsTheLastPartFrame() async throws {
        for fade in [true, false] {
            let (media, project) = try await fixture(fade: fade)
            XCTAssertEqual(project.duration, length)
            // The whole video, as `tandem check --privacy` asks for it.
            let whole = try await privacyFrames(project, media, range: TimeRange(start: .zero, end: project.duration))
            XCTAssertEqual(whole.count, 90, "frames 0 to 89, fade \(fade)")
            XCTAssertEqual(whole.last, Time.frames(89, at: .fps30))
            // A stretch that ends inside the last frame, and one past the end.
            for end in [2.97, 3.0] {
                let tail = try await privacyFrames(project, media, range: TimeRange(start: t(2.5), end: t(end)))
                XCTAssertEqual(tail.count, 15, "frames 75 to 89, to \(end), fade \(fade)")
            }
        }
    }

    /// Nothing is drawn after the end, and a stretch out there mustn't
    /// come back as read and clean.
    func testPrivacyCheckRefusesAStretchPastTheEnd() async throws {
        let (media, project) = try await fixture()
        do {
            let frames = try await privacyFrames(project, media, range: TimeRange(start: t(3), end: t(4)))
            XCTFail("read \(frames.count) frames past the end")
        } catch {
            XCTAssertTrue("\(error)".contains("did not read every requested output frame"), "\(error)")
        }
    }

    /// What the privacy check has to match: the exported file holds frame
    /// 89 and stops where the timeline does.
    func testExportWritesTheLastPartFrame() async throws {
        let (media, project) = try await fixture(fade: false)
        let out = media.folder.appendingPathComponent("out.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 4_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset, output: out).run()
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        XCTAssertEqual(range.duration.seconds, length.seconds, accuracy: 0.002)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var pictures = 0
        while let sample = output.copyNextSampleBuffer() {
            // Not the markers a reader hands over around the edit list.
            if CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 { pictures += 1 }
        }
        XCTAssertEqual(pictures, 90, "frames 0 to 89")
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let last = Bitmap(try await generator.image(at: t(2.975).cmTime).image)
        XCTAssertEqual(TestMedia.readIndex(last, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 89)
    }

    /// The 384-wide render check stops at the timeline's end already.
    func testRenderCheckReadsTheLastPartFrame() async throws {
        let (media, project) = try await fixture()
        let context = RenderContext(project: project, folder: media.projectFolder)
        let frames = try await FrameScanner.scan(context, ranges: [TimeRange(start: .zero, end: t(3))], width: 192)
        XCTAssertEqual(frames.count, 90, "frames 0 to 89")
    }
}

private final class LockedTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Time] = []
    var value: [Time] { lock.withLock { times } }
    func set(_ new: [Time]) { lock.withLock { times = new } }
}
