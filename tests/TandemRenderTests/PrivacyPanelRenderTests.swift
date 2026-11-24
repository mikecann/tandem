import AppKit
import AVFoundation
import ImageIO
import XCTest
@testable import TandemCore
import TandemMedia
@testable import TandemRender

extension PrivacyAuditRenderTests {
    func panelReady(mode: RippleMode = .cut) async throws -> (TestMedia, ProjectCoordinator) {
        let (media, c) = try await fixture(video: true, timed: true)
        try apply(c, .updateClip(clipID: "clip_dummy", patch: .object(["duration": .number(4)])))
        if mode != .cut {
            try apply(c, .updateTrack(trackID: "trk_screen", patch: .object(["name": .string("B-roll"), "rippleMode": .string(mode.rawValue)])))
            try apply(c, .addTrack(kind: .video, name: "Control", index: 0, id: "trk_control"))
        }
        try hide(c, range: TimeRange(start: t(1), end: t(3)))
        return (media, c)
    }

    func panelPicture(_ c: ProjectCoordinator) -> Clip {
        c.project.videoTracks.filter { !$0.isPrivacy }.flatMap(\.clips).first { $0.start == t(1) }!
    }

    func panelCovered(_ c: ProjectCoordinator, _ media: TestMedia, at time: Double, name: String, encode: Bool = false) async throws {
        let directory = try store(c, media, as: name)
        let reopened = ProjectCoordinator(project: try ProjectFile.load(from: directory.appendingPathComponent("Synthetic.tandem")).project)
        let frame = try await image(reopened, media, at: time)
        try png(frame, name + "-after-reload")
        let lines = recognise(frame)
        print("PANEL pixels \(name) at \(time): \(lines)")
        XCTAssertFalse(lines.contains { $0.contains("@example.com") }, "private text must stay hidden: \(name)")
        if encode {
            let out = directory.appendingPathComponent("export.mp4")
            let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
            _ = try await Exporter(context: RenderContext(project: reopened.project, folder: media.projectFolder), preset: preset, output: out).run()
            let encoded = try await exportedImage(out, at: time)
            try png(encoded, name + "-export")
            XCTAssertFalse(recognise(encoded).contains { $0.contains(email) })
        }
    }

    func testPanelSlidesExposeProtectedFramesOnBothNeighbours() async throws {
        try skipSlowPrivacyRenderOnCI()
        for delta in [0.2, -0.2] {
            let (media, c) = try await panelReady()
            let before = try await scan(c, media, to: 4)
            XCTAssertTrue(before.isEmpty)
            try apply(c, .slide(clipID: panelPicture(c).id, delta: t(delta)))
            try await panelCovered(c, media, at: delta > 0 ? 1.1 : 2.9, name: delta > 0 ? "slide-positive" : "slide-negative", encode: true)
            let after = try await scan(c, media, to: c.project.duration.seconds)
            print("PANEL slide \(delta) scan: \(after.map(\.message))")
        }
    }

    func testPanelRollNeedsSourceAndPlacementCoverage() async throws {
        try skipSlowPrivacyRenderOnCI()
        for edge in ["head", "tail"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            let neighbour = c.project.videoTracks[0].clips.first { edge == "head" ? $0.end == t(1) : $0.start == t(3) }!
            try apply(c, .updateClip(clipID: neighbour.id, patch: .object(["video": .object(["transform": .object(["position": .object(["x": .number(0.5), "y": .number(0.8)])])])])))
            let before = try await scan(c, media, to: 4)
            XCTAssertTrue(before.isEmpty)
            try apply(c, .roll(leftClipID: edge == "head" ? neighbour.id : picture.id, rightClipID: edge == "head" ? picture.id : neighbour.id, delta: t(edge == "head" ? 0.2 : -0.2)))
            try await panelCovered(c, media, at: edge == "head" ? 1.1 : 2.9, name: "roll-\(edge)-different-placement", encode: edge == "head")
        }
        // The panel's continuous negative-head-roll example adds source
        // before the originally protected interval. It must not be reported
        // as exposing that interval when identical framing still covers it.
        let (media, c) = try await panelReady()
        let picture = panelPicture(c)
        let left = c.project.videoTracks[0].clips.first { $0.end == t(1) }!
        try apply(c, .roll(leftClipID: left.id, rightClipID: picture.id, delta: t(-0.2)))
        let beforeScope = try await image(c, media, at: 0.9)
        let protected = try await image(c, media, at: 1.1)
        try png(beforeScope, "roll-continuous-before-protected-source")
        XCTAssertFalse(recognise(beforeScope).contains { $0.contains(email) })
        XCTAssertFalse(recognise(protected).contains { $0.contains(email) })
        let found = try await scan(c, media, to: 4)
        XCTAssertTrue(found.isEmpty)
    }

    func testPanelFollowAndOffRippleInsertLeaveACoverageHole() async throws {
        try skipSlowPrivacyRenderOnCI()
        for mode: RippleMode in [.follow, .off] {
            let (media, c) = try await panelReady(mode: mode)
            let before = try await scan(c, media, to: 4)
            XCTAssertTrue(before.isEmpty)
            try apply(c, .insertTime(at: t(2), duration: t(0.4), trackIDs: ["trk_control"]))
            try await panelCovered(c, media, at: 2.2, name: "ripple-insert-\(mode.rawValue)", encode: true)
        }
    }

    func testPanelTargetedBrollRippleLeavesMaskBehind() async throws {
        let (media, c) = try await panelReady(mode: .follow)
        try apply(c, .rippleDeleteRange(range: TimeRange(start: .zero, end: t(0.5)), trackIDs: ["trk_screen"]))
        try await panelCovered(c, media, at: 0.7, name: "ripple-targeted-broll")
    }

    func testPanelTrackTransferAndReorderExposeAboveTheMask() async throws {
        for move in ["transfer", "reorder"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            if move == "transfer" {
                try apply(c, .addTrack(kind: .video, name: "B-roll", index: nil, id: "trk_upper"))
                try apply(c, .moveClips(clipIDs: [picture.id], delta: .zero, toTrackID: "trk_upper"))
            } else {
                try apply(c, .moveTrack(trackID: "trk_screen", index: c.project.videoTracks.count-1))
            }
            try await panelCovered(c, media, at: 2, name: "track-\(move)", encode: move == "transfer")
        }
    }

    func testPanelDirectTimeAndEnabledPatchesExposeThePicture() async throws {
        for change in ["start", "enabled"] {
            let (media, c) = try await panelReady()
            let picture = panelPicture(c)
            if change == "start" {
                let following = c.project.videoTracks[0].clips.first { $0.start == t(3) }!
                try apply(c, .removeClips(clipIDs: [following.id], includeLinked: false))
                try apply(c, .updateClip(clipID: picture.id, patch: .object(["start": .number(1.5)])))
            } else {
                let mask = c.project.videoTracks.first { $0.isPrivacy }!.clips[0]
                try apply(c, .updateClip(clipID: picture.id, patch: .object(["enabled": .bool(false)])))
                // This probe checks automatic following. An explicit copy
                // disable intentionally stays off, even after picture-on.
                XCTAssertFalse(c.project.clip(mask.id)!.enabled)
                try apply(c, .updateClip(clipID: picture.id, patch: .object(["enabled": .bool(true)])))
            }
            try await panelCovered(c, media, at: change == "start" ? 3.2 : 2, name: "direct-\(change)", encode: change == "start")
        }
    }

    func testPanelLockedAngleSwitchExposesAnEnabledAngle() async throws {
        let (media, base) = try await fixture(video: true, timed: true)
        try await media.movie("plain.mov", seconds: 4, size: canvas, draw: { _, c in self.draw(c, privateText: false) })
        var p = base.project
        p.media[0].takeID = "take_panel"; p.media[0].takeOffset = .zero
        p.media.append(MediaItem(id: "med_wide", path: "plain.mov", kind: .video, role: .camera, takeID: "take_panel", takeOffset: .zero, duration: t(4), frameRate: .fps30, width: 1280, height: 720, hasVideo: true))
        p.videoTracks = [Track(id: "trk_camera", kind: .video, name: "Camera", clips: [Clip(id: "clip_camera", content: .media(mediaID: "med_wide"), start: .zero, duration: t(4), linkGroup: "lnk_panel", video: VideoProperties())], rippleMode: .cut)]
        let c = ProjectCoordinator(project: p)
        try apply(c, .placeSynced(mediaID: "med_dummy"))
        try hide(c, range: TimeRange(start: t(1), end: t(3)))
        try apply(c, .showAngle(range: TimeRange(start: t(1), end: t(3)), trackID: "Camera"))
        let before = try await image(c, media, at: 2)
        XCTAssertFalse(recognise(before).contains { $0.contains(email) })
        let track = c.project.videoTracks.first { $0.isPrivacy }!
        XCTAssertTrue(track.clips.allSatisfy { !$0.enabled })
        try apply(c, .updateTrack(trackID: track.id, patch: .object(["locked": .bool(true)])))
        try apply(c, .showAngle(range: TimeRange(start: t(1.5), end: t(2.5)), trackID: "Angle 2"))
        try await panelCovered(c, media, at: 2, name: "locked-angle-switch")
    }

    func testPanelOneSidedTransitionsMovePictureOutsideItsMask() async throws {
        for type: TransitionType in [.push, .cutSlide, .slide, .zoom] {
            let media = try TestMedia()
            let zoom = type == .zoom
            let rect = zoom ? Rect(x: 0.29, y: 0.7, width: 0.5, height: 0.13) : region
            try await media.movie("dummy.mov", seconds: 4, size: canvas, draw: { _, c in
                if zoom {
                    c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(origin: .zero, size: self.canvas))
                    self.text(self.email, x: 400, y: 580, size: 45, in: c)
                } else { self.draw(c) }
            })
            let item = MediaItem(id: "med_dummy", path: "dummy.mov", kind: .video, role: .screen, duration: t(4), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
            let picture = Clip(id: "clip_dummy", content: .media(mediaID: item.id), start: .zero, duration: t(2), video: VideoProperties())
            let p = Project(name: "Panel transition", settings: ProjectSettings(width: 1280, height: 720, frameRate: .fps30), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [picture], rippleMode: .cut)], audioTracks: [])
            let c = ProjectCoordinator(project: p)
            try apply(c, .redact(range: picture.range, rect: rect, mediaID: item.id, style: .blur, size: 90))
            let control = try await image(c, media, at: 1.5)
            XCTAssertFalse(recognise(control).contains { $0.contains(email) })
            let incoming = type == .slide
            let transition = Transition(type: type, direction: incoming ? .up : .down, duration: t(1), fromClipID: incoming ? nil : picture.id, toClipID: incoming ? picture.id : nil)
            try apply(c, .addTransition(trackID: "trk_screen", transition: transition))
            let at = zoom ? 1.4 : incoming ? 0.5 : 1.5
            if zoom {
                let directory = try store(c, media, as: "transition-one-sided-zoom")
                let reopened = ProjectCoordinator(project: try ProjectFile.load(from: directory.appendingPathComponent("Synthetic.tandem")).project)
                let frame = try await image(reopened, media, at: at)
                try png(frame, "transition-one-sided-zoom-after-reload")
                let bitmap = Bitmap(frame)
                let outside = (610..<700).reduce(0) { count, y in
                    count + (250..<950).filter { bitmap.luma($0, y) < 220 }.count
                }
                XCTAssertLessThan(outside, 500, "source redaction hides the private glyphs before zoom motion")
                let lines = recognise(frame)
                XCTAssertFalse(lines.contains { $0.contains(email) })
                print("PANEL zoom: \(outside) nonwhite pixels outside patch; OCR \(lines); readable email NOT demonstrated")
            } else {
                try await panelCovered(c, media, at: at, name: "transition-one-sided-\(type.rawValue)", encode: type == .push)
            }
        }
    }

    func testPanelRedactingAnAlreadyFrozenHLGClipFreezesItsCopy() async throws {
        let media = try TestMedia()
        try await media.movie("dummy.mov", seconds: 4, size: canvas, hlg: true, draw: { frame, c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(origin: .zero, size: self.canvas))
            c.setFillColor(CGColor(gray: frame < 60 ? 0.35 : 0.8, alpha: 1))
            c.fill(CGRect(x: 96, y: 180, width: 704, height: 130))
            self.text(frame < 60 ? self.email : "bob@example.net", x: 120, y: 260, size: 45, in: c)
        })
        let item = MediaItem(id: "med_dummy", path: "dummy.mov", kind: .video, role: .screen, duration: t(4), frameRate: .fps30, width: 1280, height: 720, hasVideo: true)
        let clip = Clip(id: "clip_dummy", content: .media(mediaID: item.id), start: .zero, duration: t(3), sourceStart: t(1), freezeFrame: true, video: VideoProperties())
        let c = ProjectCoordinator(project: Project(name: "Panel frozen HLG", settings: ProjectSettings(width: 1280, height: 720, frameRate: .fps30), media: [item], videoTracks: [Track(id: "trk_screen", kind: .video, name: "Screen", clips: [clip], rippleMode: .cut)], audioTracks: []))
        let control = try await image(c, media, at: 2.5)
        XCTAssertTrue(recognise(control).contains { $0.contains(email) })
        try hide(c)
        let mask = c.project.videoTracks.first { $0.isPrivacy }!.clips[0]
        XCTAssertTrue(mask.freezeFrame)
        XCTAssertEqual(mask.sourceStart, t(1))
        let early = try await image(c, media, at: 0.25)
        let late = try await image(c, media, at: 2.5)
        try png(late, "hlg-frozen-copy-covered")
        XCTAssertFalse(recognise(late).contains { $0.contains(email) })
        let a = Bitmap(early), b = Bitmap(late)
        for channel in 0..<3 { XCTAssertEqual(a[700, 240][channel], b[700, 240][channel], accuracy: 3) }
        let found = try await scan(c, media)
        XCTAssertTrue(found.isEmpty)
        let directory = try store(c, media, as: "hlg-frozen-copy")
        let out = directory.appendingPathComponent("export.mp4")
        let preset = ExportPreset(name: "Audit", codec: .h264, videoBitrate: 8_000_000, audioBitrate: 192_000, loudnessTarget: nil, truePeakCeiling: nil)
        _ = try await Exporter(context: RenderContext(project: c.project, folder: media.projectFolder), preset: preset, output: out).run()
        let encoded = try await exportedImage(out, at: 2.5)
        XCTAssertFalse(recognise(encoded).contains { $0.contains(email) })
        // Deliberately corrupt only the scratch copy: a moving copy would
        // now show the lighter later frame. This makes the temporal fixture
        // discriminate the exact bug the original static fixture missed.
        try apply(c, .updateClip(clipID: mask.id, patch: .object(["freezeFrame": .bool(false), "sourceStart": .number(0)])))
        let corrupt = Bitmap(try await image(c, media, at: 2.5))
        XCTAssertGreaterThan(abs(corrupt[700, 240][0] - b[700, 240][0]), 20)
    }
}
