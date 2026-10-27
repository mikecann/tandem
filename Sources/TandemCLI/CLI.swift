import Foundation
import TandemAPI
import TandemAssets
import TandemCore
import TandemRender

/// The `tandem` command. Each subcommand builds a service request, sends
/// it through `ProjectClient` (to the app when it has the project open,
/// otherwise straight to the file) and prints the result as text, or as
/// JSON with `--json`.
struct CLI {
    let arguments: [String]
    let directory: URL
    let environment: [String: String]

    init(arguments: [String], directory: URL, environment: [String: String]) {
        self.arguments = arguments
        self.directory = directory
        self.environment = environment
    }

    func run() async -> Int32 {
        let parsed: Arguments
        do {
            parsed = try Arguments.parse(arguments)
        } catch let error as UsageError {
            return usage(error.message, command: nil)
        } catch {
            return usage(error.localizedDescription, command: nil)
        }
        if parsed.has("version") && parsed.command == nil {
            StandardOutput.line("tandem \(TandemAPI.version)")
            return 0
        }
        guard let name = parsed.command else {
            StandardOutput.line(Help.overview)
            return parsed.has("help") ? 0 : 2
        }
        // Titles can use the shared library's fonts wherever this process
        // draws them (an export, a frame, tandem serve).
        ProjectFonts.libraryFolders = [SharedLibrary.locate(environment: environment).url(.fonts)]
        // On stderr, so --json output (and MCP's stdout) stays clean.
        ProjectClient.waitNotice = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        if name == "help" {
            if let topic = parsed.positionals.first {
                guard let text = Help.topic(topic) else {
                    let names = Help.commands.map(\.name) + CommandCase.allCases.map(\.rawValue)
                    let hint = Arguments.closest(topic, in: names).map { " Did you mean `tandem help \($0)`?" } ?? ""
                    return usage("There's no `\(topic)` command or edit command.\(hint)", command: nil)
                }
                StandardOutput.line(text)
            } else {
                StandardOutput.line(Help.overview)
            }
            return 0
        }
        guard let command = Help.command(name) else {
            let hint = Arguments.closest(name, in: Help.commands.map(\.name)).map { " Did you mean `tandem \($0)`?" } ?? ""
            return usage("There's no `\(name)` command.\(hint)", command: nil)
        }
        if parsed.has("help") {
            StandardOutput.line(Help.detail(command))
            return 0
        }
        do {
            try parsed.check(allowed: command.options, command: name)
            return try await execute(name, parsed)
        } catch let error as UsageError {
            return usage(error.message, command: command)
        } catch {
            return fail(ServiceError.wrap(error), json: parsed.has("json"))
        }
    }

    // MARK: - Commands

    private func execute(_ name: String, _ args: Arguments) async throws -> Int32 {
        let json = args.has("json")
        switch name {
        case "new":
            return try await newProject(args)
        case "effects":
            try args.expectPositionals(atMost: 1, command: name)
            return show(try EffectsResult.catalog(type: args.positionals.first), json: json)
        case "schema":
            let data = try ServiceJSON.encoder(pretty: true).encode(CommandSchema.document)
            StandardOutput.line(String(decoding: data, as: UTF8.self))
            return 0
        case "serve":
            return try await serve(args)
        case "mcp":
            return await mcp(args)
        case "import":
            return try await ImportCommand(directory: directory).run(args)
        case "assets":
            return try await AssetsCommand(directory: directory, environment: environment).run(args, author: author(args)) { try project(args) }
        case "segments":
            return try await SegmentsCommand(directory: directory, environment: environment).run(args, author: author(args)) { try project(args) }
        case "archive":
            try args.expectPositionals(atMost: 1, command: name)
            if args.has("with-cache"), args.options["to"] == nil {
                throw UsageError(message: "--with-cache keeps proxies and mattes in a copy made with --to <folder>; without --to the cache stays where it is.")
            }
            let request = ArchiveRequest(
                to: args.options["to"].map(absolute), withCache: args.has("with-cache") ? true : nil,
                dryRun: args.has("dry-run") ? true : nil, label: args.options["label"]
            )
            // The project can be named straight after the command.
            let url = try ProjectLocator.find(args.positionals.first ?? args.options["project"], in: directory, environment: environment)
            return show(try await ProjectClient(projectURL: url, author: author(args)).call(request), json: json)
        default:
            break
        }

        // Arguments are checked before the project is looked up, so a typo
        // gets a usage error even outside a project folder.
        let client = { ProjectClient(projectURL: try project(args), author: author(args)) }
        switch name {
        case "status":
            try args.expectPositionals(atMost: 0, command: name)
            let status = try await client().call(StatusRequest())
            // Just the number, for scripts; --json has it as `revision` too.
            if args.has("revision") && !json {
                StandardOutput.line(String(status.revision))
                return 0
            }
            return show(status, json: json)
        case "media":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(MediaRequest(refresh: args.has("refresh"))), json: json)
        case "timeline":
            try args.expectPositionals(atMost: 0, command: name)
            let request = TimelineRequest(
                from: try time(args, "from"), to: try time(args, "to"), format: json ? .json : .text,
                words: args.has("words"), summary: args.has("summary")
            )
            return show(try await client().call(request), json: json)
        case "apply":
            try args.expectPositionals(atMost: 1, command: name)
            let request = try applyRequest(args)
            return show(try await client().call(request), json: json)
        case "undo":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(UndoRequest(expectedRevision: try args.integer("expect"), count: try args.integer("count"))), json: json)
        case "redo":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(RedoRequest(expectedRevision: try args.integer("expect"), count: try args.integer("count"))), json: json)
        case "history":
            try args.expectPositionals(atMost: 0, command: name)
            return show(try await client().call(HistoryRequest(limit: try args.integer("limit"))), json: json)
        case "diff":
            try args.expectPositionals(atMost: 1, command: name)
            guard let since = args.options["since"] ?? args.positionals.first else {
                throw UsageError(message: "`tandem diff` needs --since: a revision, a .tandem file or an export, like tandem diff --since 95.")
            }
            return show(try await client().call(DiffRequest(since: reference(since))), json: json)
        case "restore":
            try args.expectPositionals(atMost: 0, command: name)
            guard let from = args.options["from"] else {
                throw UsageError(message: "`tandem restore` needs --from: a revision, a .tandem file or an export, like tandem restore --from 95 --clips clip_a,clip_b.")
            }
            let clips = args.values("clips").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
            let request = RestoreRequest(
                from: reference(from), clips: clips.isEmpty ? nil : clips,
                fromTime: try time(args, "from-time"), toTime: try time(args, "to-time"), track: args.options["track"],
                apply: args.has("apply") ? true : nil, label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "clips":
            try args.expectPositionals(atMost: 0, command: name)
            let request = ClipsRequest(
                track: args.options["track"], from: try time(args, "from"), to: try time(args, "to"),
                media: args.options["media"], ids: args.has("ids") ? true : nil
            )
            return show(try await client().call(request), json: json)
        case "validate":
            try args.expectPositionals(atMost: 0, command: name)
            let result = try await client().call(ValidateRequest())
            _ = show(result, json: json)
            return result.ok ? 0 : 1
        case "check":
            try args.expectPositionals(atMost: 0, command: name)
            let request = CheckRequest(
                from: try time(args, "from"), to: try time(args, "to"),
                changed: args.has("changed") ? true : nil, quick: args.has("quick") ? true : nil, cuts: args.has("cuts") ? true : nil,
                listen: args.has("listen") ? true : nil, width: try args.integer("width")
            )
            let result = try await client().call(request)
            _ = show(result, json: json)
            return result.ok ? 0 : 1
        case "sync":
            // Files to line up by sound, or one picture delay.
            if args.positionals.count > 1 || args.positionals.first.map(Self.isSyncFile) == true {
                let request = SyncRequest(
                    files: args.positionals.map(mediaReference), to: args.options["to"].map(mediaReference),
                    place: args.has("no-place") ? false : nil, dryRun: args.has("dry-run") ? true : nil,
                    label: args.options["label"], expectedRevision: try args.integer("expect")
                )
                return show(try await client().call(request), json: json)
            }
            let delay = try args.positionals.first.map(Self.syncDelay)
            let media = args.values("media")
            let request = SyncRequest(
                delay: delay, media: media.isEmpty ? nil : media, makeDefault: args.has("default") ? true : nil,
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "handback":
            try args.expectPositionals(atMost: 1, command: name)
            return show(try await client().call(try handbackRequest(args)), json: json)
        case "comments":
            guard args.positionals.first == "resolve" else {
                try args.expectPositionals(atMost: 0, command: name)
                if args.has("all") { throw UsageError(message: "--all goes with resolve: tandem comments resolve --all.") }
                return show(try await client().call(CommentsRequest()), json: json)
            }
            return try await resolveComments(Array(args.positionals.dropFirst()), all: args.has("all"), label: args.options["label"], client: try client(), json: json)
        case "transcript":
            try args.expectPositionals(atMost: 1, command: name)
            let request = TranscriptRequest(id: args.positionals.first, from: try time(args, "from"), to: try time(args, "to"))
            let client = try client()
            if args.has("make") {
                guard let id = args.positionals.first else { throw UsageError(message: "--make needs a media or clip ID, like tandem transcript med_x --make.") }
                let made = try await client.call(TranscribeRequest(media: [mediaReference(id)], wait: true, timeout: try args.number("timeout")), onEvent: progress(WaitRequest(what: .transcript, media: [id]), json: json))
                guard made.ok else {
                    _ = show(made, json: json)
                    return 1
                }
            }
            return show(try await client.call(request), json: json)
        case "transcribe":
            guard !args.positionals.isEmpty else {
                throw UsageError(message: "`tandem transcribe` needs media, like tandem transcribe med_x or tandem transcribe source/generated/cartoon.mp4.")
            }
            if args.has("wait") && args.has("no-wait") { throw UsageError(message: "Pick one of --wait and --no-wait.") }
            let client = try client()
            let media = args.positionals.map(mediaReference)
            // With the app closed nothing else would make it, so it waits.
            let wait = args.has("wait") || (!args.has("no-wait") && client.route == .headless)
            let request = TranscribeRequest(media: media, wait: wait, timeout: try args.number("timeout"), label: args.options["label"])
            let result = try await client.call(request, onEvent: wait ? progress(WaitRequest(what: .transcript, media: media), json: json) : nil)
            _ = show(result, json: json)
            return result.ok ? 0 : 1
        case "wait":
            try args.expectPositionals(atMost: 1, command: name)
            var what = WaitTarget.jobs
            if let word = args.positionals.first {
                guard let target = WaitTarget(rawValue: word) else {
                    throw UsageError(message: "`tandem wait` waits for transcript, matte, proxy, jobs or export, not \"\(word)\".")
                }
                what = target
            }
            let media = args.values("media").map(mediaReference)
            let request = WaitRequest(what: what, media: media.isEmpty ? nil : media, timeout: try args.number("timeout"))
            let result = try await client().call(request, onEvent: progress(request, json: json))
            _ = show(result, json: json)
            return result.ok ? 0 : 1
        case "search":
            let phrase = args.positionals.joined(separator: " ")
            guard !phrase.isEmpty else { throw UsageError(message: "`tandem search` needs a phrase, like tandem search \"decision models\".") }
            return show(try await client().call(SearchRequest(phrase: phrase, limit: try args.integer("limit"))), json: json)
        case "pauses":
            try args.expectPositionals(atMost: 0, command: name)
            let request = PausesRequest(min: try seconds(args, "min"), from: try time(args, "from"), to: try time(args, "to"))
            return show(try await client().call(request), json: json)
        case "tighten":
            try args.expectPositionals(atMost: 0, command: name)
            let protect = try (args.repeated["protect"] ?? [])
                .flatMap { $0.split(separator: ",") }
                .map { try parseTime($0.trimmingCharacters(in: .whitespaces)) }
            let request = TightenRequest(
                min: try seconds(args, "min"), keep: try seconds(args, "keep"),
                sentence: try seconds(args, "sentence"), comma: try seconds(args, "comma"), mid: try seconds(args, "mid"),
                midMin: try seconds(args, "mid-min"), mike: args.has("mike") ? true : nil,
                protect: protect.isEmpty ? nil : protect, widen: args.has("widen") ? true : nil,
                apply: args.has("apply"), from: try time(args, "from"), to: try time(args, "to"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "cut":
            // Phrases are the positionals; each --at goes with the phrase
            // in the same place, for one said more than once.
            let ats = try args.values("at").map { try parseTime($0) }
            guard ats.count <= args.positionals.count else {
                throw UsageError(message: "Each --at goes with a phrase, in order: \(ats.count) --at for \(args.positionals.count) phrase\(args.positionals.count == 1 ? "" : "s").")
            }
            var remove = args.positionals.enumerated().map { CutTarget(phrase: $1, at: $0 < ats.count ? ats[$0] : nil) }
            for text in args.values("range") {
                let parts = text.split(separator: "-", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { throw UsageError(message: "--range is <start>-<end>, like 2:14.2-2:16.05, not \"\(text)\".") }
                remove.append(CutTarget(start: try parseTime(parts[0]), end: try parseTime(parts[1])))
            }
            guard !remove.isEmpty || args.has("fillers") else {
                throw UsageError(message: "`tandem cut` needs a phrase, a --range or --fillers, like tandem cut \"as I said before\", tandem cut --range 2:14.2-2:16.05 or tandem cut --fillers.")
            }
            let protect = try (args.repeated["protect"] ?? [])
                .flatMap { $0.split(separator: ",") }
                .map { try parseTime($0.trimmingCharacters(in: .whitespaces)) }
            let request = CutRequest(
                remove: remove, fillers: args.has("fillers") ? true : nil, from: try time(args, "from"), to: try time(args, "to"),
                protect: protect.isEmpty ? nil : protect,
                falseStart: args.has("false-start") ? true : nil, apply: args.has("apply"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "join":
            try args.expectPositionals(atMost: 0, command: name)
            let request = JoinRequest(
                from: try time(args, "from"), to: try time(args, "to"), apply: args.has("apply"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "short":
            try args.expectPositionals(atMost: 0, command: name)
            let request = ShortRequest(
                apply: args.has("apply"), copy: args.has("copy") ? true : nil, copyPath: args.has("copy") ? args.options["output"] : nil,
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "captions":
            try args.expectPositionals(atMost: 0, command: name)
            let request = CaptionsRequest(
                from: try time(args, "from"), to: try time(args, "to"), words: try args.integer("max-words"),
                y: try args.number("y"), track: args.options["track"], apply: args.has("apply"),
                label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "cards":
            try args.expectPositionals(atMost: 0, command: name)
            let request = CardsRequest(
                markers: args.repeated["marker"], duration: try time(args, "duration"), kicker: args.options["kicker"],
                track: args.options["track"], insert: args.has("insert") ? true : nil, sounds: args.has("no-sounds") ? false : nil,
                apply: args.has("apply"), label: args.options["label"], expectedRevision: try args.integer("expect")
            )
            return show(try await client().call(request), json: json)
        case "frame":
            try args.expectPositionals(atMost: 1, command: name)
            let at = try parseTime(try args.positional(0, "a time, like tandem frame 01:23.500", command: name))
            let output = absolute(args.options["output"] ?? "frame-\(TimeText.fileSafe(at)).png")
            let request = FrameRequest(time: at, maxWidth: try args.integer("width"), maxHeight: try args.integer("height"), output: output, format: args.options["format"])
            return show(try await client().call(request), json: json)
        case "frames":
            let times = try args.positionals.map(parseTime)
            let every = try time(args, "every")
            guard !times.isEmpty || every != nil else {
                throw UsageError(message: "`tandem frames` needs times, like tandem frames 0:10 0:20 0:30, or --every <seconds>.")
            }
            let from = try time(args, "from"), to = try time(args, "to")
            let output = absolute(args.options["output"] ?? Self.sheetName(times: times, every: every, from: from, to: to))
            let request = FramesRequest(
                times: times.isEmpty ? nil : times, every: every, from: from, to: to,
                width: try args.integer("width"), output: output, format: args.options["format"]
            )
            return show(try await client().call(request), json: json)
        case "screenshot":
            try args.expectPositionals(atMost: 0, command: name)
            let output = absolute(args.options["output"] ?? "tandem-window.png")
            return show(try await client().call(ScreenshotRequest(output: output)), json: json)
        case "clip":
            try args.expectPositionals(atMost: 2, command: name)
            let start = try parseTime(try args.positional(0, "a start and an end, like tandem clip 1:00 1:20", command: name))
            let end = try parseTime(try args.positional(1, "an end time too, like tandem clip 1:00 1:20", command: name))
            let request = ClipRequest(
                start: start, end: end, output: args.options["output"].map(absolute), preset: args.options["preset"],
                tracks: AssetNames.split(args.options["tracks"]).nilIfEmpty, audioOnly: args.has("audio-only") ? true : nil
            )
            return show(try await client().call(request), json: json)
        case "export":
            try args.expectPositionals(atMost: 0, command: name)
            let request = ExportRequest(
                preset: args.options["preset"], output: args.options["output"].map(absolute),
                from: try time(args, "from"), to: try time(args, "to"), format: args.options["format"]
            )
            return show(try await client().call(request), json: json)
        case "loudness":
            try args.expectPositionals(atMost: 1, command: name)
            let request = LoudnessRequest(
                mediaID: args.positionals.first, from: try time(args, "from"), to: try time(args, "to"), step: try time(args, "step"),
                tracks: AssetNames.split(args.options["tracks"]).nilIfEmpty, gains: args.has("gains") ? true : nil,
                over: try args.number("over")
            )
            return show(try await client().call(request), json: json)
        case "relink":
            try args.expectPositionals(atMost: 0, command: name)
            let search = args.values("search").map(absolute)
            let request = RelinkRequest(search: search.isEmpty ? nil : search, dryRun: args.has("dry-run") ? true : nil, label: args.options["label"])
            return show(try await client().call(request), json: json)
        case "watch":
            try args.expectPositionals(atMost: 0, command: name)
            if args.has("once") {
                let result = try await client().call(WatchRequest(timeout: try args.number("timeout")))
                return show(result, json: json)
            }
            return try await follow(try client(), json: json)
        default:
            throw UsageError(message: "There's no `\(name)` command.")
        }
    }

    private func newProject(_ args: Arguments) async throws -> Int32 {
        try args.expectPositionals(atMost: 1, command: "new")
        var url = URL(fileURLWithPath: absolute(try args.positional(0, "a path, like tandem new \"Decision Models.tandem\"", command: "new")))
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            url = url.appendingPathComponent(url.lastPathComponent).appendingPathExtension(ProjectFile.fileExtension)
        } else if url.pathExtension != ProjectFile.fileExtension {
            url = url.appendingPathExtension(ProjectFile.fileExtension)
        }
        var settings = ProjectSettings()
        if args.has("portrait") {
            settings.width = 1080
            settings.height = 1920
        }
        if let size = args.options["size"] {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
                throw UsageError(message: "--size takes width x height in pixels, like 1080x1920 or 3840x2160.")
            }
            settings.width = parts[0]
            settings.height = parts[1]
        }
        let session = try ProjectSession.create(at: url, name: args.options["name"], settings: settings, owner: .cli)
        defer { session.close() }
        let refresh = try await session.refreshMediaReport()
        let project = session.coordinator.project
        if args.has("json") {
            let service = TandemService(session: session, mode: .headless)
            defer { service.shutdown() }
            return show(service.status(), json: true)
        }
        StandardOutput.line("Created \(url.path), \(project.settings.width)x\(project.settings.height), with \(project.allTracks.count) tracks (\(project.allTracks.map(\.name).joined(separator: ", "))).")
        let added = refresh.added
        StandardOutput.line(added.isEmpty ? "No media found in the folder yet. Add files and run `tandem media --refresh`." : "Added \(added.count) media file\(added.count == 1 ? "" : "s") from the folder.")
        for line in Self.newMediaLines(refresh, in: project) { StandardOutput.line(line) }
        return 0
    }

    /// What `tandem new` says about the media it found: the Live Photos, and
    /// which file it treated as the camera take, why, and how to change it.
    static func newMediaLines(_ refresh: MediaRefresh, in project: Project) -> [String] {
        let added = refresh.added.compactMap { project.media($0) }
        var lines: [String] = []
        let livePhotos = added.filter { $0.livePhotoVideo != nil }.count
        if livePhotos > 0 {
            lines.append("\(livePhotos) \(livePhotos == 1 ? "is a Live Photo" : "are Live Photos"): the still is the media item, with its motion clip kept on it (livePhotoVideo) rather than added on its own.")
        }
        func command(_ id: String, role: MediaRole) -> String {
            #"tandem apply '{"updateMedia": {"mediaID": "\#(id)", "patch": {"role": "\#(role.rawValue)"}}}'"#
        }
        let takes = refresh.cameraTakes
        if !takes.isEmpty {
            let shown = 5
            for take in takes.prefix(shown) {
                // A speech recording is a camera take with no picture.
                let label = project.media(take.mediaID)?.kind == .audio ? "Voice take" : "Camera take"
                lines.append("\(label): \(take.path) (\(take.mediaID)), \(take.reason).")
            }
            if takes.count > shown { lines.append("And \(takes.count - shown) more camera takes; `tandem media` lists them.") }
            lines.append("Not the camera? \(command(takes.count == 1 ? takes[0].mediaID : "<id>", role: .other))")
        } else if added.contains(where: { $0.kind == .video }) {
            // The likeliest take is the longest video with sound that nothing
            // else claimed.
            let likely = added.filter { $0.kind == .video && $0.role == .other && $0.hasAudio }.max { ($0.duration ?? .zero) < ($1.duration ?? .zero) }
            var line = "No camera take: no video is named like one, or is a recording (from a phone or camera, or in source/) with speech and a face in it. To make one the camera: \(command(likely?.id ?? "<id>", role: .camera))"
            if let likely { line += " (\(likely.id) is \((likely.path as NSString).lastPathComponent), the longest video with sound)." }
            lines.append(line)
        }
        for angle in refresh.angles {
            lines.append("Another angle: \(angle.path) (\(angle.mediaID)), \(angle.reason), so it's b-roll rather than a second camera take. To make it a camera take: \(command(angle.mediaID, role: .camera))")
        }
        if let rate = refresh.frameRate {
            lines.append("Frame rate: \(String(format: "%g", rate.framesPerSecond)) fps, the camera take's. To change it: tandem apply '{\"updateSettings\": {\"patch\": {\"frameRate\": {\"numerator\": 30, \"denominator\": 1}}}}'")
        }
        return lines
    }

    private func serve(_ args: Arguments) async throws -> Int32 {
        try args.expectPositionals(atMost: 0, command: "serve")
        let url = try project(args)
        let port = try args.integer("port") ?? 0
        guard (0...65535).contains(port) else { throw UsageError(message: "--port must be between 0 and 65535.") }
        let session = try ProjectSession.open(url, owner: .cli)
        let host: TandemAPIHost
        do {
            host = try await TandemAPIHost.start(session: session, fontInstaller: LibraryFontInstaller.shared, port: UInt16(port))
        } catch {
            session.close()
            throw error
        }
        let project = session.coordinator.project
        StandardOutput.line("Serving \"\(project.name)\" on http://127.0.0.1:\(host.port) (pid \(getpid())). The token is in \(ProjectSession.lockURL(for: url).path). Stop with Ctrl-C.")
        let log = Task {
            for await event in host.service.events.subscribe() where event.isChange {
                let line = "r\(event.revision ?? 0) \(event.kind.rawValue) \"\(event.label ?? "")\" by \(event.author ?? "?")\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        // Stop on Ctrl-C or kill, or when the app asks for the project.
        let release = Signals.Trigger()
        host.server.onRelease = { release.fire() }
        await Signals.wait(for: [SIGINT, SIGTERM], or: release)
        log.cancel()
        host.stop()
        session.close()
        StandardOutput.line("Stopped. Saved revision \(session.savedRevision).")
        return 0
    }

    private func mcp(_ args: Arguments) async -> Int32 {
        // A client that goes away mid-write shouldn't kill the process.
        signal(SIGPIPE, SIG_IGN)
        let options = MCPServer.Options(project: args.options["project"], directory: directory, author: args.options["author"], environment: environment)
        await MCPServer(options: options, output: StandardOutput.handle).run()
        return 0
    }

    private func follow(_ client: ProjectClient, json: Bool) async throws -> Int32 {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        if !json {
            FileHandle.standardError.write(Data("Watching \(client.projectURL.lastPathComponent). Stop with Ctrl-C.\n".utf8))
        }
        for try await event in client.events() {
            if json {
                StandardOutput.line(String(decoding: try ServiceJSON.encoder().encode(event), as: UTF8.self))
            } else {
                var line = "\(formatter.string(from: event.date))  "
                switch event.kind {
                case .jobs:
                    let active = (event.jobs ?? []).filter { $0.state == .running || $0.state == .queued }
                    line += "jobs: " + (active.isEmpty ? "idle" : active.map { "\($0.kind.rawValue) \($0.mediaID) \($0.state.rawValue)" }.joined(separator: ", "))
                case .export:
                    if let job = event.export {
                        line += "export \((job.output as NSString).lastPathComponent) \(job.state.rawValue) \(Int(job.progress * 100))%"
                    }
                default:
                    line += "r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))"
                }
                StandardOutput.line(line)
            }
        }
        return 0
    }

    // MARK: - Helpers

    /// Prints a wait's progress as it goes (not with --json, whose output
    /// is the one result).
    private func progress(_ request: WaitRequest, json: Bool) -> (@Sendable (ServiceEvent) -> Void)? {
        guard !json else { return nil }
        let progress = WaitProgress(request)
        return { event in
            for line in progress.lines(for: event) { StandardOutput.line(line) }
        }
    }

    /// A media ID, clip ID or path as given. A path to a file that exists
    /// from here is made absolute, since the service reads relative paths
    /// against the project folder.
    private func mediaReference(_ text: String) -> String {
        let expanded = NSString(string: text).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return expanded }
        let here = directory.appendingPathComponent(expanded).standardizedFileURL
        return FileManager.default.fileExists(atPath: here.path) ? here.path : text
    }

    private func project(_ args: Arguments) throws -> URL {
        try ProjectLocator.find(args.options["project"], in: directory, environment: environment)
    }

    private func author(_ args: Arguments) -> String {
        args.options["author"] ?? environment["TANDEM_AUTHOR"] ?? "cli"
    }

    /// A revision stays as it is; a path is made absolute from here.
    private func reference(_ text: String) -> String {
        let digits = text.hasPrefix("r") ? String(text.dropFirst()) : text
        return Int(digits) != nil ? text : absolute(text)
    }

    private func absolute(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return directory.appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// `tandem frames`'s default file: named for its times, with dots
    /// where the times have colons, since ffmpeg and others read a colon
    /// in a file name as a protocol.
    static func sheetName(times: [Time], every: Time?, from: Time?, to: Time?) -> String {
        var name = "frames"
        if let every {
            name += "-every-\(String(format: "%g", every.seconds))s"
            if from != nil || to != nil {
                name += "-\(TimeText.fileSafe(from ?? .zero))-\(to.map(TimeText.fileSafe) ?? "end")"
            }
        } else if let first = times.min(), let last = times.max() {
            name += "-\(TimeText.fileSafe(first))"
            if last != first { name += "-\(TimeText.fileSafe(last))" }
        }
        return name + ".png"
    }

    private func parseTime(_ text: String) throws -> Time {
        guard let time = TimeText.parse(text), time >= .zero else {
            throw UsageError(message: "\"\(text)\" isn't a time. Use seconds (83.5) or mm:ss.mmm (01:23.500).")
        }
        return time
    }

    private func time(_ args: Arguments, _ name: String) throws -> Time? {
        guard let text = args.options[name] else { return nil }
        return try parseTime(text)
    }

    private func seconds(_ args: Arguments, _ name: String) throws -> Double? {
        try time(args, name)?.seconds
    }

    /// Reads the batch for `apply` from a file or stdin. Accepts a batch
    /// object, a list of commands, or a single command.
    private func applyRequest(_ args: Arguments) throws -> ApplyRequest {
        let source = try args.positional(0, "a JSON file, - to read standard input, or the batch itself", command: "apply")
        let data: Data
        if source == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else if let first = source.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
            // The batch itself, quoted on the command line.
            data = Data(source.utf8)
        } else {
            let url = URL(fileURLWithPath: absolute(source))
            guard let contents = try? Data(contentsOf: url) else { throw UsageError(message: "Couldn't read \(url.path).") }
            data = contents
        }
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ServiceError(.badRequest, "That isn't valid JSON: \(error.localizedDescription)")
        }
        var request: ApplyRequest
        switch value {
        case .object(let fields) where fields["commands"] != nil:
            request = try ServiceJSON.decodeRequest(ApplyRequest.self, from: data)
        case .array(let items):
            request = ApplyRequest(commands: try items.enumerated().flatMap { try CommandJSON.decodeAll($1, path: "[\($0)]") })
        case .object:
            request = ApplyRequest(commands: try CommandJSON.decodeAll(value))
        default:
            throw ServiceError(.badRequest, "Expected a batch object, a list of commands or one command.")
        }
        if let label = args.options["label"] { request.label = label }
        if let author = args.options["author"] { request.author = author }
        if let expected = try args.integer("expect") { request.expectedRevision = expected }
        if let key = args.options["key"] { request.idempotencyKey = key }
        if args.has("dry-run") { request.dryRun = true }
        return request
    }

    /// A sync delay: seconds (0.08 or 0.08s), or milliseconds (80ms).
    static func syncDelay(_ text: String) throws -> Time {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("ms"), let ms = Double(value.dropLast(2)) { return Time(seconds: ms / 1000) }
        if let seconds = Double(value.hasSuffix("s") ? String(value.dropLast()) : value) { return Time(seconds: seconds) }
        throw UsageError(message: "\(text) isn't a delay or a file. Give seconds, like tandem sync 0.08, milliseconds, like tandem sync 80ms, or files to line up with the camera by sound, like tandem sync mic.wav.")
    }

    /// Whether `tandem sync`'s argument names a file to line up by sound
    /// rather than a delay: a media ID, or something with a slash or an
    /// extension that isn't a number.
    static func isSyncFile(_ text: String) -> Bool {
        if (try? syncDelay(text)) != nil { return false }
        return text.hasPrefix("med_") || text.contains("/") || text.contains(".")
    }

    /// Clears comments an agent has done: one undoable edit, credited to it.
    private func resolveComments(_ ids: [String], all: Bool, label: String?, client: ProjectClient, json: Bool) async throws -> Int32 {
        guard all != !ids.isEmpty else {
            throw UsageError(message: all ? "Give comment IDs or --all, not both." : "`tandem comments resolve` needs the IDs of the comments you've done (from tandem comments), or --all.")
        }
        let listed = try await client.call(CommentsRequest())
        let known = Set(listed.comments.map(\.id))
        if let stranger = ids.first(where: { !known.contains($0) }) {
            throw UsageError(message: "\(stranger) isn't one of Mike's comments. tandem comments lists them.")
        }
        let chosen = all ? listed.comments.map(\.id) : ids
        guard !chosen.isEmpty else {
            StandardOutput.line("No comments to resolve.")
            return 0
        }
        let batch = CommentEdits.remove(chosen, label: label ?? (chosen.count == 1 ? "Resolve comment" : "Resolve \(chosen.count) comments"))
        let request = ApplyRequest(label: batch.label, commands: batch.commands, expectedRevision: listed.revision)
        return show(try await client.call(request), json: json)
    }

    /// `tandem handback`: a JSON list of things to look at (quoted, in a
    /// file, or - for standard input), one from --at and --name, or nothing
    /// to list what Mike hasn't watched yet.
    private func handbackRequest(_ args: Arguments) throws -> HandbackRequest {
        let flags = ["at", "to", "name", "note"].filter { args.options[$0] != nil } + (args.has("question") ? ["question"] : [])
        if let source = args.positionals.first {
            guard flags.isEmpty else { throw UsageError(message: "Give the JSON list or --\(flags[0]), not both.") }
            let data: Data
            if source == "-" {
                data = FileHandle.standardInput.readDataToEndOfFile()
            } else if let first = source.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
                data = Data(source.utf8)
            } else {
                let url = URL(fileURLWithPath: absolute(source))
                guard let contents = try? Data(contentsOf: url) else { throw UsageError(message: "Couldn't read \(url.path).") }
                data = contents
            }
            let shape = "Each thing to look at is {\"at\": \"2:45\", \"to\": \"3:10\", \"name\": \"a few words on what's there\", \"note\": \"one short line more, or the question\", \"question\": true}; only at and name are needed."
            if let one = try? ServiceJSON.decoder().decode(HandbackNote.self, from: data) { return HandbackRequest(notes: [one]) }
            do {
                return HandbackRequest(notes: try ServiceJSON.decodeRequest([HandbackNote].self, from: data))
            } catch {
                throw UsageError(message: "Couldn't read the things to look at: \(error.localizedDescription) \(shape)")
            }
        }
        guard !flags.isEmpty else { return HandbackRequest() }
        guard let at = args.options["at"] else { throw UsageError(message: "--\(flags[0]) goes with --at <time>, where the stretch starts.") }
        guard let name = args.options["name"], !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw UsageError(message: "--at needs --name: one line saying what's there to see.")
        }
        let note = HandbackNote(at: try parseTime(at), to: try time(args, "to"), name: name, note: args.options["note"], question: args.has("question") ? true : nil)
        return HandbackRequest(notes: [note])
    }

    private func show<R: Encodable & ReadableResult>(_ result: R, json: Bool) -> Int32 {
        if json {
            guard let data = try? ServiceJSON.encoder(pretty: true).encode(result) else { return 1 }
            StandardOutput.line(String(decoding: data, as: UTF8.self))
        } else {
            StandardOutput.line(result.readableText)
        }
        return 0
    }

    private func fail(_ error: ServiceError, json: Bool) -> Int32 {
        if json, let data = try? ServiceJSON.encoder(pretty: true).encode(ErrorEnvelope(error: error)) {
            StandardOutput.line(String(decoding: data, as: UTF8.self))
        } else {
            FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
        }
        return 1
    }

    private func usage(_ message: String, command: CommandHelp?) -> Int32 {
        var text = "error: \(message)\n"
        if let command { text += "Usage: \(command.usage)\n" } else { text += "Run `tandem help` for the commands.\n" }
        FileHandle.standardError.write(Data(text.utf8))
        return 2
    }
}

/// Waits for a signal instead of dying on it, so `serve` can save and let
/// go of the project.
enum Signals {
    /// A way to end the wait from code, like a signal would.
    final class Trigger: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (() -> Void)?
        private var fired = false

        func fire() {
            let run = lock.withLock { () -> (() -> Void)? in
                fired = true
                return handler
            }
            run?()
        }

        func onFire(_ body: @escaping () -> Void) {
            let already = lock.withLock { () -> Bool in
                handler = body
                return fired
            }
            if already { body() }
        }
    }

    static func wait(for signals: [Int32], or trigger: Trigger? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.mikerosoft.tandem.signals")
            let once = SignalOnce()
            // Ignore the default handling so the sources below see the signal.
            let sources = signals.map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                return DispatchSource.makeSignalSource(signal: number, queue: queue)
            }
            let finish = {
                once.run {
                    for source in sources { source.cancel() }
                    continuation.resume()
                }
            }
            for source in sources {
                source.setEventHandler { finish() }
                source.resume()
            }
            // Keep the sources alive until a signal arrives.
            once.keep(sources)
            trigger?.onFire { queue.async { finish() } }
        }
    }
}

final class SignalOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var retained: [DispatchSourceSignal] = []

    func keep(_ sources: [DispatchSourceSignal]) {
        lock.withLock { retained = sources }
    }

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}

extension Array {
    /// Nil for an empty list, so a missing option stays missing.
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
