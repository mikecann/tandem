import AVFoundation
import XCTest
@testable import TandemAPI
import TandemAssets
import TandemMedia
import ImageIO
@testable import TandemCore

/// Runs the built `tandem` binary, the way Mike and agents do.
final class CLITests: XCTestCase {
    static var binary: URL {
        Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("tandem")
    }

    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// A shared library nothing makes, so commands run here never look in
    /// the real ~/Movies/Tandem Library.
    static let noSharedLibrary = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tests-no-shared-library-\(UUID().uuidString)").path
    /// Settings nothing writes, so commands run here never use Mike's.
    static let noSettings = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tests-no-settings-\(UUID().uuidString).json").path

    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TANDEM_PROJECT")
        environment.removeValue(forKey: "TANDEM_AUTHOR")
        environment["TANDEM_LIBRARY"] = noSharedLibrary
        environment["TANDEM_SETTINGS"] = noSettings
        environment.merge(extra) { $1 }
        return environment
    }

    @discardableResult
    func tandem(_ arguments: String..., in folder: URL, stdin: String? = nil, env: [String: String] = [:]) throws -> Output {
        try tandem(arguments, in: folder, stdin: stdin, env: env)
    }

    func tandem(_ arguments: [String], in folder: URL, stdin: String? = nil, env: [String: String] = [:]) throws -> Output {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = Self.environment(env)
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        let exited = ExitSignal(process)
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        var errorData = Data()
        let reader = Thread { errorData = errors.fileHandleForReading.readDataToEndOfFile() }
        reader.start()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        return Output(status: process.terminationStatus, stdout: String(decoding: outputData, as: UTF8.self), stderr: String(decoding: errorData, as: UTF8.self))
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.binary.path), "tandem isn't built at \(Self.binary.path)")
    }

    func testHelpVersionAndUsageErrors() throws {
        let folder = TempFolder()
        let version = try tandem("--version", in: folder.url)
        XCTAssertEqual(version.status, 0)
        XCTAssertEqual(version.stdout, "tandem \(TandemAPI.version)\n")

        let bare = try tandem(in: folder.url)
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.stdout.contains("Commands:"), bare.stdout)

        let help = try tandem("help", "tighten", in: folder.url)
        XCTAssertEqual(help.status, 0)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem tighten"), help.stdout)

        let typo = try tandem("statsu", in: folder.url)
        XCTAssertEqual(typo.status, 2)
        XCTAssertTrue(typo.stderr.contains("Did you mean `tandem status`?"), typo.stderr)

        let option = try tandem("pauses", "--mni", "1", in: folder.url)
        XCTAssertEqual(option.status, 2)
        XCTAssertTrue(option.stderr.contains("Unknown option --mni. Did you mean --min?"), option.stderr)

        let wrong = try tandem("timeline", "--min", "3", in: folder.url)
        XCTAssertEqual(wrong.status, 2)
        XCTAssertTrue(wrong.stderr.contains("`tandem timeline` doesn't take --min"), wrong.stderr)

        let noProject = try tandem("status", in: folder.url)
        XCTAssertEqual(noProject.status, 1)
        XCTAssertTrue(noProject.stderr.contains("No .tandem project"), noProject.stderr)

        // What an export leaves beside its video is a record, not a project.
        try Data("{}".utf8).write(to: folder.file("review 1:00-1:20.mp4.tandem"))
        XCTAssertTrue(ProjectLocator.isRenderSnapshot(folder.file("review 1:00-1:20.mp4.tandem")))
        XCTAssertFalse(ProjectLocator.isRenderSnapshot(folder.file("Daytona.tandem")))
        let snapshotOnly = try tandem("status", in: folder.url)
        XCTAssertTrue(snapshotOnly.stderr.contains("No .tandem project"), snapshotOnly.stderr)

        let badTime = try tandem("frame", "soon", in: folder.url)
        XCTAssertEqual(badTime.status, 2)
        XCTAssertTrue(badTime.stderr.contains("isn't a time"), badTime.stderr)
    }

    func testHelpExplainsEditCommandsFromTheSchema() throws {
        let folder = TempFolder()
        let help = try tandem("help", "addTransition", in: folder.url)
        XCTAssertEqual(help.status, 0, help.stderr)
        XCTAssertTrue(help.stdout.hasPrefix("addTransition (an edit command for tandem apply): Adds a transition"), help.stdout)
        XCTAssertTrue(help.stdout.contains("trackID"), help.stdout)
        XCTAssertTrue(help.stdout.contains("required"), help.stdout)
        XCTAssertTrue(help.stdout.contains(#"{"addTransition": {"trackID": "trk_camera""#), help.stdout)

        let anyCase = try tandem("help", "addtransition", in: folder.url)
        XCTAssertEqual(anyCase.stdout, help.stdout)

        // join is a CLI command and an edit command: both are explained.
        let join = try tandem("help", "join", in: folder.url)
        XCTAssertTrue(join.stdout.hasPrefix("Usage: tandem join"), join.stdout)
        XCTAssertTrue(join.stdout.contains(#"{"join": {"clipID""#), join.stdout)

        let typo = try tandem("help", "addTransiton", in: folder.url)
        XCTAssertEqual(typo.status, 2)
        XCTAssertTrue(typo.stderr.contains("Did you mean `tandem help addTransition`?"), typo.stderr)

        let overview = try tandem("help", in: folder.url)
        XCTAssertTrue(overview.stdout.contains("tandem help <edit command>"), overview.stdout)
    }

    func testFramesWritesOneContactSheet() throws {
        let folder = TempFolder()
        XCTAssertEqual(try tandem("new", "Sheet.tandem", in: folder.url).status, 0)
        let screen = try XCTUnwrap(try ProjectFile.load(from: folder.file("Sheet.tandem")).project.track(named: "Screen")).id
        let solid = try tandem("apply", #"{"insertClip": {"trackID": "\#(screen)", "clip": {"content": {"solid": {"color": {"r": 0.2, "g": 0.4, "b": 0.8}}}, "start": 0, "duration": 4}}}"#, in: folder.url)
        XCTAssertEqual(solid.status, 0, solid.stderr)
        let named = try tandem("frames", "0", "0:01.5", "1", in: folder.url)
        XCTAssertEqual(named.status, 0, named.stderr)
        XCTAssertTrue(named.stdout.contains("3 frames"), named.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("frames-00.00.000-00.01.500.png").path), named.stdout)

        let stepped = try tandem("frames", "--every", "1", "--to", "3", "--width", "160", "-o", "sheets/step.png", in: folder.url)
        XCTAssertEqual(stepped.status, 0, stepped.stderr)
        XCTAssertTrue(stepped.stdout.contains("4 frames"), stepped.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("sheets/step.png").path))

        let nothing = try tandem("frames", in: folder.url)
        XCTAssertEqual(nothing.status, 2)
        XCTAssertTrue(nothing.stderr.contains("--every"), nothing.stderr)
    }

    func testApplyTakesTheBatchQuotedAsItsArgument() throws {
        // As `tandem media` suggests fixes: tandem apply '{"updateMedia": ...}'.
        let folder = TempFolder()
        XCTAssertEqual(try tandem("new", "Inline.tandem", in: folder.url).status, 0)
        let inline = try tandem("apply", #"  {"addMarker": {"marker": {"id": "mk_inline", "time": 2, "name": "Inline"}}}"#, in: folder.url)
        XCTAssertEqual(inline.status, 0, inline.stderr)
        XCTAssertNotNil(try ProjectFile.load(from: folder.file("Inline.tandem")).project.markers.first { $0.id == "mk_inline" })
        let missing = try tandem("apply", "nope.json", in: folder.url)
        XCTAssertEqual(missing.status, 2)
        XCTAssertTrue(missing.stderr.contains("Couldn't read"), missing.stderr)
    }

    func testHeadlessEditLoop() throws {
        let folder = TempFolder()
        let created = try tandem("new", "Loop.tandem", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        XCTAssertTrue(created.stdout.contains("with 8 tracks"), created.stdout)

        let batch = #"""
        {"label": "Place the take", "commands": [
          {"addMedia": {"item": {"id": "med_cam", "path": "source/t1-camera.mov", "kind": "video", "role": "camera", "takeID": "t1", "takeOffset": 0.5, "duration": 60, "hasVideo": true, "hasAudio": true}}},
          {"addMedia": {"item": {"id": "med_scr", "path": "source/t1-screen.mov", "kind": "video", "role": "screen", "takeID": "t1", "duration": 61, "hasVideo": true, "hasAudio": true}}},
          {"placeMedia": {"mediaIDs": ["med_cam", "med_scr"], "at": 0}}
        ]}
        """#
        try batch.write(to: folder.file("batch.json"), atomically: true, encoding: .utf8)
        let applied = try tandem("apply", "batch.json", in: folder.url)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.hasPrefix("Applied \"Place the take\" by cli as revision 1."), applied.stdout)

        let timeline = try tandem("timeline", in: folder.url)
        XCTAssertEqual(timeline.status, 0)
        XCTAssertTrue(timeline.stdout.contains("t1-camera.mov [00:00.000-01:00.000]  linked #1  level -20 LUFS"), timeline.stdout)

        let cut = try tandem("apply", "-", "--author", "claude", in: folder.url, stdin: #"{"blade": {"at": "0:10"}}"#)
        XCTAssertEqual(cut.status, 0, cut.stderr)
        XCTAssertTrue(cut.stdout.hasPrefix("Applied \"Cut at 00:10.000\" by claude as revision 2."), cut.stdout)

        let dry = try tandem("apply", "-", "--dry-run", in: folder.url, stdin: #"[{"rippleDeleteRange": {"range": {"start": 20, "end": 22}}}]"#)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.contains("it would work"), dry.stdout)

        let history = try tandem("history", in: folder.url)
        XCTAssertTrue(history.stdout.contains("Cut at 00:10.000  (claude)  at 00:10.000 on V2 Camera, V1 Screen, A1 Voice\n  Place the take  (cli)"), history.stdout)

        let undo = try tandem("undo", "--expect", "2", in: folder.url)
        XCTAssertEqual(undo.status, 0, undo.stderr)
        XCTAssertEqual(undo.stdout, "Undid \"Cut at 00:10.000\" (by claude). Now at revision 3.\n")

        let status = try tandem("status", "--json", in: folder.url)
        let decoded = try ServiceJSON.decoder().decode(StatusResult.self, from: Data(status.stdout.utf8))
        XCTAssertEqual(decoded.revision, 3)
        XCTAssertEqual(decoded.redo, "Cut at 00:10.000")
        XCTAssertTrue(decoded.headless)

        let invalid = try tandem("validate", in: folder.url)
        XCTAssertEqual(invalid.status, 1, "the media files don't exist")
        XCTAssertTrue(invalid.stdout.contains("source/t1-camera.mov is missing"), invalid.stdout)

        // The take covers the timeline, so the checks that need no
        // rendering find nothing.
        let check = try tandem("check", "--quick", in: folder.url)
        XCTAssertEqual(check.status, 0, check.stdout + check.stderr)
        XCTAssertTrue(check.stdout.hasPrefix("Checked 00:00.000-"), check.stdout)
        XCTAssertTrue(check.stdout.contains("(quick: no frames rendered)") && check.stdout.contains("no problems."), check.stdout)
        let cuts = try tandem("check", "--cuts", in: folder.url)
        XCTAssertEqual(cuts.status, 0, cuts.stdout + cuts.stderr)
        XCTAssertTrue(cuts.stdout.contains("cut edge") && cuts.stdout.contains("so its cuts weren't checked."), "the file isn't there to listen to: \(cuts.stdout)")
        let backwards = try tandem("check", "--from", "20", "--to", "10", in: folder.url)
        XCTAssertEqual(backwards.status, 1)
        XCTAssertTrue(backwards.stderr.contains("Nothing to check between"), backwards.stderr)

        let bad = try tandem("apply", "-", "--json", in: folder.url, stdin: #"{"trim": {"clipID": "x", "edge": "end", "to": 5, "rippel": true}}"#)
        XCTAssertEqual(bad.status, 1)
        let envelope = try ServiceJSON.decoder().decode(ErrorEnvelope.self, from: Data(bad.stdout.utf8))
        XCTAssertEqual(envelope.error.code, "badRequest")
        XCTAssertTrue(envelope.error.message.contains("did you mean \"ripple\""), envelope.error.message)

        // Without transcripts the tools say so instead of inventing pauses.
        let pauses = try tandem("pauses", in: folder.url)
        XCTAssertEqual(pauses.status, 0)
        XCTAssertTrue(pauses.stdout.contains("No transcript yet for med_cam"), pauses.stdout)
        let tighten = try tandem("tighten", "--mike", "--mid", "0.1", "--widen", "--protect", "0:10,20.5", "--json", in: folder.url)
        XCTAssertEqual(tighten.status, 0, tighten.stderr)
        let plan = try ServiceJSON.decoder().decode(TightenResult.self, from: Data(tighten.stdout.utf8))
        XCTAssertEqual(plan.sentence, Time(seconds: 0.4))
        XCTAssertEqual(plan.mid, Time(seconds: 0.1))
        XCTAssertTrue(plan.cuts.isEmpty && plan.widened.isEmpty)
        let both = try tandem("tighten", "--keep", "0.2", "--sentence", "0.4", in: folder.url)
        XCTAssertEqual(both.status, 1)
        XCTAssertTrue(both.stderr.contains("give each kind its own"), both.stderr)
        // With no transcript there's no phrase to find; a range is placed
        // from the sound, and here there's none to read.
        let phrase = try tandem("cut", "as I said", "--json", in: folder.url)
        XCTAssertEqual(phrase.status, 1)
        XCTAssertTrue(phrase.stdout.contains("isn't said on the timeline"), phrase.stdout)
        let range = try tandem("cut", "--range", "1-2.5", "--false-start", "--json", in: folder.url)
        XCTAssertEqual(range.status, 0, range.stderr)
        let rangePlan = try ServiceJSON.decoder().decode(CutResult.self, from: Data(range.stdout.utf8))
        XCTAssertEqual(rangePlan.cuts.map(\.status), [.kept])
        XCTAssertEqual(rangePlan.cuts.first?.start, Time(seconds: 1))
        XCTAssertTrue(rangePlan.commands.isEmpty)
        let ats = try tandem("cut", "a", "--at", "1", "--at", "2", in: folder.url)
        XCTAssertEqual(ats.status, 2)
        XCTAssertTrue(ats.stderr.contains("Each --at goes with a phrase"), ats.stderr)
        let help = try tandem("help", "cut", in: folder.url)
        XCTAssertTrue(help.stdout.hasPrefix("Usage: tandem cut"), help.stdout)

        let project = try ProjectFile.load(from: folder.file("Loop.tandem"))
        XCTAssertEqual(project.revision, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProjectSession.lockURL(for: folder.file("Loop.tandem")).path))
    }

    func testRevisionUndoCountAndJSONErrors() throws {
        let folder = TempFolder()
        XCTAssertEqual(try tandem("new", "Revs.tandem", in: folder.url).status, 0)
        let marker = { (id: String) in #"{"addMarker": {"marker": {"id": "\#(id)", "time": 2, "name": "M"}}}"# }
        XCTAssertEqual(try tandem("apply", marker("mk_a"), "--label", "First", in: folder.url).status, 0)
        XCTAssertEqual(try tandem("apply", marker("mk_b"), "--label", "Second", in: folder.url).status, 0)

        let revision = try tandem("status", "--revision", in: folder.url)
        XCTAssertEqual(revision.status, 0, revision.stderr)
        XCTAssertEqual(revision.stdout, "2\n")

        let badCount = try tandem("undo", "--count", "zero", in: folder.url)
        XCTAssertEqual(badCount.status, 2)

        let undo = try tandem("undo", "--count", "2", "--expect", "2", in: folder.url)
        XCTAssertEqual(undo.status, 0, undo.stderr)
        XCTAssertEqual(undo.stdout, "Undid 2 edits: \"Second\" (by cli), \"First\" (by cli). Now at revision 4.\n")
        XCTAssertEqual(try tandem("status", "--revision", in: folder.url).stdout, "4\n")

        let undoJSON = try tandem("redo", "--count", "2", "--json", in: folder.url)
        XCTAssertEqual(undoJSON.status, 0, undoJSON.stderr)
        let redone = try ServiceJSON.decoder().decode(UndoResult.self, from: Data(undoJSON.stdout.utf8))
        XCTAssertEqual(redone.labels, ["First", "Second"])

        // An error in --json mode is a JSON object on stdout and a non-zero exit.
        XCTAssertEqual(try tandem("new", "Other.tandem", in: folder.url).status, 0)
        for arguments in [["status", "--json"], ["status", "--revision"]] {
            let ambiguous = try tandem(arguments, in: folder.url)
            XCTAssertEqual(ambiguous.status, 1, arguments.joined(separator: " "))
            if arguments.contains("--json") {
                let envelope = try ServiceJSON.decoder().decode(ErrorEnvelope.self, from: Data(ambiguous.stdout.utf8))
                XCTAssertTrue(envelope.error.message.contains("has 2 projects"), envelope.error.message)
            } else {
                XCTAssertEqual(ambiguous.stdout, "")
            }
        }
    }

    func testServeTakesCommandsOverHTTP() throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let serve = Process()
        serve.executableURL = Self.binary
        serve.arguments = ["serve"]
        serve.currentDirectoryURL = folder.url
        serve.environment = Self.environment()
        let serveOutput = Pipe()
        serve.standardOutput = serveOutput
        serve.standardError = Pipe()
        let exited = ExitSignal(serve)
        try serve.run()
        defer { if serve.isRunning { serve.terminate() } }

        let deadline = Date().addingTimeInterval(10)
        while ProjectSession.liveLock(for: url)?.port == nil && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let lock = try XCTUnwrap(ProjectSession.liveLock(for: url), "serve should advertise its port")
        XCTAssertEqual(lock.pid, serve.processIdentifier)

        let status = try tandem("status", "--json", in: folder.url)
        let decoded = try ServiceJSON.decoder().decode(StatusResult.self, from: Data(status.stdout.utf8))
        XCTAssertFalse(decoded.headless, "went through serve's API")
        XCTAssertEqual(decoded.openIn?.pid, serve.processIdentifier)

        let applied = try tandem("apply", "-", "--author", "codex", in: folder.url, stdin: #"{"addMarker": {"marker": {"id": "mk_hook", "time": 3, "name": "Hook"}}}"#)
        XCTAssertEqual(applied.status, 0, applied.stderr)
        XCTAssertTrue(applied.stdout.contains("by codex as revision 2"), applied.stdout)

        serve.interrupt()
        // Its output only ends once it has, and asking a running process
        // for its status raises.
        guard exited.wait(timeout: 20) else { return XCTFail("serve should stop on Ctrl-C") }
        XCTAssertEqual(serve.terminationStatus, 0)
        let printed = String(decoding: serveOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(printed.contains("Serving \"Decision Models\""), printed)
        XCTAssertEqual(try ProjectFile.load(from: url).project.markers.map(\.id), ["mk_hook", "mk_s2"], "saved on the way out")
        XCTAssertNil(ProjectSession.liveLock(for: url))
    }

    func testServeLetsGoWhenTheAppAsks() async throws {
        let folder = TempFolder()
        let url = try APIFixture.write(to: folder.url)
        let serve = Process()
        serve.executableURL = Self.binary
        serve.arguments = ["serve"]
        serve.currentDirectoryURL = folder.url
        serve.environment = Self.environment()
        serve.standardOutput = Pipe()
        serve.standardError = Pipe()
        let exited = ExitSignal(serve)
        try serve.run()
        defer { if serve.isRunning { serve.terminate() } }
        let deadline = Date().addingTimeInterval(10)
        while ProjectSession.liveLock(for: url)?.port == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertThrowsError(try ProjectSession.open(url, owner: .app), "serve has it")

        // What the app does: ask serve to let go, then open.
        let session = try await ProjectSession.open(url, owner: .app, waitingUpTo: 10)
        let stopped = await exited.value(timeout: 20)
        guard stopped else { session.close(); return XCTFail("serve should quit once it has let go") }
        XCTAssertEqual(serve.terminationStatus, 0)
        XCTAssertEqual(ProjectSession.readLock(for: url)?.owner, .app)
        session.close()
    }

    func testMCPOverStdio() async throws {
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let mcp = Process()
        mcp.executableURL = Self.binary
        mcp.arguments = ["mcp"]
        mcp.currentDirectoryURL = folder.url
        mcp.environment = Self.environment()
        let input = Pipe(), output = Pipe()
        mcp.standardInput = input
        mcp.standardOutput = output
        mcp.standardError = Pipe()
        let exited = ExitSignal(mcp)
        try mcp.run()
        defer { if mcp.isRunning { mcp.terminate() } }
        var lines = LineReader.lines(output.fileHandleForReading).makeAsyncIterator()
        func send(_ text: String) { input.fileHandleForWriting.write(Data((text + "\n").utf8)) }
        func next() async throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: Data((await lines.next() ?? "").utf8))
        }

        send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#)
        let initialize = try await next()
        XCTAssertEqual(initialize[json: "result"]?[json: "protocolVersion"], .string("2025-06-18"))
        send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        send(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"timeline","arguments":{"from":20,"to":25}}}"#)
        let timeline = try await next()
        let text = timeline[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString ?? ""
        XCTAssertTrue(text.contains("clip_brl1  00:20.000-00:25.000"), text)
        send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"apply","arguments":{"commands":[{"blade":{"at":22}}]}}}"#)
        let apply = try await next()
        XCTAssertTrue(apply[json: "result"]?[json: "content"]?[json: 0]?[json: "text"]?.testString?.contains("by claude as revision 2") ?? false, "\(apply)")

        try input.fileHandleForWriting.close()
        let stopped = await exited.value(timeout: 20)
        guard stopped else { return XCTFail("exits when stdin closes") }
        XCTAssertEqual(mcp.terminationStatus, 0)
    }

    /// Core ML (through Bark) and other native libraries can print straight
    /// to descriptor 1. That has to land on stderr, not in front of the JSON.
    func testStrayNativeOutputGoesToStderr() throws {
        let folder = TempFolder()
        let stray = ["TANDEM_TEST_STRAY_STDOUT": "1"]
        let effects = try tandem("effects", "--json", in: folder.url, env: stray)
        XCTAssertEqual(effects.status, 0, effects.stderr)
        XCTAssertFalse(effects.stdout.contains("E5RT"), effects.stdout)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(effects.stdout.utf8)), effects.stdout)
        XCTAssertTrue(effects.stderr.contains("E5RT encountered an STL exception (write)"), effects.stderr)
        XCTAssertTrue(effects.stderr.contains("E5RT encountered an STL exception (stdio)"), effects.stderr)

        let version = try tandem("--version", in: folder.url, env: stray)
        XCTAssertEqual(version.stdout, "tandem \(TandemAPI.version)\n")

        let failed = try tandem("status", "--json", in: folder.url, env: stray)
        XCTAssertEqual(failed.status, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(failed.stdout.utf8)), failed.stdout)
    }

    func testMCPStdoutStaysJSONWhenALibraryPrints() async throws {
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let mcp = Process()
        mcp.executableURL = Self.binary
        mcp.arguments = ["mcp"]
        mcp.currentDirectoryURL = folder.url
        mcp.environment = Self.environment(["TANDEM_TEST_STRAY_STDOUT": "1"])
        let input = Pipe(), output = Pipe()
        mcp.standardInput = input
        mcp.standardOutput = output
        mcp.standardError = Pipe()
        let exited = ExitSignal(mcp)
        try mcp.run()
        defer { if mcp.isRunning { mcp.terminate() } }
        input.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"# + "\n").utf8))
        try input.fileHandleForWriting.close()
        let stopped = await exited.value(timeout: 20)
        guard stopped else { return XCTFail("exits when stdin closes") }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(text.split(separator: "\n").count, 1, text)
        let reply = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(reply[json: "result"]?[json: "protocolVersion"], .string("2025-06-18"))
    }

    /// Finding what changed, putting it back, and finding clip IDs, the
    /// way agents do between Mike's rounds.
    func testDiffRestoreHistoryAndClips() throws {
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let lift = try tandem("apply", #"{"removeClips": {"clipIDs": ["clip_brl1"]}}"#, "--label", "Lift the B-roll", in: folder.url)
        XCTAssertEqual(lift.status, 0, lift.stderr)

        let history = try tandem("history", in: folder.url)
        XCTAssertTrue(history.stdout.contains("Lift the B-roll  (cli)  00:20.000-00:25.000 on V3 B-roll"), history.stdout)

        let diff = try tandem("diff", "--since", "1", in: folder.url)
        XCTAssertEqual(diff.status, 0, diff.stderr)
        XCTAssertTrue(diff.stdout.contains("r2  Lift the B-roll  by cli"), diff.stdout)
        XCTAssertTrue(diff.stdout.contains("removed  clip_brl1  V3 B-roll  00:20.000-00:25.000  servers.mp4"), diff.stdout)
        let json = try tandem("diff", "--since", "1", "--json", in: folder.url)
        let decoded = try ServiceJSON.decoder().decode(DiffResult.self, from: Data(json.stdout.utf8))
        XCTAssertEqual(decoded.changes.first?.before?.id, "clip_brl1")

        let dry = try tandem("restore", "--from", "1", "--clips", "clip_brl1", in: folder.url)
        XCTAssertEqual(dry.status, 0, dry.stderr)
        XCTAssertTrue(dry.stdout.contains("put back  clip_brl1"), dry.stdout)
        let applied = try tandem("restore", "--from", "1", "--clips", "clip_brl1", "--apply", in: folder.url)
        XCTAssertTrue(applied.stdout.contains("Applied as revision 3"), applied.stdout)

        let ids = try tandem("clips", "--track", "B-roll", "--ids", in: folder.url)
        XCTAssertEqual(ids.stdout, "clip_brl1\n")
        let listed = try tandem("clips", "--media", "bed.m4a", in: folder.url)
        XCTAssertTrue(listed.stdout.contains("clip_mus1"), listed.stdout)

        XCTAssertEqual(try tandem("diff", in: folder.url).status, 2)
        XCTAssertEqual(try tandem("restore", "--clips", "clip_brl1", in: folder.url).status, 2)
    }
}

/// `tandem import`, wired in at integration.
final class ImportCLITests: XCTestCase {
    let cli = CLITests()

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
    }

    func testImportUsageErrors() throws {
        let folder = TempFolder()
        let bare = try cli.tandem("import", in: folder.url)
        XCTAssertEqual(bare.status, 2)
        XCTAssertTrue(bare.stderr.contains("needs filmora, edl or compare"), bare.stderr)
        let typo = try cli.tandem("import", "filmroa", "x.wfp", in: folder.url)
        XCTAssertEqual(typo.status, 2)
        XCTAssertTrue(typo.stderr.contains("Did you mean `tandem import filmora`?"), typo.stderr)
        let noRecipe = try cli.tandem("import", "edl", in: folder.url)
        XCTAssertEqual(noRecipe.status, 2)
        XCTAssertTrue(noRecipe.stderr.contains("needs --recipe"), noRecipe.stderr)
        let missing = try cli.tandem("import", "filmora", "nope.wfp", in: folder.url)
        XCTAssertEqual(missing.status, 1)
    }

    func testCompareTwoCuts() throws {
        let folder = TempFolder()
        let coordinator = ProjectCoordinator(project: APIFixture.project())
        let a = folder.url.appendingPathComponent("a.tandem")
        let b = folder.url.appendingPathComponent("b.tandem")
        try ProjectFile.save(coordinator.project, revision: 1, to: a)
        try coordinator.apply(EditBatch(label: "Tighten", commands: [.rippleDeleteRange(range: TimeRange(start: Time(seconds: 10), end: Time(seconds: 11)))]))
        try ProjectFile.save(coordinator.project, revision: 2, to: b)
        let result = try cli.tandem("import", "compare", "a.tandem", "b.tandem", "--json", in: folder.url)
        XCTAssertEqual(result.status, 0, result.stderr)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
        guard case .object(let fields) = json else { return XCTFail("not an object: \(result.stdout)") }
        XCTAssertNotNil(fields["matchedVoice"])
    }
}

/// Knows when a process has exited. `Process.waitUntilExit()` spins the run
/// loop of the thread that launched the process, so in an async test that
/// resumes on another thread it can wait forever; the termination handler
/// runs on a queue of its own.
final class ExitSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var exited = false

    /// Call before `run()`. A process still running after `limit` seconds
    /// is terminated, so a test reading its output fails rather than hangs.
    init(_ process: Process, limit: TimeInterval = 120) {
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            XCTFail("\(process.executableURL?.lastPathComponent ?? "a process") \(process.arguments ?? []) was still running after \(Int(limit)) s")
            process.terminate()
        }
        process.terminationHandler = { [self] _ in
            watchdog.cancel()
            lock.withLock { exited = true }
            semaphore.signal()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: watchdog)
    }

    /// Blocks until the process exits, or `timeout` passes. True if it exited.
    @discardableResult
    func wait(timeout: TimeInterval = 120) -> Bool {
        if lock.withLock({ exited }) { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success
    }

    /// The same without blocking a concurrency thread.
    func value(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ exited }) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return lock.withLock { exited }
    }
}

/// `tandem assets`, against a library in a temp folder with the network
/// and the Keychain switched off.
final class AssetsCLITests: XCTestCase {
    let cli = CLITests()

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
    }

    func testAssetsEndToEnd() async throws {
        let folder = TempFolder("tandem-assets-cli")
        let root = folder.url.appendingPathComponent("library", isDirectory: true)
        do {
            // An import folder whose licence asks for a credit.
            let library = try AssetLibrary(root: root, previewFolder: root.appendingPathComponent("previews"), transport: OfflineTransport(), secrets: StaticSecretStore())
            let imports = folder.url.appendingPathComponent("imports", isDirectory: true)
            try AssetFixtures.wav(at: imports.appendingPathComponent("sfx/Swoosh_Air.wav"))
            try await library.addImportFolder(imports, licence: FolderLicence(source: "Test Sounds", licence: "CC BY 4.0", licenceClass: .creditNeeded, credit: "Swoosh Air by Test Sounds (CC BY 4.0)"))
        }
        let env = ["TANDEM_ASSETS_ROOT": root.path, "TANDEM_ASSETS_OFFLINE": "1"]
        let video = folder.url.appendingPathComponent("video", isDirectory: true)
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        let projectURL = try APIFixture.write(to: video)

        let providers = try cli.tandem("assets", "providers", in: video, env: env)
        XCTAssertEqual(providers.status, 0, providers.stderr)
        XCTAssertTrue(providers.stdout.contains("elevenlabs  ElevenLabs"), providers.stdout)
        XCTAssertTrue(providers.stdout.contains("needs a key"), providers.stdout)

        let search = try cli.tandem("assets", "search", "swoosh", "--kind", "sfx", "--json", in: video, env: env)
        XCTAssertEqual(search.status, 0, search.stderr)
        let found = try ServiceJSON.decoder().decode(AssetSearchResult.self, from: Data(search.stdout.utf8))
        let id = try XCTUnwrap(found.local.first?.id)

        let use = try cli.tandem("assets", "use", id, "--at", "0:02", "--author", "claude", in: video, env: env)
        XCTAssertEqual(use.status, 0, use.stderr)
        XCTAssertTrue(use.stdout.hasPrefix("Placed Swoosh Air (sfx) at 00:02.000 on SFX at -15 dB as revision 2."), use.stdout)
        XCTAssertTrue(use.stdout.contains("needs a credit"), use.stdout)
        let project = try ProjectFile.load(from: projectURL).project
        XCTAssertEqual(project.track(named: "SFX")?.clips.first?.start, t(2))
        let history = try cli.tandem("history", in: video)
        XCTAssertTrue(history.stdout.contains("Add Swoosh Air at 00:02.000  (claude)"), history.stdout)

        let credits = try cli.tandem("assets", "credits", in: video, env: env)
        XCTAssertEqual(credits.status, 0, credits.stderr)
        XCTAssertTrue(credits.stdout.contains("Credits\nSwoosh Air by Test Sounds (CC BY 4.0)"), credits.stdout)

        let online = try cli.tandem("assets", "search", "rocket", "--online", "--provider", "noto", in: video, env: env)
        XCTAssertEqual(online.status, 0, online.stderr)
        XCTAssertTrue(online.stdout.contains("noto: couldn't search."), online.stdout)

        let generate = try cli.tandem("assets", "generate", "sfx", "soft whoosh", in: video, env: env)
        XCTAssertEqual(generate.status, 1)
        XCTAssertTrue(generate.stderr.contains("ElevenLabs is unavailable"), generate.stderr)

        let starter = try cli.tandem("assets", "install-starter", in: video, env: env)
        XCTAssertTrue(starter.stdout.hasPrefix("The starter set is in the library:"), starter.stdout)

        let noID = try cli.tandem("assets", "use", in: video, env: env)
        XCTAssertEqual(noID.status, 2)
        XCTAssertTrue(noID.stderr.contains("needs an asset ID"), noID.stderr)
        let wrongOption = try cli.tandem("assets", "search", "x", "--at", "3", in: video, env: env)
        XCTAssertEqual(wrongOption.status, 2)
        XCTAssertTrue(wrongOption.stderr.contains("`tandem assets search` doesn't take --at"), wrongOption.stderr)
        let wrongAnchor = try cli.tandem("assets", "use", "stock:whoosh-deep", "--at", "1", "--anchor", "bottomright", in: video, env: env)
        XCTAssertEqual(wrongAnchor.status, 2)
        XCTAssertTrue(wrongAnchor.stderr.contains("--anchor is one of bottom, bottomLeft"), wrongAnchor.stderr)
        XCTAssertTrue(wrongAnchor.stderr.contains("Did you mean bottomRight?"), wrongAnchor.stderr)
    }
}

/// `tandem screenshot` needs the app, so headless it explains that.
final class ScreenshotCLITests: XCTestCase {
    func testScreenshotWithoutTheAppExplainsWhy() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder()
        _ = try APIFixture.write(to: folder.url)
        let result = try CLITests().tandem("screenshot", "-o", "shot.png", in: folder.url)
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.file("shot.png").path))
    }
}

final class NewProjectCLITests: XCTestCase {
    func testPortraitProject() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        let folder = TempFolder()
        let result = try CLITests().tandem("new", "Short.tandem", "--portrait", in: folder.url)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("1080x1920"), result.stdout)
        let project = try ProjectFile.load(from: folder.file("Short.tandem")).project
        XCTAssertEqual(project.settings.width, 1080)
        XCTAssertEqual(project.settings.height, 1920)
        let bad = try CLITests().tandem("new", "Odd.tandem", "--size", "big", in: folder.url)
        XCTAssertEqual(bad.status, 2)
    }

    /// A project made portrait is its own short: the short preset and the
    /// default both render its 1080x1920 canvas at the 1080p rate, and say
    /// what they used. (It used to fail with "No output format".)
    func testPortraitProjectExports() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let cli = CLITests()
        let folder = TempFolder()
        try FileManager.default.createDirectory(at: folder.file("source"), withIntermediateDirectories: true)
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x2040c0:s=1080x1920:d=2:r=30",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-shortest", folder.file("source/take1-camera.mp4").path])
        let created = try cli.tandem("new", "Short.tandem", "--portrait", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        let project = try ProjectFile.load(from: folder.file("Short.tandem")).project
        let media = try XCTUnwrap(project.media.first { $0.path == "source/take1-camera.mp4" })
        let placed = try cli.tandem("apply", "-", in: folder.url, stdin: #"{"placeMedia": {"mediaIDs": ["\#(media.id)"], "at": 0}}"#)
        XCTAssertEqual(placed.status, 0, placed.stderr)

        // Into exports/, as the snapshot beside each export is a .tandem too.
        // The apply above waits for review, so these are check exports.
        let waiting = try cli.tandem("export", "--preset", "short", "-o", "exports/short.mp4", in: folder.url)
        XCTAssertEqual(waiting.status, 1, "a final export waits for Mike's review")
        XCTAssertTrue(waiting.stderr.contains("Not exported"), waiting.stderr)
        let short = try cli.tandem("export", "--preset", "short", "-o", "exports/short.mp4", "--unreviewed", in: folder.url)
        XCTAssertEqual(short.status, 0, short.stderr)
        XCTAssertTrue(short.stdout.contains("(Short 9:16: 1080x1920 H.264 at 20 Mbps, 00:02.000 long)"), short.stdout)
        let standard = try cli.tandem("export", "-o", "exports/default.mp4", "--unreviewed", "--json", in: folder.url)
        XCTAssertEqual(standard.status, 0, standard.stderr)
        let outcome = try ServiceJSON.decoder().decode(ExportOutcome.self, from: Data(standard.stdout.utf8))
        XCTAssertEqual(outcome.preset, "YouTube 1080p")
        XCTAssertEqual([outcome.width, outcome.height], [1080, 1920])
        XCTAssertEqual(outcome.videoBitrate, 20_000_000)
        for name in ["exports/short.mp4", "exports/default.mp4"] {
            let asset = AVURLAsset(url: folder.file(name))
            let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 1080, height: 1920), name)
        }
        // Laying a short over a project that's already one is refused.
        let layout = try cli.tandem("short", in: folder.url)
        XCTAssertEqual(layout.status, 1)
        XCTAssertTrue(layout.stderr.contains("already 9:16"), layout.stderr)

        let help = try cli.tandem("help", "export", in: folder.url)
        XCTAssertTrue(help.stdout.contains("1080x1920 for a 9:16 one"), help.stdout)
        XCTAssertTrue(help.stdout.contains("`tandem new --portrait`"), help.stdout)
    }

    /// A photo like an iPhone's, for a Live Photo.
    static func writeJPEG(to url: URL) throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.6, green: 0.45, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testSaysWhichFileIsTheCameraAndKeepsLivePhotosTogether() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        func movie(_ path: String, seconds: Int, in folder: TempFolder) throws {
            try FileManager.default.createDirectory(at: folder.file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x806040:s=320x240:d=\(seconds):r=30", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", folder.file(path).path])
        }
        // A record-it camera file, and a Live Photo: the still and its two
        // second movie.
        let folder = TempFolder()
        try movie("source/t1-camera.mov", seconds: 2, in: folder)
        try movie("photos/IMG_0130.mov", seconds: 2, in: folder)
        try Self.writeJPEG(to: folder.file("photos/IMG_0130.jpg"))

        let result = try CLITests().tandem("new", "Bench.tandem", in: folder.url)
        XCTAssertEqual(result.status, 0, result.stderr)
        let project = try ProjectFile.load(from: folder.file("Bench.tandem")).project
        XCTAssertEqual(project.media.map(\.path).sorted(), ["photos/IMG_0130.jpg", "source/t1-camera.mov"])
        XCTAssertEqual(project.media.first { $0.path == "photos/IMG_0130.jpg" }?.livePhotoVideo, "photos/IMG_0130.mov")
        let camera = try XCTUnwrap(project.media.first { $0.path == "source/t1-camera.mov" })
        XCTAssertEqual(camera.role, .camera)
        XCTAssertTrue(result.stdout.contains("Added 2 media files from the folder.\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("1 is a Live Photo: "), result.stdout)
        XCTAssertTrue(result.stdout.contains("Camera take: source/t1-camera.mov (\(camera.id)), named like a record-it camera file.\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains(#"tandem apply '{"updateMedia": {"mediaID": "\#(camera.id)", "patch": {"role": "other"}}}'"#), result.stdout)
        let media = try CLITests().tandem("media", in: folder.url)
        XCTAssertTrue(media.stdout.contains("photos/IMG_0130.jpg  image  64x48  Live Photo, motion clip IMG_0130.mov  0 clips"), media.stdout)

        // With no camera take it names the likeliest video to make one.
        let bare = TempFolder()
        try movie("source/talk.mov", seconds: 3, in: bare)
        try movie("source/short.mov", seconds: 1, in: bare)
        let none = try CLITests().tandem("new", "Bare.tandem", in: bare.url)
        XCTAssertEqual(none.status, 0, none.stderr)
        let talk = try XCTUnwrap(ProjectFile.load(from: bare.file("Bare.tandem")).project.media.first { $0.path == "source/talk.mov" })
        XCTAssertEqual(talk.role, .other)
        XCTAssertTrue(none.stdout.contains("No camera take: "), none.stdout)
        XCTAssertTrue(none.stdout.contains(#"tandem apply '{"updateMedia": {"mediaID": "\#(talk.id)", "patch": {"role": "camera"}}}'"#), none.stdout)

        // Mike's usual 30 fps take leaves the project at 30, and says nothing.
        XCTAssertEqual(project.settings.frameRate, FrameRate(30))
        XCTAssertFalse(result.stdout.contains("Frame rate:"), result.stdout)
    }

    func testANewProjectTakesItsCameraTakesFrameRate() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        func movie(_ path: String, rate: String, in folder: TempFolder) throws {
            try FileManager.default.createDirectory(at: folder.file(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x806040:s=320x240:d=2:r=\(rate)", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", folder.file(path).path])
        }
        // Ian's interview was shot at 23.976 and came in as a 30 fps project.
        let film = TempFolder()
        try movie("source/ian-camera.mov", rate: "24000/1001", in: film)
        try movie("source/ian-screen.mov", rate: "30", in: film)
        let made = try CLITests().tandem("new", "Ian.tandem", in: film.url)
        XCTAssertEqual(made.status, 0, made.stderr)
        XCTAssertEqual(try ProjectFile.load(from: film.file("Ian.tandem")).project.settings.frameRate, FrameRate(24_000, 1001))
        XCTAssertTrue(made.stdout.contains("Frame rate: 23.976 fps, the camera take's."), made.stdout)

        // A 60 fps webcam keeps Mike's usual 30.
        let fast = TempFolder()
        try movie("source/t1-camera.mov", rate: "60", in: fast)
        let sixty = try CLITests().tandem("new", "Fast.tandem", in: fast.url)
        XCTAssertEqual(sixty.status, 0, sixty.stderr)
        XCTAssertEqual(try ProjectFile.load(from: fast.file("Fast.tandem")).project.settings.frameRate, FrameRate(30))
        XCTAssertFalse(sixty.stdout.contains("Frame rate:"), sixty.stdout)
    }
}

/// Stock alpha stickers come as QuickTime Animation or PNG in a MOV, which
/// AVFoundation can't decode. Rendering a project that uses them used to
/// fail with "Cannot Decode"; now the render converts them first.
final class UndecodableStickerCLITests: XCTestCase {
    func testQuickTimeAnimationAndPNGStickersRender() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: CLITests.binary.path), "tandem isn't built")
        guard let ffmpeg = FFmpeg.locate() else { throw XCTSkip("ffmpeg isn't installed") }
        let cli = CLITests()
        let folder = TempFolder()
        try FileManager.default.createDirectory(at: folder.file("stickers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.file("source"), withIntermediateDirectories: true)
        // A red disc on a clear square, in both codecs, and a screen take.
        let disc = "color=c=red:s=256x256:d=2:r=30,format=rgba,geq=r='255':g='0':b='0':a='if(lt(hypot(X-128,Y-128),100),255,0)'"
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", disc, "-c:v", "qtrle", "-pix_fmt", "argb", folder.file("stickers/disc-qtrle.mov").path])
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", disc, "-c:v", "png", "-pix_fmt", "rgba", folder.file("stickers/disc-png.mov").path])
        try ffmpeg.run(["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=0x2040c0:s=1280x720:d=4:r=30", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                        folder.file("source/take1-screen.mp4").path])

        let created = try cli.tandem("new", "Alpha.tandem", "--size", "1280x720", in: folder.url)
        XCTAssertEqual(created.status, 0, created.stderr)
        let listed = try cli.tandem("media", "--refresh", "--json", in: folder.url)
        XCTAssertEqual(listed.status, 0, listed.stderr)
        let media = try ServiceJSON.decoder().decode(MediaResult.self, from: Data(listed.stdout.utf8))
        func id(_ path: String) throws -> String { try XCTUnwrap(media.items.first { $0.path == path }?.id, path) }
        XCTAssertEqual(media.items.first { $0.path == "stickers/disc-qtrle.mov" }?.undecodableCodec, "rle ")
        XCTAssertEqual(media.items.first { $0.path == "stickers/disc-png.mov" }?.undecodableCodec, "png ")
        XCTAssertNil(media.items.first { $0.path == "source/take1-screen.mp4" }?.undecodableCodec)

        let project = try ProjectFile.load(from: folder.file("Alpha.tandem")).project
        let graphics = try XCTUnwrap(project.track(named: "Graphics")).id
        let batch = """
        {"commands": [
          {"placeMedia": {"mediaIDs": ["\(try id("source/take1-screen.mp4"))"], "at": 0}},
          {"placeMedia": {"mediaIDs": ["\(try id("stickers/disc-qtrle.mov"))"], "at": 0, "videoTrackID": "\(graphics)", "anchor": "centre"}},
          {"placeMedia": {"mediaIDs": ["\(try id("stickers/disc-png.mov"))"], "at": 2, "videoTrackID": "\(graphics)", "anchor": "centre"}}
        ]}
        """
        let applied = try cli.tandem("apply", "-", in: folder.url, stdin: batch)
        XCTAssertEqual(applied.status, 0, applied.stderr)

        for (time, name) in [("1", "qtrle"), ("3", "png")] {
            let frame = try cli.tandem("frame", time, "-o", "frame-\(name).png", in: folder.url)
            XCTAssertEqual(frame.status, 0, "\(name): \(frame.stderr)")
            XCTAssertFalse(frame.stdout.contains("decode"), frame.stdout)
            let image = try XCTUnwrap(CGImageSourceCreateWithURL(folder.file("frame-\(name).png") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let centre = pixel(image, x: image.width / 2, y: image.height / 2)
            let corner = pixel(image, x: 20, y: 20)
            XCTAssertGreaterThan(centre[0], 220, "\(name): the disc is at the centre, \(centre)")
            XCTAssertLessThan(centre[2], 40, "\(name): \(centre)")
            XCTAssertGreaterThan(corner[2], 150, "\(name): the take shows around it, \(corner)")
        }
        let clip = try cli.tandem("clip", "0", "4", "-o", "exports/review.mp4", in: folder.url)
        XCTAssertEqual(clip.status, 0, clip.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.file("exports/review.mp4").path))

        let after = try cli.tandem("media", in: folder.url)
        XCTAssertEqual(after.status, 0, after.stderr)
        XCTAssertTrue(after.stdout.contains("stickers/disc-qtrle.mov  sticker"), after.stdout)
        XCTAssertTrue(after.stdout.contains("QuickTime Animation"), after.stdout)
        XCTAssertTrue(after.stdout.contains("converted ready"), after.stdout)
    }

    /// RGBA at (x, y), y down.
    func pixel(_ image: CGImage, x: Int, y: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return data.map(Int.init)
    }
}
