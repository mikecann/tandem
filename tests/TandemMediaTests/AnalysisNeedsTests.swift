import XCTest
@testable import TandemCore
@testable import TandemMedia

final class AnalysisNeedsTests: XCTestCase {
    func t(_ s: Double) -> Time { Time(seconds: s) }

    /// A folder's worth of media, only some of it on the timeline.
    func project() -> Project {
        var p = Project.standard(name: "Needs")
        p.media = [
            MediaItem(id: "med_cam", path: "source/a-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_scr", path: "source/a-screen.mov", kind: .video, role: .screen, duration: t(600), width: 3200, height: 1800, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_old", path: "Video v12.mp4", kind: .video, role: .other, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_cam2", path: "source/b-camera.mov", kind: .video, role: .camera, duration: t(600), width: 3840, height: 2160, hasVideo: true, hasAudio: true),
            MediaItem(id: "med_bed", path: "music/bed.mp3", kind: .audio, role: .music, duration: t(120), hasAudio: true)
        ]
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        let screen = p.location(ofTrack: p.track(named: "Screen")!.id)!
        let voice = p.location(ofTrack: p.track(named: "Voice")!.id)!
        var cam = Clip(id: "clip_cam", content: .media(mediaID: "med_cam"), start: .zero, duration: t(10))
        cam.video = VideoProperties(cutout: Cutout(enabled: true, mode: .personAndProps))
        p[camera].clips = [cam]
        p[screen].clips = [Clip(id: "clip_scr", content: .media(mediaID: "med_scr"), start: .zero, duration: t(10))]
        var sound = Clip(id: "clip_voice", content: .media(mediaID: "med_scr"), start: .zero, duration: t(10))
        sound.audio = AudioProperties(voiceIsolation: 0.5)
        p[voice].clips = [sound]
        return p
    }

    func kinds(_ needs: [AnalysisNeeds.Need], _ id: String) -> Set<AnalysisKind> {
        Set(needs.filter { $0.mediaID == id }.map(\.kind))
    }

    func testHeavyWorkOnlyForWhatTheEditUses() {
        let needs = AnalysisNeeds.needs(for: project())
        // On the timeline with its cutout on: everything it needs.
        XCTAssertEqual(kinds(needs, "med_cam"), [.thumbnails, .waveform, .loudness, .transcript, .proxy, .matte])
        // Screen on the Voice track with isolation: transcript and isolated
        // voice, a proxy, but no matte.
        XCTAssertEqual(kinds(needs, "med_scr"), [.thumbnails, .waveform, .loudness, .transcript, .proxy, .isolatedVoice])
        // An old render in the folder: only the cheap ones.
        XCTAssertEqual(kinds(needs, "med_old"), [.thumbnails, .waveform, .loudness])
        // A camera take not placed yet: searchable, nothing heavy.
        XCTAssertEqual(kinds(needs, "med_cam2"), [.thumbnails, .waveform, .loudness, .transcript])
        XCTAssertEqual(needs.first { $0.mediaID == "med_cam2" }?.priority, .background)
        XCTAssertEqual(kinds(needs, "med_bed"), [.waveform, .loudness])
    }

    func testFilesMacOSCantDecodeAreConvertedFirst() {
        var p = project()
        p.media += [
            MediaItem(id: "med_pop", path: "stickers/pop.mov", kind: .video, role: .sticker, duration: t(2), width: 512, height: 512, hasVideo: true, hasAlpha: true, undecodableCodec: "rle "),
            MediaItem(id: "med_spare", path: "stickers/spare.mov", kind: .video, role: .sticker, duration: t(2), width: 512, height: 512, hasVideo: true, hasAlpha: true, undecodableCodec: "png ")
        ]
        let graphics = p.location(ofTrack: p.track(named: "Graphics")!.id)!
        p[graphics].clips = [Clip(id: "clip_pop", content: .media(mediaID: "med_pop"), start: .zero, duration: t(2))]
        let needs = AnalysisNeeds.needs(for: p)

        let placed = needs.filter { $0.mediaID == "med_pop" }
        XCTAssertEqual(placed.map(\.kind), [.converted, .thumbnails])
        XCTAssertEqual(placed.first?.priority, .timeline)
        // Not on the timeline yet: converted in the background so the
        // browser can show it.
        let spare = needs.filter { $0.mediaID == "med_spare" }
        XCTAssertEqual(spare.map(\.kind), [.converted, .thumbnails])
        XCTAssertEqual(spare.first?.priority, .background)
        XCTAssertFalse(kinds(needs, "med_cam").contains(.converted))

        XCTAssertEqual(MediaAnalysis.defaultKinds(for: p.media.first { $0.id == "med_pop" }!), [.converted, .thumbnails])
    }

    func testMatteFollowsTheCutoutMode() {
        var p = project()
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        var plain = Clip(id: "clip_cam_b", content: .media(mediaID: "med_cam"), start: t(20), duration: t(5))
        plain.video = VideoProperties(cutout: Cutout(enabled: true, mode: .person))
        p[camera].clips.append(plain)
        let mattes = AnalysisNeeds.needs(for: p).filter { $0.kind == .matte }
        XCTAssertEqual(Set(mattes.compactMap(\.matteMode)), [.person, .personAndProps])
    }

    /// An 8 minute take with a minute and a half of it in the corner: the
    /// stretches the cutout clips play are matted first, in the order they
    /// play, so the corner is cut out long before the whole file is.
    func testMatteSpansFollowTheTimeline() throws {
        var p = project()
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        func cutout(_ id: String, at start: Double, from source: Double, for length: Double, speed: Double = 1) -> Clip {
            var clip = Clip(id: id, content: .media(mediaID: "med_cam"), start: t(start), duration: t(length), sourceStart: t(source), speed: speed)
            clip.video = VideoProperties(cutout: Cutout(enabled: true, mode: .personAndProps))
            return clip
        }
        p[camera].clips = [
            // First on the timeline, but late in the take.
            cutout("clip_a", at: 0, from: 400, for: 30),
            // Two cuts close together in the take become one stretch.
            cutout("clip_b", at: 30, from: 100, for: 20),
            cutout("clip_c", at: 50, from: 121.5, for: 10),
            // Twice the speed plays twice the source.
            cutout("clip_d", at: 60, from: 200, for: 10, speed: 2),
            // Runs to the end of the take: the stretch stops there.
            cutout("clip_e", at: 70, from: 590, for: 10)
        ]
        let matte = try XCTUnwrap(AnalysisNeeds.needs(for: p).first { $0.kind == .matte })
        XCTAssertEqual(matte.matteSpans, [
            UpscaleSpan(start: 399, end: 431),
            UpscaleSpan(start: 99, end: 133),
            UpscaleSpan(start: 199, end: 221),
            UpscaleSpan(start: 589, end: 600)
        ])
    }

    func testMatteSpansReachIntoTransitionsAndFollowThePictureDelay() throws {
        var p = project()
        let index = try XCTUnwrap(p.media.firstIndex { $0.id == "med_cam" })
        p.media[index].pictureDelay = t(0.5)
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        p[camera].clips[0].sourceStart = t(50)
        p[camera].transitions = [Transition(id: "tr_1", type: .fadeFromBlack, duration: t(2), fromClipID: nil, toClipID: "clip_cam")]
        let matte = try XCTUnwrap(AnalysisNeeds.needs(for: p).first { $0.kind == .matte })
        // 50.5 to 60.5 played, 2 s of transition and 1 s of margin each way.
        XCTAssertEqual(matte.matteSpans, [UpscaleSpan(start: 47, end: 64)])
    }

    func testCutoutOffMeansNoMatte() {
        var p = project()
        let camera = p.location(ofTrack: p.track(named: "Camera")!.id)!
        p[camera].clips[0].video?.cutout?.enabled = false
        XCTAssertFalse(kinds(AnalysisNeeds.needs(for: p), "med_cam").contains(.matte))
    }
}

extension AnalysisNeedsTests {
    /// `tandem transcribe` marks a file so its transcript is made whatever
    /// its role or track: a generated clip checked for made-up speech.
    func testATranscriptAskedForIsMadeWhateverTheRole() throws {
        var p = project()
        XCTAssertFalse(kinds(AnalysisNeeds.needs(for: p), "med_old").contains(.transcript))
        let index = try XCTUnwrap(p.media.firstIndex { $0.id == "med_old" })
        p.media[index].transcribe = true
        p.media.append(MediaItem(id: "med_mute", path: "broll/mute.mp4", kind: .video, role: .broll, duration: t(5), width: 1920, height: 1080, hasVideo: true, transcribe: true))
        let needs = AnalysisNeeds.needs(for: p)
        XCTAssertEqual(kinds(needs, "med_old"), [.thumbnails, .waveform, .loudness, .transcript])
        // Someone asked, so it goes ahead of the folder's idle work.
        XCTAssertEqual(needs.first { $0.mediaID == "med_old" && $0.kind == .transcript }?.priority, .timeline)
        XCTAssertFalse(kinds(needs, "med_mute").contains(.transcript), "no sound, nothing to transcribe")
    }

    func testTheRequestIsSavedWithTheMedia() throws {
        var item = MediaItem(id: "med_gen", path: "source/generated/cartoon.mp4", kind: .video, role: .other, hasVideo: true, hasAudio: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("transcribe"), "left out until asked for")
        item.transcribe = true
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.transcribe, true)
    }
}
