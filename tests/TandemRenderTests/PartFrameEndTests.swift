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
    func fixture(fade: Bool = true, length: Time? = nil) async throws -> (TestMedia, Project) {
        let length = length ?? self.length
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

    /// The frames `tandem check --privacy` reads over `range`, called as
    /// `TandemService.privacyCheck` calls it.
    func privacyFrames(_ project: Project, _ media: TestMedia, range: TimeRange) async throws -> [Time] {
        let reader = FrameTextReader(context: RenderContext(project: project, folder: media.projectFolder), width: 320)
        let times = LockedTimes()
        _ = try await PrivacyCheck.run(project: project, ranges: [range], folder: media.projectFolder, renderedEnd: try await reader.renderedEnd()) { wanted, sequential in
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

    /// The pictures in an export of `project`, and its video's length.
    func exported(_ project: Project, _ media: TestMedia) async throws -> (url: URL, pictures: Int, seconds: Double) {
        let out = media.folder.appendingPathComponent("out.mp4")
        let preset = ExportPreset(name: "Test", codec: .h264, videoBitrate: 4_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: project, folder: media.projectFolder), preset: preset, output: out).run()
        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var pictures = 0
        while let sample = output.copyNextSampleBuffer() {
            // Not the markers a reader hands over around the edit list.
            if CMSampleBufferGetNumSamples(sample) > 0, CMSampleBufferGetTotalSampleSize(sample) > 0 { pictures += 1 }
        }
        return (out, pictures, range.duration.seconds)
    }

    /// What the privacy check has to match: the exported file holds frame
    /// 89 and stops where the timeline does.
    func testExportWritesTheLastPartFrame() async throws {
        let (media, project) = try await fixture(fade: false)
        let file = try await exported(project, media)
        XCTAssertEqual(file.seconds, length.seconds, accuracy: 0.002)
        XCTAssertEqual(file.pictures, 90, "frames 0 to 89")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let last = Bitmap(try await generator.image(at: t(2.975).cmTime).image)
        XCTAssertEqual(TestMedia.readIndex(last, in: CGRect(x: 0, y: 0, width: 320, height: 180)), 89)
    }

    /// A last frame of 1.5 ms, just more than the millisecond that moves
    /// an end onto its frame (`RenderPlanner.onFrames`): the check reads
    /// as many frames as export writes.
    func testASliverOfALastFrameIsReadAsExportWritesIt() async throws {
        let (media, project) = try await fixture(fade: false, length: Time(seconds: 3.0015))
        let file = try await exported(project, media)
        XCTAssertEqual(file.pictures, 91, "frames 0 to 90")
        let read = try await privacyFrames(project, media, range: TimeRange(start: t(2.5), end: project.duration))
        XCTAssertEqual(read.count, 16, "frames 75 to 90")
        XCTAssertEqual(read.last, Time.frames(90, at: .fps30))
    }

    /// The reader takes the video in pieces of up to 10 s, so here its
    /// last piece is the part frame alone: a read 14 ms long.
    func testAPartFrameInAPieceOfItsOwnIsRead() async throws {
        let media = try TestMedia()
        try await media.movie("index.mov", seconds: 11, draw: { TestMedia.drawIndex($0, $1) })
        let clip = Clip(id: "clip_i", content: .media(mediaID: "med_i"), start: .zero, duration: Time(seconds: 10.014))
        let project = smallProject(video: [Track(kind: .video, name: "V1", clips: [clip])], media: [media.item("med_i", "index.mov", seconds: 11)])
        let read = try await privacyFrames(project, media, range: TimeRange(start: .zero, end: project.duration))
        XCTAssertEqual(read.count, 301, "frames 0 to 300")
        XCTAssertEqual(read.last, Time.frames(300, at: .fps30))
    }

    /// A 1 s dissolve into a last clip of 0.2 s: the first clip plays on
    /// for the transition's whole second half, so the export is 5.5 s long
    /// and the project 5.2. The check reads to the export's end.
    func testPrivacyCheckReadsAPictureRunningPastTheProjectsEnd() async throws {
        let media = try TestMedia()
        try await media.movie("index.mov", seconds: 8, draw: { TestMedia.drawIndex($0, $1) })
        let a = Clip(id: "clip_a", content: .media(mediaID: "med_i"), start: .zero, duration: t(5))
        let b = Clip(id: "clip_b", content: .media(mediaID: "med_i"), start: t(5), duration: t(0.2), sourceStart: t(6))
        let project = smallProject(
            video: [Track(kind: .video, name: "V1", clips: [a, b], transitions: [Transition(type: .dissolve, duration: t(1), fromClipID: a.id, toClipID: b.id)])],
            media: [media.item("med_i", "index.mov", seconds: 8)]
        )
        XCTAssertEqual(project.duration, t(5.2))
        let file = try await exported(project, media)
        XCTAssertEqual(file.pictures, 165, "5.5 s of frames")
        let read = try await privacyFrames(project, media, range: TimeRange(start: .zero, end: project.duration))
        XCTAssertEqual(read.count, file.pictures)
        // A stretch that stops short of the project's end stops there.
        let part = try await privacyFrames(project, media, range: TimeRange(start: t(4), end: t(5)))
        XCTAssertEqual(part.count, 30)
    }

    /// `tandem frame` at the end shows frame 89, not the one before it.
    func testAStillOfTheEndShowsTheLastPartFrame() async throws {
        let (media, project) = try await fixture(fade: false)
        let renderer = FrameRenderer(context: RenderContext(project: project, folder: media.projectFolder))
        let whole = CGRect(x: 0, y: 0, width: 320, height: 180)
        for time in [2.967, 2.975, 2.981, 3.5] {
            let still = Bitmap(try await renderer.image(at: t(time)))
            XCTAssertEqual(TestMedia.readIndex(still, in: whole), 89, "at \(time)")
        }
        let stills = try await renderer.images(at: [t(2.94), Time.frames(89, at: .fps30)])
        XCTAssertEqual(stills.map { TestMedia.readIndex(Bitmap($0.image), in: whole) }, [88, 89])
        XCTAssertEqual(FrameRenderer.lastFrameStart(before: t(3), rate: .fps30), Time.frames(89, at: .fps30), "a video that ends on a frame")
        XCTAssertEqual(FrameRenderer.lastFrameStart(before: .zero, rate: .fps30), .zero)
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
