import Foundation
import XCTest
@testable import TandemAPI
import TandemAssets
@testable import TandemCore

/// A library in a temp folder holding the two section card whooshes under
/// their real IDs, or none.
enum CardSoundsFixture {
    static func library(at root: URL, withSounds: Bool = true) throws -> AssetLibrary {
        let library = try AssetLibrary(root: root, previewFolder: root.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
        guard withSounds else { return library }
        for (sound, seconds) in [(SectionCardSounds.whooshIn, 1.2), (SectionCardSounds.whooshOut, 1.0)] {
            let parts = sound.assetID.split(separator: ":", maxSplits: 1).map(String.init)
            var asset = Asset(provider: parts[0], providerID: parts[1], kind: .sfx, name: "Whoosh", duration: seconds)
            try AssetFixtures.wav(at: library.folder(for: asset).appendingPathComponent("original.wav"), seconds: seconds)
            asset.state = .normalised
            asset.files = AssetFiles(original: "original.wav")
            try library.catalog.upsert(asset)
        }
        return library
    }
}

/// `cards`: a section card at every section marker, from the service, the
/// CLI and the timeline dump.
final class SectionCardsAPITests: XCTestCase {
    /// The fixture (Section 2 at 30) plus the cold open at 0 and
    /// Methodology at 8, with a note.
    static func project() -> Project {
        var project = APIFixture.project()
        project.markers += [
            Marker(id: "mk_open", time: .zero, name: "Cold open", kind: .section),
            Marker(id: "mk_method", time: t(8), name: "Methodology", kind: .section, note: "Let's keep it fair")
        ]
        project.markers.sort { $0.time < $1.time }
        return project
    }

    func cards(_ project: Project) -> [(clip: Clip, props: SectionCard.Props)] {
        project.videoTracks.flatMap(\.clips).compactMap { clip in SectionCard.props(of: clip).map { (clip, $0) } }.sorted { $0.clip.start < $1.clip.start }
    }

    func testDryRunThenApplyWithTheWhooshes() async throws {
        let folder = TempFolder("tandem-cards")
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        h.service.soundLibrary = try CardSoundsFixture.library(at: folder.url.appendingPathComponent("library"))
        let sfx = h.url.deletingLastPathComponent().appendingPathComponent("assets/sfx")

        let plan = try await h.service.cards(CardsRequest(), context: h.context)
        XCTAssertNil(plan.applied)
        XCTAssertEqual(plan.cards.map(\.number), ["01", "02"])
        XCTAssertEqual(plan.cards.map(\.title), ["Methodology", "Section 2"])
        XCTAssertEqual(plan.cards.first?.subtitle, "Let's keep it fair")
        XCTAssertTrue(plan.sounds.hasPrefix("a whoosh on each sweep"), plan.sounds)
        XCTAssertEqual(h.service.coordinator.revision, 1, "a dry run changes nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sfx.path), "or copies anything")
        let text = plan.readableText
        XCTAssertTrue(text.hasPrefix("2 section cards (dry run, revision 1):"), text)
        XCTAssertTrue(text.contains(#"01  00:08.000  "Methodology" / "Let's keep it fair"  card 00:07.567-00:11.767 (4.2 s)"#), text)
        XCTAssertTrue(text.contains("Run again with --apply"), text)

        let applied = try await h.service.cards(CardsRequest(kicker: "Section", apply: true), context: h.context)
        XCTAssertEqual(applied.applied?.revision, 2)
        XCTAssertEqual(applied.applied?.label, "Add 2 section cards")
        let project = h.service.coordinator.project
        let made = cards(project)
        XCTAssertEqual(made.map(\.props.label), ["01 Methodology", "02 Section 2"])
        XCTAssertEqual(made.map(\.props.kickerLine), ["Section 1 of 2", "Section 2 of 2"])
        // Fitted to their words: "Methodology Let's keep it fair Section
        // 1 of 2" is 45 characters, 2.2 + 45 / 15 = 5.2 s.
        XCTAssertEqual(made.map { $0.clip.duration.seconds }, [5.2, 4])
        XCTAssertEqual(applied.cards.map { ($0.end - $0.start).seconds }, [5.2, 4], "as planned")
        let sounds = project.track(named: "SFX")?.clips ?? []
        XCTAssertEqual(sounds.count, 4, "a whoosh in and out for each card")
        XCTAssertEqual(Set(sounds.compactMap(\.linkGroup)), Set(made.compactMap(\.clip.linkGroup)))
        for card in made {
            let own = sounds.filter { $0.linkGroup == card.clip.linkGroup }.sorted { $0.start < $1.start }
            let motion = SectionCard.Motion(duration: card.clip.duration, width: project.settings.width, height: project.settings.height)
            XCTAssertEqual(own.map(\.start), [card.clip.start, card.clip.start + Time(seconds: motion.outStart(0))], "each swish starts with its sweep")
        }
        let media = project.media.filter { $0.path.hasPrefix("assets/sfx/") }
        XCTAssertEqual(media.count, 2)
        for item in media {
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.url.deletingLastPathComponent().appendingPathComponent(item.path).path), item.path)
        }
        // The fixture's speech plays at -14 LUFS, 6 dB over the -20 the
        // gains are set against, so the whooshes come up 6 dB to stay as
        // far under it.
        XCTAssertEqual(AudioLevels.speechLevel(in: project), -14)
        XCTAssertEqual(Set(sounds.compactMap(\.audio?.gainDB)), [0.6, -2.3], "-5.4 and -8.3, up 6 dB")

        // Running it again renumbers what's there, and adds nothing.
        let again = try await h.service.cards(CardsRequest(apply: true), context: h.context)
        XCTAssertEqual(again.cards.compactMap(\.existingClipID).count, 2)
        XCTAssertEqual(again.sounds, "the cards there keep their sounds")
        XCTAssertEqual(cards(h.service.coordinator.project).count, 2)
        XCTAssertEqual(h.service.coordinator.project.track(named: "SFX")?.clips.count, 4)
        XCTAssertTrue(again.readableText.contains("already there, renumbered"), again.readableText)
    }

    /// The whooshes sit 15 LU under the voice wherever it plays: set for
    /// speech at -20 LUFS, moved for a project whose speech plays elsewhere.
    func testTheWhooshesFollowTheSpeechLevel() {
        let sounds = SectionCardSounds.Resolved(
            media: [],
            soundIn: SectionCardSound(mediaID: "med_in", gainDB: SectionCardSounds.whooshIn.gainDB),
            soundOut: SectionCardSound(mediaID: "med_out", gainDB: SectionCardSounds.whooshOut.gainDB)
        )
        XCTAssertEqual(SectionCardSounds.whooshIn.gainDB, -5.4, "-29.6 LUFS at its loudest, to -35")
        XCTAssertEqual(SectionCardSounds.whooshOut.gainDB, -8.3, "-26.7 LUFS at its loudest, to -35")
        var imported = Self.project()
        for index in imported.audioTracks[0].clips.indices {
            imported.audioTracks[0].clips[index].audio = AudioProperties(normalizeTo: -28.74)
        }
        let levelled = sounds.levelled(for: imported)
        XCTAssertEqual(levelled.soundIn.gainDB, -14.1, "8.7 dB quieter against speech at -28.7")
        XCTAssertEqual(levelled.soundOut.gainDB, -17.0)
        XCTAssertEqual(levelled.speechLevel, -28.74)
        XCTAssertEqual(levelled.levelled(for: imported), levelled, "levelling twice changes nothing")
        var standard = imported
        for index in standard.audioTracks[0].clips.indices {
            standard.audioTracks[0].clips[index].audio = AudioProperties(normalizeTo: -20)
        }
        XCTAssertEqual(sounds.levelled(for: standard), sounds, "at Tandem's speech level they're as set")
        XCTAssertEqual(levelled.levelled(for: standard).soundIn.gainDB, -5.4, "and back")
    }

    func testSilentWithoutTheWhooshes() async throws {
        let folder = TempFolder("tandem-cards")
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        h.service.soundLibrary = try CardSoundsFixture.library(at: folder.url.appendingPathComponent("library"), withSounds: false)
        let dry = try await h.service.cards(CardsRequest(), context: h.context)
        XCTAssertTrue(dry.sounds.hasPrefix("silent"), dry.sounds)
        let applied = try await h.service.cards(CardsRequest(apply: true), context: h.context)
        XCTAssertTrue(applied.sounds.hasPrefix("silent"), applied.sounds)
        XCTAssertEqual(cards(h.service.coordinator.project).count, 2)
        XCTAssertEqual(h.service.coordinator.project.track(named: "SFX")?.clips.count, 0)
        // And none asked for.
        let quiet = try await h.service.cards(CardsRequest(markers: ["mk_s2"], sounds: false), context: h.context)
        XCTAssertEqual(quiet.sounds, "no sounds (asked for none)")
    }

    /// Mike's Daytona video: each section marker sat right on the section's
    /// first word, where the transcript starts it ("Now," at 15:03.33), in a
    /// pause tightened with its cut 0.1 s before the word. Making room for
    /// the card right at the marker left a 0.1 s sliver of the take before
    /// the gap and started the section on the word's first sound, so "Now"
    /// was clipped. The take is cut in the pause before the word instead,
    /// here at the cut already there, so nothing is left behind.
    func testInsertCutsInThePauseBeforeTheSectionsFirstWord() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        // The pause from "section." (29.9) to "Now" (30.5), across the cut
        // at 30, tightened the way `tandem tighten` does it: 0.1 s kept on
        // each side of the cut, which stays at 30.
        let tightened = try h.service.tighten(TightenRequest(min: 0.5, keep: 0.15, apply: true, from: t(29.5), to: t(31)), context: h.context)
        XCTAssertEqual(tightened.cuts.map(\.cut), [TimeRange(start: t(30), end: t(30.4))])
        func now() throws -> WordTiming {
            try XCTUnwrap(h.service.transcript(id: nil, from: nil, to: nil).words.first { $0.text == "Now" })
        }
        XCTAssertEqual(try now().start, t(30.1))
        // The marker right on the word, as the agent put it.
        try h.apply(.updateMarker(markerID: "mk_s2", patch: .object(["time": .number(30.1)])))
        let take = ["Screen", "Camera", "Voice"]
        let before = take.map { h.service.coordinator.project.track(named: $0)!.clips }

        // The plan says where the take is cut, and why.
        let plan = try await h.service.cards(CardsRequest(insert: true, sounds: false), context: h.context)
        XCTAssertEqual(plan.cards.map(\.cut), [t(30)])
        XCTAssertEqual(plan.commands.last, .addSectionCards(mode: .insert, cuts: ["mk_s2": t(30)]))
        XCTAssertTrue(plan.readableText.contains("take cut at 00:30.000"), plan.readableText)
        XCTAssertTrue(plan.warnings.contains(#"The marker "Section 2" is on "Now", so the take is cut 0.100s earlier, at 00:30.000, in the pause before the word, so the word isn't clipped."#), "\(plan.warnings)")
        // Laid over the take, nothing is cut, so nothing moves.
        let over = try await h.service.cards(CardsRequest(sounds: false), context: h.context)
        XCTAssertEqual(over.cards.map(\.cut), [nil])
        XCTAssertEqual(over.cards.map(\.start), [Time.frames(890, at: .fps30)], "0.43 s before the marker, on a frame, as before")
        XCTAssertFalse(over.warnings.contains { $0.contains("\"Now\"") })

        let result = try await h.service.cards(CardsRequest(insert: true, sounds: false, apply: true), context: h.context)
        let project = h.service.coordinator.project
        for (name, clips) in zip(take, before) {
            let after = try XCTUnwrap(project.track(named: name)).clips
            XCTAssertEqual(after.count, clips.count, "\(name): the room goes at the cut already there, so no sliver is cut off")
            XCTAssertEqual(after.map(\.sourceStart), clips.map(\.sourceStart), name)
            XCTAssertEqual(after.map(\.duration), clips.map(\.duration), name)
            XCTAssertEqual(after[0].end, t(30), "\(name): the section before plays up to the cut")
            XCTAssertGreaterThan(after[1].start, after[0].end, "\(name): the room is between the sections")
        }
        // No cut on or just before the word's first sound: the section
        // starts 0.1 s before "Now", as it did before the room.
        let spoken = try now()
        for name in take {
            for clip in try XCTUnwrap(project.track(named: name)).clips {
                for edge in [clip.start, clip.end] {
                    XCTAssertFalse(edge > spoken.start - t(0.05) && edge < spoken.end, "\(name) is cut at \(edge), on \"Now\" (\(spoken.start))")
                }
            }
        }
        let voice = try XCTUnwrap(project.track(named: "Voice")).clips
        XCTAssertEqual(spoken.start - voice[1].start, t(0.1))
        XCTAssertEqual(project.markers.first { $0.id == "mk_s2" }?.time, spoken.start, "the marker stays on its word")
        // The card hides the frame from the cut on.
        let card = try XCTUnwrap(cards(project).first)
        let covered = try XCTUnwrap(SectionCard.Motion(duration: card.clip.duration, width: project.settings.width, height: project.settings.height).covered)
        XCTAssertLessThanOrEqual(card.clip.start + Time(seconds: covered.lowerBound), t(30))
        XCTAssertEqual(voice[1].start.seconds, (card.clip.start + Time(seconds: covered.upperBound)).seconds, accuracy: 1.0 / 30, "the section starts as the wipe out shows it")
        XCTAssertTrue(result.warnings.contains { $0.contains("\"Now\"") }, "\(result.warnings)")

        // The card still covers its marker, so running it again finds it.
        let again = try await h.service.cards(CardsRequest(insert: true, sounds: false, apply: true), context: h.context)
        XCTAssertEqual(again.cards.map(\.existingClipID), [card.clip.id])
        XCTAssertEqual(again.cards.map(\.cut), [nil])
        XCTAssertEqual(h.service.coordinator.project.track(named: "Voice")?.clips, voice, "no more room")
        XCTAssertEqual(cards(h.service.coordinator.project).count, 1)
    }

    func testMistakesComeBackAsServiceErrors() async throws {
        let h = try ServiceHarness()
        defer { h.close() }
        do {
            _ = try await h.service.cards(CardsRequest(markers: ["mk_nope"]), context: h.context)
            XCTFail("unknown marker")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "notFound")
        }
        do {
            _ = try await h.service.cards(CardsRequest(expectedRevision: 7), context: h.context)
            XCTFail("stale")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, "staleRevision")
        }
    }

    func testRequestsReadFriendlyForms() throws {
        let request = try ServiceJSON.decodeRequest(CardsRequest.self, from: Data(#"{"markers": ["mk_a"], "duration": "0:04", "kicker": "Tip", "insert": true, "sounds": false, "apply": true}"#.utf8))
        XCTAssertEqual(request.markers, ["mk_a"])
        XCTAssertEqual(request.duration, t(4))
        XCTAssertEqual(request.kicker, "Tip")
        XCTAssertEqual(request.insert, true)
        XCTAssertEqual(request.sounds, false)
        XCTAssertTrue(request.changesProject)
        XCTAssertFalse(CardsRequest().changesProject)
        XCTAssertTrue(ServiceOperation.cards.edits)
        XCTAssertNotNil(MCPTools.named("cards"))
    }

    func testTheTimelineDumpNamesTheCards() throws {
        let h = try ServiceHarness(project: Self.project())
        defer { h.close() }
        try h.apply(.addSectionCards(kicker: "Section"))
        let dump = TimelineDump.render(h.service.coordinator.project, revision: 1)
        XCTAssertTrue(dump.contains(#"section card 01 "Methodology" / "Let's keep it fair" 1 of 2 kicker Section"#), dump)
        let card = try XCTUnwrap(cards(h.service.coordinator.project).first)
        try h.apply(.updateClip(clipID: card.clip.id, patch: .object(["content": .object(["graphic": .object(["props": .object(["cursor": .bool(false)])])])])))
        let quiet = TimelineDump.render(h.service.coordinator.project, revision: 2)
        XCTAssertTrue(quiet.contains(#"1 of 2 kicker Section no cursor"#), quiet)
    }

    func testTheCLIPlansThenAddsThem() async throws {
        let cli = CLITests()
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder("tandem-cards-cli")
        let root = folder.url.appendingPathComponent("library", isDirectory: true)
        _ = try CardSoundsFixture.library(at: root)
        let env = ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"]
        let video = folder.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let projectURL = try APIFixture.write(to: video, project: Self.project())

        let plan = try cli.tandem("cards", in: video, env: env)
        XCTAssertEqual(plan.status, 0, plan.stderr)
        XCTAssertTrue(plan.stdout.hasPrefix("2 section cards (dry run, revision 1):"), plan.stdout)
        XCTAssertEqual(cards(try ProjectFile.load(from: projectURL).project).count, 0)

        let applied = try cli.tandem("cards", "--kicker", "Tip", "--apply", "--author", "claude", in: video, env: env)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.contains("Sound: a whoosh on each sweep"), applied.stdout)
        let project = try ProjectFile.load(from: projectURL).project
        XCTAssertEqual(cards(project).map(\.props.kickerLine), ["Tip 1 of 2", "Tip 2 of 2"])
        XCTAssertEqual(project.track(named: "SFX")?.clips.count, 4)
        let history = try cli.tandem("history", in: video)
        XCTAssertTrue(history.stdout.contains("Add 2 section cards  (claude)"), history.stdout)

        let usage = try cli.tandem("cards", "--insert", "--bogus", in: video, env: env)
        XCTAssertEqual(usage.status, 2, "a usage mistake")
    }
}
