import XCTest
@testable import TandemAPI
@testable import TandemCore

/// `tandem join`: through-edits found, listed and joined, with what plays
/// left exactly as it was.
final class JoinAPITests: XCTestCase {
    /// The fixture cut through at 10 s and 45 s (camera, screen, voice and
    /// the music bed under them), with the music after 45 s turned up, so
    /// that one cut can't join.
    func cutUp(_ h: ServiceHarness) throws -> Project {
        try h.apply(.blade(at: t(10)), .blade(at: t(45)), label: "Cut")
        let music = try XCTUnwrap(h.service.coordinator.project.track("trk_music")).clips
        XCTAssertEqual(music.count, 3)
        try h.apply(.updateClip(clipID: music[2].id, patch: .object(["audio": .object(["gainDB": .number(-28)])])), label: "Louder")
        return h.service.coordinator.project
    }

    func testADryRunListsThemAndChangesNothing() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let cut = try cutUp(h)
        let plan = try h.service.join(JoinRequest(), context: h.context)
        XCTAssertEqual(h.service.coordinator.project, cut, "a dry run changes nothing")
        XCTAssertNil(plan.applied)
        XCTAssertEqual(plan.revision, 3)
        XCTAssertEqual(plan.joins.map(\.time), [t(10), t(10), t(45)])
        XCTAssertEqual(plan.joins[0].clips.map(\.track), ["V2 Camera", "V1 Screen", "A1 Voice"], "the take joins as one, top track first")
        XCTAssertEqual(plan.joins[0].clips[0].clipID, "clip_cam1")
        XCTAssertEqual(plan.joins[1].clips.map(\.track), ["A2 Music"])
        XCTAssertEqual(plan.skipped.map(\.time), [t(45)])
        XCTAssertEqual(plan.skipped[0].track, "A2 Music")
        XCTAssertTrue(plan.skipped[0].reason.contains("different settings (gain)"), plan.skipped[0].reason)
        XCTAssertEqual(plan.commands, [.joinThroughEdits()])
        // The cut at 30 s jumps 2 s in the file, so it isn't one at all.
        XCTAssertFalse(plan.joins.contains { $0.time == t(30) })

        let text = plan.readableText
        XCTAssertTrue(text.hasPrefix("Join 3 through-edits (dry run, revision 3)"), text)
        XCTAssertTrue(text.contains("  00:10.000  V2 Camera clip_cam1 + "), text)
        XCTAssertTrue(text.contains("Leaves 1 cut that looks like a through-edit, as joining would change what plays:"), text)
        XCTAssertTrue(text.contains("Run again with --apply"), text)
    }

    /// Applied, the take is back as it was before the cuts, the music cut
    /// that can't join stays, and what plays hasn't changed.
    func testApplyingJoinsThemAndPlaysTheSame() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        let original = APIFixture.project()
        let cut = try cutUp(h)
        let result = try h.service.join(JoinRequest(apply: true), context: h.context)
        let applied = try XCTUnwrap(result.applied)
        XCTAssertEqual(applied.revision, 4)
        XCTAssertEqual(applied.label, "Join 3 through-edits")
        XCTAssertEqual(applied.author, "claude")
        XCTAssertEqual(result.warnings, [], "the cut it left is in skipped, not said again")
        XCTAssertTrue(result.readableText.contains("Applied as revision 4"), result.readableText)

        let joined = h.service.coordinator.project
        for id in ["trk_screen", "trk_camera", "trk_voice"] {
            XCTAssertEqual(joined.track(id), original.track(id), "\(id) is as it was before the cuts, its dissolve too")
        }
        XCTAssertEqual(joined.track("trk_music")?.clips.map(\.start), [t(0), t(45)])
        Self.assertPlaysTheSame(cut, joined)
        XCTAssertLessThan(Self.playedRanges(cut).stretches.count, cut.allTracks.flatMap(\.clips).count, "the check sees through the cuts")
        XCTAssertTrue(ProjectValidator.validate(joined).allSatisfy { $0.severity != .error })

        let again = try h.service.join(JoinRequest(apply: true), context: h.context)
        XCTAssertTrue(again.joins.isEmpty)
        XCTAssertNil(again.applied, "nothing left to join, so no edit")

        _ = try h.service.undo(expectedRevision: nil)
        XCTAssertEqual(h.service.coordinator.project, cut)
    }

    func testFromAndToOnlyJoinCutsBetweenThem() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        _ = try cutUp(h)
        let plan = try h.service.join(JoinRequest(from: t(40), to: t(50)), context: h.context)
        XCTAssertEqual(plan.joins.map(\.time), [t(45)])
        XCTAssertEqual(plan.skipped.map(\.time), [t(45)])
        guard case .joinThroughEdits(let range?) = plan.commands.first else { return XCTFail("\(plan.commands)") }
        XCTAssertEqual(range, TimeRange(start: t(40), end: t(50)))
        // A cut exactly at the ends counts.
        XCTAssertEqual(try h.service.join(JoinRequest(from: t(10), to: t(10)), context: h.context).joins.map(\.time), [t(10), t(10)])

        assertServiceError(.badRequest) { _ = try h.service.join(JoinRequest(from: t(50), to: t(40)), context: h.context) }
        assertServiceError(.staleRevision) { _ = try h.service.join(JoinRequest(apply: true, expectedRevision: 1), context: h.context) }
    }

    /// The single form through `apply`: joins one cut, or says why not.
    func testOneCutJoinsThroughApply() throws {
        let h = try ServiceHarness()
        defer { h.close() }
        _ = try cutUp(h)
        let result = try h.service.apply(ApplyRequest(commands: [try CommandJSON.decode(try json(#"{"join": {"clipID": "clip_cam1"}}"#))]), context: h.context)
        XCTAssertEqual(result.label, "Join a through-edit")
        XCTAssertEqual(result.removed.count, 3, "the right-hand camera, screen and voice pieces")
        XCTAssertEqual(Set(result.changed), ["clip_cam1", "clip_scr1", "clip_voc1"])
        XCTAssertEqual(h.service.coordinator.project.clip("clip_cam1")?.range, TimeRange(start: t(0), end: t(30)))

        // The take's own cut at 30 s jumps in the file.
        XCTAssertThrowsError(try h.apply(.join(clipID: "clip_cam1"))) { error in
            let message = (error as? ServiceError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("can't join clip_cam1 with clip_cam2") && message.contains("doesn't carry straight on"), message)
        }
    }

    // MARK: - Helpers

    /// A stretch of a file a track plays.
    struct Stretch: Equatable {
        var track: String
        var start: Time
        var end: Time
        var media: String?
        var from: Time
        var to: Time
        var fadeIn: Time
        var fadeOut: Time
        /// Everything else the clips play it with.
        var settings: Clip
    }

    /// What each track plays, as stretches of files: each clip's timeline
    /// range, file, the part of the file, fades and settings, with clips
    /// that carry straight on into each other (the same file and settings,
    /// no jump, no fade between) counted as one stretch. And where each
    /// transition plays.
    static func playedRanges(_ project: Project) -> (stretches: [Stretch], transitions: [String]) {
        var stretches: [Stretch] = []
        var transitions: [String] = []
        for track in project.allTracks {
            var previous: Clip?
            for clip in track.clips {
                defer { previous = clip }
                let settings = ThroughEdits.settings(clip)
                let fadeIn = clip.audio?.fadeIn ?? .zero
                let fadeOut = clip.audio?.fadeOut ?? .zero
                if var last = stretches.last, previous != nil, last.track == track.id, last.end == clip.start, last.media == clip.mediaID,
                   last.to == clip.sourceStart, last.settings == settings, last.fadeOut == .zero, fadeIn == .zero, clip.keyframes.isEmpty {
                    last.end = clip.end
                    last.to = clip.sourceEnd
                    last.fadeOut = fadeOut
                    stretches[stretches.count - 1] = last
                } else {
                    stretches.append(Stretch(
                        track: track.id, start: clip.start, end: clip.end, media: clip.mediaID, from: clip.sourceStart, to: clip.sourceEnd,
                        fadeIn: fadeIn, fadeOut: fadeOut, settings: settings
                    ))
                }
            }
            for transition in track.transitions {
                transitions.append("\(track.id) \(transition.type.rawValue) \(transition.window(on: track).map { "\($0.start)-\($0.end)" } ?? "nowhere")")
            }
        }
        return (stretches, transitions.sorted())
    }

    static func assertPlaysTheSame(_ before: Project, _ after: Project, file: StaticString = #filePath, line: UInt = #line) {
        let (a, b) = (playedRanges(before), playedRanges(after))
        XCTAssertEqual(a.stretches, b.stretches, file: file, line: line)
        XCTAssertEqual(a.transitions, b.transitions, file: file, line: line)
    }
}

/// `tandem join` as agents run it.
final class JoinCLITests: XCTestCase {
    private let cli = CLITests()

    func testAnAgentListsThenJoinsTheThroughEdits() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let cut = try cli.tandem("apply", #"[{"blade": {"at": 10}}, {"blade": {"at": 45}}]"#, "--author", "claude", in: folder.url)
        XCTAssertEqual(cut.status, 0, cut.stderr)
        let before = try ProjectFile.load(from: url).project

        let plan = try cli.tandem("join", in: folder.url)
        XCTAssertEqual(plan.status, 0, plan.stderr)
        XCTAssertTrue(plan.stdout.hasPrefix("Join 4 through-edits (dry run, revision 2)"), plan.stdout)
        XCTAssertEqual(try ProjectFile.load(from: url).project, before, "a dry run changes nothing")

        let json = try cli.tandem("join", "--from", "40", "--to", "0:50", "--json", in: folder.url)
        XCTAssertEqual(json.status, 0, json.stderr)
        let decoded = try ServiceJSON.decoder().decode(JoinResult.self, from: Data(json.stdout.utf8))
        XCTAssertEqual(decoded.joins.map(\.time), [t(45), t(45)])

        let applied = try cli.tandem("join", "--apply", "--expect", "2", "--label", "Join the take back up", "--author", "claude", in: folder.url)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.contains("Applied as revision 3 (\"Join the take back up\")"), applied.stdout)
        let joined = try ProjectFile.load(from: url).project
        let original = APIFixture.project()
        for id in ["trk_screen", "trk_camera", "trk_voice", "trk_music"] {
            XCTAssertEqual(joined.track(id), original.track(id), id)
        }
        JoinAPITests.assertPlaysTheSame(before, joined)

        // One cut through apply, and why one can't join.
        let refused = try cli.tandem("apply", #"{"join": {"clipID": "clip_cam1"}}"#, in: folder.url)
        XCTAssertEqual(refused.status, 1)
        XCTAssertTrue(refused.stderr.contains("doesn't carry straight on"), refused.stderr)

        let help = try cli.tandem("help", "join", in: folder.url)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem join"), help.stdout)
    }
}
