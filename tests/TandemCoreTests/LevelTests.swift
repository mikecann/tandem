import XCTest
@testable import TandemCore

/// Speech levelling: what placing sound sets, `normalizeSpeech`, the
/// project's speech level and the gain maths the render shares.
final class LevelTests: XCTestCase {
    /// A voice-over and a sound effect beside the fixture's take and music.
    func project() -> (Fixture, ProjectCoordinator) {
        var fixture = Fixture()
        fixture.project.media += [
            MediaItem(id: "med_vo", path: "vo/line.m4a", kind: .audio, role: .music, duration: t(20), hasAudio: true),
            MediaItem(id: "med_whoosh", path: "sfx/whoosh.wav", kind: .audio, role: .sfx, duration: t(1), hasAudio: true),
            MediaItem(id: "med_intro", path: "Intro.mp4", kind: .video, role: .other, duration: t(5), hasVideo: true, hasAudio: true)
        ]
        return (fixture, ProjectCoordinator(project: fixture.project))
    }

    // MARK: - Placing

    func testPlacedSpeechIsNormalisedAndMusicAndEffectsKeepTheirGains() throws {
        let (f, c) = project()
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(30)))
        try c.run("Music", .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(30)))
        try c.run("Whoosh", .placeMedia(mediaIDs: ["med_whoosh"], at: t(5)))
        let voice = c.clips("Voice")[0]
        XCTAssertEqual(voice.audio?.normalizeTo, AudioLevels.defaultSpeechLoudness)
        XCTAssertEqual(voice.audio?.normalizeTo, -20)
        XCTAssertEqual(voice.audio?.gainDB, 0)
        XCTAssertEqual(c.clips("Music")[0].audio, AudioProperties(gainDB: -31, fadeOut: t(2)))
        XCTAssertEqual(c.clips("SFX")[0].audio, AudioProperties(gainDB: -15))
        XCTAssertEqual(f.project.settings.speechLoudness, -20)
    }

    func testPlacingUsesTheProjectsSpeechLevel() throws {
        let (_, c) = project()
        try c.run("Level", .updateSettings(patch: .object(["speechLoudness": .number(-18)])))
        try c.run("Place", .placeMedia(mediaIDs: ["med_camera"], at: .zero, duration: t(10)))
        XCTAssertEqual(c.clips("Voice")[0].audio?.normalizeTo, -18)
    }

    func testAnythingPlacedOnASpeechTrackIsSpeech() throws {
        let (f, c) = project()
        // A voice-over the scanner took for music, dropped on Voice.
        try c.run("VO", .placeMedia(mediaIDs: ["med_vo"], at: t(40), audioTrackID: f.track("Voice").id))
        XCTAssertEqual(c.clips("Voice")[0].audio, AudioProperties(normalizeTo: -20))
        // Camera sound is speech wherever it goes.
        try c.run("Camera on SFX", .placeMedia(mediaIDs: ["med_camera"], at: t(70), duration: t(5), audioTrackID: f.track("SFX").id))
        XCTAssertEqual(c.clips("SFX")[0].audio?.normalizeTo, -20)
        // A file with no clearer role (a rendered intro) lands on Voice as speech.
        try c.run("Intro", .placeMedia(mediaIDs: ["med_intro"], at: t(100)))
        XCTAssertEqual(c.clips("Voice").last?.audio?.normalizeTo, -20)
        // The same music on the Music track keeps its bed level.
        try c.run("Music", .placeMedia(mediaIDs: ["med_vo"], at: t(40)))
        XCTAssertEqual(c.clips("Music")[0].audio?.gainDB, -31)
        XCTAssertNil(c.clips("Music")[0].audio?.normalizeTo)
    }

    /// The -31 dB a bed is placed at is set against the file as it is.
    /// Once the bed is levelled to a loudness, that gain would stack on top
    /// of it: Databased S2E7 and Convex 1.48 both exported with no music
    /// from `normalizeTo` -42 plus a forgotten -31 dB.
    func testNormalisingABedDropsThePlacedGain() throws {
        let (_, c) = project()
        try c.run("Music", .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(30)))
        let bed = c.clips("Music")[0]
        let result = try c.run("Level", .updateClip(clipID: bed.id, patch: .object(["audio": .object(["normalizeTo": .number(-42)])])))
        XCTAssertEqual(c.clips("Music")[0].audio, AudioProperties(fadeOut: t(2), normalizeTo: -42))
        XCTAssertTrue(result.warnings.contains { $0.contains("-31") }, "\(result.warnings)")

        // A gain given with the level is kept, and so is one set after it.
        try c.run("Level and trim", .updateClip(clipID: bed.id, patch: .object(["audio": .object(["normalizeTo": .null])])))
        try c.run("Level and trim", .updateClip(clipID: bed.id, patch: .object(["audio": .object(["normalizeTo": .number(-42), "gainDB": .number(-3)])])))
        XCTAssertEqual(c.clips("Music")[0].audio?.gainDB, -3)
        try c.run("New level", .updateClip(clipID: bed.id, patch: .object(["audio": .object(["normalizeTo": .number(-40)])])))
        XCTAssertEqual(c.clips("Music")[0].audio?.gainDB, -3)
    }

    /// A ducked bed's gain curve moves down with the gain, so the duck
    /// keeps its depth under the new level.
    func testNormalisingABedMovesItsGainCurveWithIt() throws {
        let (_, c) = project()
        try c.run("Music", .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(30)))
        let bed = c.clips("Music")[0]
        try c.run("Duck", .setKeyframes(clipID: bed.id, parameter: "audio.gainDB", keyframes: [
            Keyframe(time: .zero, value: .number(-31)), Keyframe(time: t(5), value: .number(-37))
        ]))
        try c.run("Level", .updateClip(clipID: bed.id, patch: .object(["audio": .object(["normalizeTo": .number(-42)])])))
        XCTAssertEqual(c.clips("Music")[0].keyframes["audio.gainDB"]?.map(\.value), [.number(0), .number(-6)])
    }

    // MARK: - Normalise speech clips

    /// A Filmora-style project: voice with hand gains, one clip on the old
    /// -14 default, music, a whoosh, and screen sound on Voice.
    func imported() throws -> ProjectCoordinator {
        let (f, c) = project()
        try c.run("Build",
            .placeMedia(mediaIDs: ["med_camera", "med_screen"], at: .zero, duration: t(30)),
            .placeMedia(mediaIDs: ["med_camera"], at: t(30), sourceStart: t(30), duration: t(10)),
            .placeMedia(mediaIDs: ["med_screen"], at: t(40), duration: t(5), audioTrackID: f.track("Voice").id, includeAudio: true),
            .placeMedia(mediaIDs: ["med_music"], at: .zero, duration: t(45)),
            .placeMedia(mediaIDs: ["med_whoosh"], at: t(5))
        )
        let voice = c.clips("Voice")
        try c.run("Filmora levels",
            .updateClip(clipID: voice[0].id, patch: .object(["audio": .object(["gainDB": .number(3.9), "normalizeTo": .null, "fadeOut": .number(0.5)])])),
            .updateClip(clipID: voice[1].id, patch: .object(["audio": .object(["normalizeTo": .number(-14), "voiceIsolation": .number(0.5)])])),
            .updateClip(clipID: voice[2].id, patch: .object(["audio": .object(["gainDB": .number(0.35), "normalizeTo": .null])]))
        )
        return c
    }

    func testNormalizeSpeechLevelsEverySpeechClipAsOneUndoStep() throws {
        let c = try imported()
        let before = c.project
        let result = try c.run("Normalise speech clips", .normalizeSpeech())
        XCTAssertEqual(result.warnings, [])
        for clip in c.clips("Voice") {
            XCTAssertEqual(clip.audio?.normalizeTo, -20, clip.id)
            XCTAssertEqual(clip.audio?.gainDB, 0, clip.id)
        }
        let voice = c.clips("Voice")
        XCTAssertEqual(voice[0].audio?.fadeOut, t(0.5), "fades stay")
        XCTAssertEqual(voice[1].audio?.voiceIsolation, 0.5, "voice isolation stays")
        XCTAssertEqual(c.clips("Music")[0].audio, before.track(named: "Music")!.clips[0].audio, "music keeps its gain")
        XCTAssertEqual(c.clips("SFX")[0].audio?.gainDB, -15, "sound effects keep theirs")
        assertValid(c.project)

        c.undo()
        XCTAssertEqual(c.project, before, "one undo puts every clip back")
    }

    /// Where speech plays: the project's speech level once it's levelled,
    /// or an import's own level before that.
    func testTheSpeechLevelIsWhereTheVoicePlays() throws {
        let c = try imported()
        // Levelled clips: -14 (10 s) is the only one; the others have
        // gains but no level, so they don't say.
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -14)
        try c.run("Normalise", .normalizeSpeech())
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -20)
        // Like the Decision Models import: every take at -28.74.
        for clip in c.clips("Voice") {
            try c.run("Import level", .updateClip(clipID: clip.id, patch: .object(["audio": .object(["normalizeTo": .number(-28.74)])])))
        }
        XCTAssertEqual(AudioLevels.speechLevel(in: c.project), -28.74, accuracy: 1e-9)
        // Nothing levelled: the project's speech level.
        XCTAssertEqual(AudioLevels.speechLevel(in: Project.standard(name: "Empty")), -20)
    }

    func testNormalizeSpeechSaysWhenThereIsNothingToDo() throws {
        let c = try imported()
        try c.run("Once", .normalizeSpeech())
        XCTAssertEqual(try c.run("Twice", .normalizeSpeech()).warnings, ["Every speech clip is already at -20 LUFS with no gain."])
        let empty = ProjectCoordinator(project: Project.standard(name: "Empty"))
        XCTAssertEqual(try empty.run("None", .normalizeSpeech()).warnings.first?.hasPrefix("There are no speech clips"), true)
    }

    func testNormalizeSpeechLeavesLockedTracksAndKeepsGainAnimation() throws {
        let c = try imported()
        let voice = c.clips("Voice")
        try c.run("Duck", .setKeyframes(clipID: voice[0].id, parameter: "audio.gainDB", keyframes: [
            Keyframe(time: t(1), value: .number(0)), Keyframe(time: t(2), value: .number(-6))
        ]))
        let locked = try c.run("Voice 2", .addTrack(kind: .audio, name: "Voice 2")).createdIDs[0]
        try c.run("PiP sound", .placeMedia(mediaIDs: ["med_camera"], at: t(50), duration: t(5), audioTrackID: locked))
        try c.run("Gain", .updateClip(clipID: c.project.track(locked)!.clips[0].id, patch: .object(["audio": .object(["gainDB": .number(4)])])))
        try c.run("Lock", .updateTrack(trackID: locked, patch: .object(["locked": .bool(true)])))

        let result = try c.run("Normalise speech clips", .normalizeSpeech())
        XCTAssertEqual(result.warnings, [
            "Locked track \"Voice 2\" was left as it was.",
            "1 speech clip keeps its gain animation, which plays on top of the level."
        ])
        XCTAssertEqual(c.project.track(locked)!.clips[0].audio?.gainDB, 4)
        XCTAssertEqual(c.clips("Voice")[0].keyframes["audio.gainDB"]?.count, 2)
        XCTAssertEqual(c.clips("Voice")[0].audio?.normalizeTo, -20)
    }

    // MARK: - Peaks

    /// Ian's whiteboard mic: about -43.5 LUFS with its loudest bump right
    /// at full scale, so levelling lifts it 23.5 dB and the bump to +23.4.
    /// The screen recording is loud already and keeps its peaks under.
    let quietMic: [String: MeasuredSound] = [
        "med_camera": MeasuredSound(integratedLUFS: -43.5, truePeakDBTP: -0.1),
        "med_screen": MeasuredSound(integratedLUFS: -19, truePeakDBTP: -6)
    ]

    func testNormalizeSpeechHoldsThePeaksLevellingWouldPushOver() throws {
        let c = try imported()
        let before = c.project
        let result = try c.run("Normalise speech clips", .normalizeSpeech(measured: quietMic))
        let voice = c.clips("Voice")
        for clip in voice where clip.mediaID == "med_camera" {
            XCTAssertEqual(clip.audio?.normalizeTo, -20, "the speech stays at the speech level")
            XCTAssertEqual(clip.audio?.effects.map(\.type), ["compressor", "limiter"], clip.id)
            let limiter = try XCTUnwrap(clip.audio?.effects.last)
            XCTAssertEqual(limiter.params["ceiling"], .number(-1), "the project's true peak ceiling")
            XCTAssertEqual(clip.audio?.effects.first?.params["threshold"], .number(-14), "6 dB over the speech level")
        }
        XCTAssertEqual(voice.last?.audio?.effects, [], "the screen's sound doesn't need holding")
        XCTAssertEqual(result.warnings, [
            "Levelled to -20 LUFS, 2 speech clips would peak at up to +23.4 dBTP, over the -1 dBTP ceiling, so they have a compressor and a limiter holding their peaks under -1 dBFS (\(voice[0].id), \(voice[1].id)). They're in each clip's audio effects: remove them to hear it as it was."
        ])
        assertValid(c.project)
        c.undo()
        XCTAssertEqual(c.project, before, "one undo takes them off again")
    }

    func testPeaksHeldOnceStayHeldAndALimiterTurnedOffStaysOff() throws {
        let c = try imported()
        try c.run("Normalise", .normalizeSpeech(measured: quietMic))
        let held = c.clips("Voice")
        // Mike turns the second clip's limiter off and takes the compressor away.
        let second = held[1]
        try c.run("Off", .updateEffect(clipID: second.id, effectID: second.audio!.effects[1].id, patch: .object(["enabled": .bool(false)])),
                  .removeEffect(clipID: second.id, effectID: second.audio!.effects[0].id))
        let result = try c.run("Again", .normalizeSpeech(measured: quietMic))
        XCTAssertEqual(result.warnings, ["Every speech clip is already at -20 LUFS with no gain."])
        XCTAssertEqual(c.clips("Voice")[0].audio?.effects, held[0].audio?.effects, "no second limiter")
        XCTAssertEqual(c.clips("Voice")[1].audio?.effects.map(\.type), ["limiter"])
        XCTAssertEqual(c.clips("Voice")[1].audio?.effects.first?.enabled, false)
    }

    /// Like Ian's project, where the camera's own sound sits muted under
    /// the mic: it's levelled, ready for unmuting, but nothing it doesn't
    /// play needs holding.
    func testSoundThatDoesntPlayIsLevelledButNotHeld() throws {
        let c = try imported()
        let voice = c.clips("Voice")
        try c.run("Mute", .updateClip(clipID: voice[0].id, patch: .object(["audio": .object(["muted": .bool(true)])])))
        let result = try c.run("Normalise", .normalizeSpeech(measured: quietMic))
        XCTAssertEqual(c.clips("Voice")[0].audio?.normalizeTo, -20)
        XCTAssertEqual(c.clips("Voice")[0].audio?.effects, [], "a muted clip")
        XCTAssertEqual(c.clips("Voice")[1].audio?.effects.count, 2)
        XCTAssertTrue(result.warnings.first?.contains("1 speech clip would peak at +23.4 dBTP") == true, "\(result.warnings)")

        try c.run("Mute Voice", .updateTrack(trackID: c.project.track(named: "Voice")!.id, patch: .object(["muted": .bool(true)])))
        try c.run("Unhold", .removeEffect(clipID: voice[1].id, effectID: c.clips("Voice")[1].audio!.effects[1].id))
        try c.run("Again", .normalizeSpeech(measured: quietMic))
        XCTAssertEqual(c.clips("Voice")[1].audio?.effects.map(\.type), ["compressor"], "a muted track")
    }

    func testTheLevelledPeakIsTheFilesPeakPlusTheLift() {
        let measured = MeasuredSound(integratedLUFS: -43.5, truePeakDBTP: -0.1)
        XCTAssertEqual(AudioLevels.levelledPeak(AudioProperties(normalizeTo: -20), measured: measured)!, 23.4, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.levelledPeak(AudioProperties(gainDB: -3, normalizeTo: -20), measured: measured)!, 20.4, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.levelledPeak(AudioProperties(gainDB: 2), measured: measured)!, 1.9, accuracy: 1e-9)
        XCTAssertNil(AudioLevels.levelledPeak(AudioProperties(), measured: MeasuredSound(integratedLUFS: -.infinity, truePeakDBTP: -.infinity)), "silence")
        var limited = AudioProperties()
        XCTAssertFalse(AudioLevels.holdsPeaks(limited))
        limited.effects = [Effect(type: "limiter", enabled: false)]
        XCTAssertFalse(AudioLevels.holdsPeaks(limited), "a limiter turned off holds nothing")
        limited.effects[0].enabled = true
        XCTAssertTrue(AudioLevels.holdsPeaks(limited))
    }

    /// Commands don't measure files, so the session fills in what the
    /// analysis measured before the batch runs, and the journal keeps it:
    /// a replay after a crash makes the same edit without the analysis.
    func testTheCoordinatorFillsInTheMeasurementsAndTheJournalKeepsThem() throws {
        let built = try imported()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ProjectJournal(url: folder.appendingPathComponent("j.jsonl"))
        let c = ProjectCoordinator(project: built.project, revision: built.revision, journal: journal)
        let mic = quietMic
        c.measureSound = { project in mic.filter { id, _ in project.media(id) != nil } }
        try c.run("Normalise speech clips", .normalizeSpeech())
        XCTAssertEqual(c.clips("Voice")[0].audio?.effects.map(\.type), ["compressor", "limiter"])
        let recovered = journal.recover(project: built.project, revision: built.revision)
        XCTAssertEqual(recovered?.project, c.project)
    }

    func testMeasurementsTravelInTheCommandsJSON() throws {
        let command = EditCommand.normalizeSpeech(measured: ["med_camera": MeasuredSound(integratedLUFS: -43.5, truePeakDBTP: -0.1)])
        let data = try JSONEncoder().encode(command)
        XCTAssertEqual(try JSONDecoder().decode(EditCommand.self, from: data), command)
        XCTAssertEqual(try JSONDecoder().decode(EditCommand.self, from: Data(#"{"normalizeSpeech": {}}"#.utf8)), .normalizeSpeech())
    }

    func testSpeechClipsAreCameraAndVoiceSoundAndTakeTracks() throws {
        let c = try imported()
        let speech = AudioLevels.speechClips(in: c.project)
        XCTAssertEqual(speech.map(\.track.name), ["Voice", "Voice", "Voice"])
        XCTAssertEqual(speech.map(\.clip.mediaID), ["med_camera", "med_camera", "med_screen"], "the screen's sound on Voice counts")
        XCTAssertFalse(AudioLevels.isSpeechTrack(c.project.track(named: "Music")!))
        XCTAssertTrue(AudioLevels.isSpeechTrack(c.project.track(named: "Voice")!))
        XCTAssertFalse(AudioLevels.isSpeechTrack(c.project.track(named: "Camera")!), "video tracks carry no sound")
    }

    // MARK: - The speech level setting

    func testChangingTheSpeechLevelMovesTheClipsAtTheOldLevel() throws {
        let c = try imported()
        try c.run("Normalise", .normalizeSpeech())
        let voice = c.clips("Voice")
        try c.run("Own level", .updateClip(clipID: voice[1].id, patch: .object(["audio": .object(["normalizeTo": .number(-24)])])))
        try c.run("Gain", .updateClip(clipID: voice[2].id, patch: .object(["audio": .object(["gainDB": .number(2)])])))

        try c.run("Speech level", .updateSettings(patch: .object(["speechLoudness": .number(-18)])))
        XCTAssertEqual(c.project.settings.speechLoudness, -18)
        XCTAssertEqual(c.clips("Voice").map(\.audio?.normalizeTo), [-18, -24, -18], "a clip with its own level keeps it")
        XCTAssertEqual(c.clips("Voice")[2].audio?.gainDB, 2, "gains stay")

        XCTAssertThrowsError(try c.run("Too loud", .updateSettings(patch: .object(["speechLoudness": .number(-3)]))))
        XCTAssertThrowsError(try c.run("Too quiet", .updateSettings(patch: .object(["speechLoudness": .number(-60)]))))
        XCTAssertEqual(c.project.settings.speechLoudness, -18)
    }

    func testProjectsFromBeforeTheSpeechLevelLoadWithTheDefault() throws {
        let old = #"{"width": 3840, "height": 2160, "loudnessTarget": -14, "truePeakCeiling": -1}"#
        let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.speechLoudness, -20)
        XCTAssertEqual(settings.loudnessTarget, -14)

        // A whole project file as the earlier build wrote it.
        var project = Project.standard(name: "Old")
        project.settings.speechLoudness = -17
        var json = try JSONSerialization.jsonObject(with: ProjectFile.encoder().encode(ProjectFile.Envelope(revision: 3, project: project))) as! [String: Any]
        var body = json["project"] as! [String: Any]
        var fields = body["settings"] as! [String: Any]
        XCTAssertEqual(fields.removeValue(forKey: "speechLoudness") as? Double, -17, "new files write it")
        body["settings"] = fields
        json["project"] = body
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("old.tandem")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        let loaded = try ProjectFile.load(from: url)
        XCTAssertEqual(loaded.project.settings.speechLoudness, -20)
        XCTAssertEqual(loaded.revision, 3)
    }

    // MARK: - Gain maths

    func testNormaliseGainIsTheTargetMinusTheMeasurementWithinThirtyDecibels() {
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -32.2)!, 12.2, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -14), -6)
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -70), 30, "at most +30 dB")
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -40, measuredLUFS: 0), -30, "at most -30 dB")
        XCTAssertEqual(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: -.infinity), 0, "a silent file has nothing to level")
        XCTAssertNil(AudioLevels.normalizeGainDB(target: -20, measuredLUFS: nil), "not measured yet")
    }

    func testGainIsAddedAfterNormalising() {
        let measured = -32.2
        XCTAssertEqual(AudioLevels.playbackLoudness(AudioProperties(gainDB: 2, normalizeTo: -20), measuredLUFS: measured)!, -18, accuracy: 1e-9)
        XCTAssertEqual(AudioLevels.playbackLoudness(AudioProperties(gainDB: 3.9), measuredLUFS: measured)!, -28.3, accuracy: 1e-9)
        XCTAssertNil(AudioLevels.playbackLoudness(AudioProperties(normalizeTo: -20), measuredLUFS: nil))
        XCTAssertNil(AudioLevels.playbackLoudness(AudioProperties(normalizeTo: -20), measuredLUFS: -.infinity))
    }
}
