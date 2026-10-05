import XCTest
@testable import TandemCore

/// Joining through-edits: a cut where a clip carries straight on into the
/// next piece of the same file becomes one clip again, and what plays
/// never changes.
final class JoinTests: XCTestCase {
    /// Cutting the take and joining the cut gives back exactly the
    /// timeline before the cut: the same IDs, link groups and lengths.
    func testJoiningABladedTakePutsItBackTogether() throws {
        let (f, c) = try Fixture.edited()
        let before = c.project
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        XCTAssertEqual(c.clips("Voice").count, 2)
        let result = try c.run("Join", .join(clipID: camera))
        XCTAssertEqual(result.createdIDs, [])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(c.project, before, "camera, screen and voice are one take again")
    }

    /// Every frame and sample plays as it did: the same file, the same
    /// moment in it, the same settings and animation, the same fades.
    func testAJoinPlaysExactlyWhatTheTwoDid() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Animate",
                  .setKeyframes(clipID: camera, parameter: "video.transform.scale", keyframes: [
                      Keyframe(time: t(2), value: .number(1), interpolation: .linear),
                      Keyframe(time: t(12), value: .number(1.4), interpolation: .easeInOut),
                      Keyframe(time: t(20), value: .number(1.2))
                  ]),
                  .updateClip(clipID: f.clips("Voice")[0].id, patch: .object(["audio": .object(["fadeIn": .number(0.5), "fadeOut": .number(1)])])))
        try c.run("Cut", .blade(at: t(7), clipIDs: [camera]), .blade(at: t(16), trackIDs: [f.track("Camera").id]))
        let cut = c.project
        XCTAssertEqual(c.clips("Camera").count, 3)

        try c.run("Join", .join(clipID: camera), .join(clipID: camera))
        XCTAssertEqual(c.clips("Camera").count, 1)
        XCTAssertEqual(c.clips("Voice").count, 1)
        XCTAssertEqual(c.clips("Voice")[0].audio?.fadeIn, t(0.5), "the first piece's fade in")
        XCTAssertEqual(c.clips("Voice")[0].audio?.fadeOut, t(1), "the last piece's fade out")
        assertPlaysTheSame(cut, c.project)
        assertValid(c.project)
    }

    func testItSaysWhyACutIsntAThroughEdit() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.track("Camera").id
        try c.run("Cut", .blade(at: t(10), trackIDs: [camera]), .blade(at: t(20), trackIDs: [camera]), .blade(at: t(30), trackIDs: [camera]))
        // A pause tightened out of the take: the file jumps at the cut.
        try c.run("Tighten", .rippleDeleteRange(range: TimeRange(start: t(20), end: t(21))))
        let pieces = c.clips("Camera").map(\.id)
        assertRefused(c, .join(clipID: pieces[1]), "the file doesn't carry straight on")

        // The last clip has nothing after it.
        assertRefused(c, .join(clipID: pieces[3]), "nothing after it")

        // A gap between them.
        try c.run("Lift", .removeClips(clipIDs: [pieces[3]], ripple: false))
        try c.run("Shorten", .trim(clipID: pieces[2], edge: .end, to: t(25)))
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera"], at: t(26), sourceStart: t(26), duration: t(4), mode: .overwrite, includeAudio: false))
        assertRefused(c, .join(clipID: pieces[2]), "gap")

        // Another speed.
        let (g, d) = try Fixture.edited()
        try d.run("Cut", .blade(at: t(10), clipIDs: [g.clips("Camera")[0].id]))
        try d.run("Fast", .setSpeed(clipID: d.clips("Camera")[1].id, speed: 2, ripple: true))
        assertRefused(d, .join(clipID: g.clips("Camera")[0].id), "speed")

        // Another file.
        let (h, e) = try Fixture.edited()
        try e.run("More B-roll", .placeMedia(mediaIDs: ["med_camera"], at: t(25), sourceStart: t(26), duration: t(2), videoTrackID: h.track("B-roll").id, includeAudio: false))
        assertRefused(e, .join(clipID: e.clips("B-roll")[0].id), "different files")
    }

    func testDifferentSettingsAreRefusedAndNothingChanges() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        try c.run("Fade the second", .updateClip(clipID: c.clips("Camera")[1].id, patch: .object(["video": .object(["opacity": .number(0.5)])])))
        assertRefused(c, .join(clipID: camera), "opacity")

        // A linked clip that can't join stops the whole join.
        let (g, d) = try Fixture.edited()
        try d.run("Cut", .blade(at: t(10), clipIDs: [g.clips("Camera")[0].id]))
        try d.run("Louder", .updateClip(clipID: d.clips("Voice")[1].id, patch: .object(["audio": .object(["gainDB": .number(3)])])))
        let error = assertRefused(d, .join(clipID: g.clips("Camera")[0].id), "gain")
        XCTAssertTrue(error.contains("Voice"), error)
        XCTAssertEqual(d.clips("Camera").count, 2, "the camera stays cut too")
    }

    /// `applyLayout` gives each clip its own drop shadow. The same shadow
    /// under another ID is the same setting, and the right clip's shadow
    /// animation follows the left one's ID.
    func testTheSameEffectsUnderOtherIDsStillJoin() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        let right = c.clips("Camera")[1].id
        try c.run("PiP", .applyLayout(clipIDs: [camera, right], preset: .pipRight))
        let shadows = c.clips("Camera").compactMap { $0.video?.effects.first?.id }
        XCTAssertEqual(shadows.count, 2)
        XCTAssertNotEqual(shadows[0], shadows[1])
        // The second piece's shadow fades out later on.
        try c.run("Shadow", .setKeyframes(clipID: right, parameter: "video.effects.\(shadows[1]).opacity", keyframes: [
            Keyframe(time: t(5), value: .number(60), interpolation: .linear),
            Keyframe(time: t(8), value: .number(0))
        ]))
        let cut = c.project
        try c.run("Join", .join(clipID: camera))
        let joined = c.clips("Camera")[0]
        XCTAssertEqual(joined.video?.effects.map(\.id), [shadows[0]])
        XCTAssertEqual(joined.keyframes["video.effects.\(shadows[0]).opacity"]?.map(\.time), [t(15), t(18)])
        assertPlaysTheSame(cut, c.project)
    }

    func testATransitionOnTheCutIsRefused() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(30), clipIDs: [camera]))
        try c.run("Dissolve", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(id: "tr_d", type: .dissolve, duration: t(0.5), fromClipID: camera, toClipID: c.clips("Camera")[1].id)
        ))
        let error = assertRefused(c, .join(clipID: camera), "dissolve")
        XCTAssertTrue(error.contains("tr_d"), error)

        let (g, d) = try Fixture.edited()
        let left = g.clips("Camera")[0].id
        try d.run("Cut", .blade(at: t(30), clipIDs: [left]))
        try d.run("Fade", .addTransition(
            trackID: g.track("Camera").id,
            transition: Transition(id: "tr_f", type: .fadeToBlack, duration: t(1), fromClipID: left, toClipID: nil)
        ))
        assertRefused(d, .join(clipID: left), "fadeToBlack")
    }

    /// A transition at the far end of the right clip moves to the joined
    /// clip and plays just as it did; one that only fit because its clip
    /// was short would grow, so that's refused.
    func testTransitionsAtTheEndsStayAsTheyWere() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(30), clipIDs: [camera]))
        try c.run("Fade", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(id: "tr_out", type: .fadeToBlack, duration: t(1.1), fromClipID: c.clips("Camera")[1].id, toClipID: nil)
        ))
        let cut = c.project
        try c.run("Join", .join(clipID: camera))
        XCTAssertEqual(c.project.track(named: "Camera")?.transitions.first?.fromClipID, camera)
        assertPlaysTheSame(cut, c.project)

        // A fade in longer than the first piece, after a trim made it short.
        let (g, d) = try Fixture.edited()
        let left = g.clips("Camera")[0].id
        try d.run("Fade in", .addTransition(
            trackID: g.track("Camera").id,
            transition: Transition(id: "tr_in", type: .fadeFromBlack, duration: t(1.1), fromClipID: nil, toClipID: left)
        ))
        try d.run("Cut", .blade(at: t(0.5), clipIDs: [left]))
        assertRefused(d, .join(clipID: left), "longer than")
    }

    func testAFadeAtTheCutIsRefused() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(30), clipIDs: [camera]))
        try c.run("Dip", .updateClip(clipID: c.clips("Voice")[0].id, patch: .object(["audio": .object(["fadeOut": .number(0.3)])])))
        let error = assertRefused(c, .join(clipID: camera), "fades out at the cut")
        XCTAssertTrue(error.contains("Voice"), error)
    }

    /// Keyframes keep their timeline times. A clip cut through its
    /// animation joins back with it whole; animation on one side only
    /// joins when it ends (or starts) where the other side sits still.
    func testKeyframesCarryOnOnlyWhenTheAnimationWouldPlayTheSame() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        let zoom = [
            Keyframe(time: t(0), value: .number(1), interpolation: .linear),
            Keyframe(time: t(10), value: .number(1.5)),
            Keyframe(time: t(20), value: .number(1), interpolation: .hold),
            Keyframe(time: t(40), value: .number(1.2))
        ]
        try c.run("Zoom", .setKeyframes(clipID: camera, parameter: "video.transform.scale", keyframes: zoom))
        let before = c.project
        try c.run("Cut", .blade(at: t(15), clipIDs: [camera]), .blade(at: t(30), trackIDs: [f.track("Camera").id]))
        try c.run("Join", .join(clipID: camera), .join(clipID: camera))
        XCTAssertEqual(c.project, before, "the animation is whole again")

        // On the left only, back where the right one sits: fine.
        let (g, d) = try Fixture.edited()
        let left = g.clips("Camera")[0].id
        try d.run("Cut", .blade(at: t(30), clipIDs: [left]))
        let right = d.clips("Camera")[1].id
        try d.run("Punch in and out", .setKeyframes(clipID: left, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: t(5), value: .number(1)), Keyframe(time: t(6), value: .number(1.3)),
            Keyframe(time: t(20), value: .number(1.3)), Keyframe(time: t(21), value: .number(1))
        ]))
        var cut = d.project
        try d.run("Join", .join(clipID: left))
        assertPlaysTheSame(cut, d.project)
        _ = d.undo()

        // Left only, still zoomed at the cut: it would carry on.
        try d.run("Stay in", .setKeyframes(clipID: left, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: t(5), value: .number(1)), Keyframe(time: t(6), value: .number(1.3))
        ]))
        assertRefused(d, .join(clipID: left), "carry on past the cut")

        // Right only, starting zoomed in: it would reach back.
        try d.run("Clear", .setKeyframes(clipID: left, parameter: "video.transform.scale", keyframes: []))
        try d.run("Start in", .setKeyframes(clipID: right, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: t(1), value: .number(1.3)), Keyframe(time: t(2), value: .number(1))
        ]))
        assertRefused(d, .join(clipID: left), "reach back")

        // Right only, still at the cut: fine.
        try d.run("Later", .setKeyframes(clipID: right, parameter: "video.transform.scale", keyframes: [
            Keyframe(time: t(0), value: .number(1)), Keyframe(time: t(2), value: .number(1.3))
        ]))
        cut = d.project
        try d.run("Join", .join(clipID: left))
        assertPlaysTheSame(cut, d.project)
        XCTAssertEqual(d.clips("Camera")[0].keyframes["video.transform.scale"]?.map(\.time), [t(30), t(32)])
    }

    func testALockedTrackIsRefused() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        try c.run("Lock", .updateTrack(trackID: f.track("Voice").id, patch: .object(["locked": .bool(true)])))
        XCTAssertThrowsError(try c.run("Join", .join(clipID: camera))) { error in
            guard case .locked(let what)? = error as? EditError else { return XCTFail("\(error)") }
            XCTAssertTrue(what.contains("Voice"), what)
        }
    }

    /// Linked clips have to meet at the same cut, so the take stays in
    /// step: one cut a moment later on its own (a split edit) can't join.
    func testLinkedClipsHaveToMeetAtTheCut() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        // The voice cut a moment after the picture, on its own.
        try c.run("Voice later", .trim(clipID: c.clips("Voice")[1].id, edge: .start, to: t(10.2), includeLinked: false))
        try c.run("Voice longer", .trim(clipID: c.clips("Voice")[0].id, edge: .end, to: t(10.2), includeLinked: false))
        XCTAssertEqual(c.clips("Camera")[0].end, t(10))
        XCTAssertEqual(c.clips("Voice")[0].end, t(10.2))
        assertRefused(c, .join(clipID: camera), "not at the cut")
    }

    /// Trims leave a little rounding between the pieces; half a frame of
    /// it still joins, more is a jump in the file.
    func testHalfAFrameOfRoundingStillJoins() throws {
        let (f, c) = try Fixture.edited()
        let camera = f.clips("Camera")[0].id
        try c.run("Cut", .blade(at: t(10), clipIDs: [camera]))
        try c.run("Nudge", .slip(clipID: c.clips("Camera")[1].id, delta: t(0.01)))
        try c.run("Join", .join(clipID: camera))
        XCTAssertEqual(c.clips("Camera").count, 1)

        let (g, d) = try Fixture.edited()
        try d.run("Cut", .blade(at: t(10), clipIDs: [g.clips("Camera")[0].id]))
        try d.run("Jump", .slip(clipID: d.clips("Camera")[1].id, delta: t(-0.05)))
        assertRefused(d, .join(clipID: g.clips("Camera")[0].id), "carry straight on")
    }

    /// Joining the clip that plays a transition's sound would lose the tie.
    func testTheSoundOfATransitionIsntJoinedAway() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Whoosh", .addMedia(item: MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(2), hasAudio: true)))
        try c.run("Place", .placeMedia(mediaIDs: ["med_whoosh"], at: t(29), duration: t(2)))
        let sfx = c.clips("SFX")[0].id
        try c.run("Cut", .blade(at: t(30), clipIDs: [sfx]), .blade(at: t(30), clipIDs: [f.clips("Camera")[0].id]))
        let pieces = c.clips("Camera").map(\.id)
        try c.run("Push", .addTransition(
            trackID: f.track("Camera").id,
            transition: Transition(id: "tr_p", type: .push, duration: t(0.5), fromClipID: pieces[0], toClipID: pieces[1], soundClipID: c.clips("SFX")[1].id)
        ))
        assertRefused(c, .join(clipID: sfx), "sound of transition tr_p")
    }

    // MARK: - Every through-edit at once

    func testJoinThroughEditsJoinsTheWholeTimelineInOneGo() throws {
        let (_, c) = try Fixture.edited()
        let before = c.project
        for seconds in stride(from: 5.0, through: 55, by: 7.5) {
            try c.run("Cut", .blade(at: t(seconds)))
        }
        XCTAssertGreaterThan(c.project.allTracks.flatMap(\.clips).count, 20)
        let cut = c.project
        let result = try c.run("Join", .joinThroughEdits())
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(c.project, before, "every cut joined, the first piece of each keeping its ID")
        assertPlaysTheSame(cut, c.project)

        XCTAssertEqual(try c.run("Again", .joinThroughEdits()).warnings, ["No through-edits to join."])
    }

    func testJoinThroughEditsOnlyJoinsCutsInItsRangeAndSaysWhatItLeft() throws {
        let (f, c) = try Fixture.edited()
        try c.run("Cut", .blade(at: t(10)), .blade(at: t(20.5)), .blade(at: t(40)))
        try c.run("Dissolve", .addTransition(
            trackID: f.track("Screen").id,
            transition: Transition(id: "tr_d", type: .dissolve, duration: t(0.5), fromClipID: c.clips("Screen")[1].id, toClipID: c.clips("Screen")[2].id)
        ))
        let report = try c.run("Join", .joinThroughEdits(range: TimeRange(start: t(10), end: t(30))))
        XCTAssertEqual(c.clips("Camera").map(\.start), [t(0), t(20.5), t(40)], "10 joined; 20.5 has a dissolve; 40 is outside")
        XCTAssertEqual(c.clips("Music").map(\.start), [t(0), t(40)], "the music bed's cuts join too")
        XCTAssertEqual(report.warnings.count, 1, "\(report.warnings)")
        XCTAssertTrue(report.warnings[0].contains("00:20.500") && report.warnings[0].contains("dissolve"), report.warnings[0])

        // The report says the same, and nothing changes making it.
        var project = c.project
        let plan = ThroughEdits.joinAll(&project)
        XCTAssertEqual(plan.joins.map(\.time), [t(40), t(40)], "the take, and the music bed under it")
        XCTAssertEqual(plan.joins.map(\.pairs.count), [3, 1], "screen, camera and voice together")
        XCTAssertEqual(plan.skipped.map(\.time), [t(20.5)], "once, though the screen, camera and voice all cut there")
        XCTAssertTrue(plan.skipped[0].reason.contains("tr_d"), plan.skipped[0].reason)
    }

    /// The case that prompted joining: a few hundred cuts put back with
    /// ripple trims, all joined in one command, quickly.
    func testHundredsOfThroughEditsJoinQuickly() throws {
        var fixture = Fixture()
        let pieces = 1000
        let length = t(0.1)
        fixture.project.media[0].duration = t(200)
        fixture.project.media[1].duration = t(201)
        for (name, mediaID, offset) in [("Screen", "med_screen", t(0.5)), ("Camera", "med_camera", Time.zero), ("Voice", "med_camera", Time.zero)] {
            guard let location = fixture.project.location(ofTrack: fixture.track(name).id) else { return XCTFail(name) }
            fixture.project[location].clips = (0..<pieces).map { i in
                let start = Time(flicks: length.flicks * Int64(i))
                return Clip(id: "clip_\(name)_\(i)", content: .media(mediaID: mediaID), start: start, duration: length, sourceStart: start + offset, linkGroup: "lnk_\(i)")
            }
        }
        assertValid(fixture.project)
        let coordinator = ProjectCoordinator(project: fixture.project)
        let started = Date()
        try coordinator.run("Join", .joinThroughEdits())
        let elapsed = Date().timeIntervalSince(started)
        for name in ["Screen", "Camera", "Voice"] {
            XCTAssertEqual(coordinator.clips(name).map(\.range), [TimeRange(start: .zero, duration: Time(flicks: length.flicks * Int64(pieces)))], name)
        }
        XCTAssertLessThan(elapsed, 2, "\(pieces * 3) clips joined in \(elapsed) s")
    }

    // MARK: - Helpers

    /// Applies a command that must fail, checks the project didn't change
    /// and returns the error's words.
    @discardableResult
    func assertRefused(_ c: ProjectCoordinator, _ command: EditCommand, _ reason: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let before = c.project
        var message = ""
        XCTAssertThrowsError(try c.run("Join", command), file: file, line: line) { error in
            message = (error as? EditError)?.description ?? "\(error)"
        }
        XCTAssertTrue(message.contains(reason), "\(message) should say \(reason)", file: file, line: line)
        XCTAssertEqual(c.project, before, "nothing changed", file: file, line: line)
        return message
    }

    /// What a track plays at a moment: the file and the moment in it, the
    /// clip's settings and animation there, and its fades. Or where one of
    /// its transitions plays.
    struct Sample: Equatable {
        var track: String
        var time: Time
        var media: String?
        var source: Time?
        var enabled = true
        var holdEdges = false
        var fade = 1.0
        var video = VideoProperties()
        var audio = AudioProperties()
        var transition: String?
    }

    /// Every track at every half frame, and where its transitions play.
    func played(_ project: Project) -> [Sample] {
        let step = Time(flicks: project.settings.frameRate.flicksPerFrame / 2)
        var samples: [Sample] = []
        for track in project.allTracks {
            var time = Time.zero
            while time < project.duration {
                defer { time += step }
                var sample = Sample(track: track.id, time: time)
                if let clip = track.clip(at: time) {
                    let local = time - clip.start
                    sample.media = clip.mediaID
                    sample.source = clip.sourceTime(atTimelineTime: time)
                    sample.enabled = clip.enabled
                    sample.holdEdges = clip.holdEdges
                    // An effect plays the same under another ID.
                    sample.video = clip.resolvedVideo(at: local)
                    sample.video.effects = sample.video.effects.map { var e = $0; e.id = ""; return e }
                    sample.audio = clip.resolvedAudio(at: local)
                    sample.audio.effects = sample.audio.effects.map { var e = $0; e.id = ""; return e }
                    if sample.audio.fadeIn > .zero { sample.fade *= min(1, local.seconds / sample.audio.fadeIn.seconds) }
                    if sample.audio.fadeOut > .zero { sample.fade *= min(1, (clip.end - time).seconds / sample.audio.fadeOut.seconds) }
                    sample.audio.fadeIn = .zero
                    sample.audio.fadeOut = .zero
                }
                samples.append(sample)
            }
            for transition in track.transitions {
                let window = transition.window(on: track).map { "\($0.start.flicks)-\($0.end.flicks)" } ?? "nowhere"
                samples.append(Sample(track: track.id, time: .zero, transition: "\(transition.id) \(transition.type.rawValue) \(window)"))
            }
        }
        return samples
    }

    func assertPlaysTheSame(_ before: Project, _ after: Project, file: StaticString = #filePath, line: UInt = #line) {
        let (a, b) = (played(before), played(after))
        XCTAssertEqual(a.count, b.count, "the timeline is as long", file: file, line: line)
        if let first = zip(a, b).first(where: { $0 != $1 }) {
            XCTFail("plays differently: \(String(describing: first.0)) became \(String(describing: first.1))", file: file, line: line)
        }
    }
}
