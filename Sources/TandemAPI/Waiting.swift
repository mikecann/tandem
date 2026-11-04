import Foundation
import TandemCore

// MARK: - waiting

/// What waits in each project of a folder: Mike's comments for the agent,
/// the places an agent handed back for him to look at, and the agent edits
/// he hasn't reviewed. It's what Threadbear's Tandem panel and badges show.
///
/// Threadbear asks every 15 to 20 seconds for every project in a thread's
/// folder, and a folder of Shorts cut from one interview holds dozens. The
/// usual `status` and `comments` open each project headless (taking its
/// lock, decoding the whole timeline and replaying its journal: over a
/// second for a long interview), so two processes per project on every
/// refresh kept Mike's Mac loaded. This reads, in one process, only the
/// markers in the project file and the review log beside it, takes no
/// lock (so it never holds a project the app is opening) and writes
/// nothing. A project the app or `tandem serve` has open is asked instead,
/// since its newest edits may not be saved yet, and one whose journal has
/// edits past the last save is opened the usual way, so a crash's edits
/// still count.
public enum ProjectsWaiting {
    public static func read(_ projects: [URL], author: String) async -> WaitingResult {
        var results: [WaitingProject] = []
        for url in projects {
            results.append(await read(url.standardizedFileURL, author: author))
        }
        return WaitingResult(projects: results)
    }

    static func read(_ url: URL, author: String) async -> WaitingProject {
        do {
            if let lock = ProjectSession.liveLock(for: url) {
                if let port = lock.port, let token = lock.token {
                    let client = TandemHTTPClient(port: port, token: token, author: author)
                    return WaitingProject(status: try await client.call(StatusRequest()), comments: try await client.call(CommentsRequest()), path: url.path)
                }
                // Held but not serving yet (the app opening it, a CLI
                // command mid-edit): the saved file may be behind, so wait
                // for its owner the way every command does.
                return try await full(url, author: author)
            }
            let file = try LightProject.load(url)
            if journalHasEdits(after: file.revision, for: url) {
                return try await full(url, author: author)
            }
            let log = ReviewLog.load(from: ProjectFile.reviewURL(for: url))
            let comments = file.project.markers.filter { $0.kind == .comment }.sorted { $0.time < $1.time }
            return WaitingProject(
                name: file.project.name,
                path: url.path,
                revision: file.revision,
                comments: comments.map { NoteComment(id: $0.id, time: $0.time, text: $0.name) },
                handback: log.notes.map { LookHere($0, comments: []) },
                reviewPending: log.entries.map(PendingReview.init)
            )
        } catch {
            // One broken project shouldn't hide the others' comments.
            return WaitingProject(
                name: url.deletingPathExtension().lastPathComponent, path: url.path, revision: nil,
                comments: [], handback: [], reviewPending: [], error: ServiceError.wrap(error).message
            )
        }
    }

    /// The usual `status` and `comments`, opening the project if no one has it.
    static func full(_ url: URL, author: String) async throws -> WaitingProject {
        let client = ProjectClient(projectURL: url, author: author)
        return WaitingProject(status: try await client.call(StatusRequest()), comments: try await client.call(CommentsRequest()), path: url.path)
    }

    /// True when the journal holds an edit newer than the saved file: a
    /// crash left it there, and the next open replays it. Only each line's
    /// revision is decoded, since an undo's line holds a whole project.
    static func journalHasEdits(after revision: Int, for url: URL) -> Bool {
        guard let data = try? Data(contentsOf: ProjectFile.journalURL(for: url)), !data.isEmpty else { return false }
        struct Header: Decodable { var revision: Int }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).contains { line in
            ((try? decoder.decode(Header.self, from: Data(line)))?.revision ?? 0) > revision
        }
    }

    /// Just the parts of a project file `waiting` needs. JSONDecoder skips
    /// the keys a type doesn't name, so the timeline's clips are parsed but
    /// never built into a model.
    struct LightProject: Decodable {
        struct Body: Decodable {
            var schemaVersion: Int
            var name: String
            var markers: [Marker]

            // The same defaults as Project's own decoder, so `waiting` and
            // `status` agree about a file missing a key.
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Project.currentSchemaVersion
                name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
                markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
            }

            enum CodingKeys: String, CodingKey { case schemaVersion, name, markers }
        }

        var revision: Int
        var project: Body

        static func load(_ url: URL) throws -> LightProject {
            do {
                let file = try JSONDecoder().decode(LightProject.self, from: try Data(contentsOf: url))
                // A newer Tandem's file may keep comments somewhere this
                // one doesn't know; say so, as opening it would.
                guard file.project.schemaVersion <= Project.currentSchemaVersion else {
                    throw ServiceError(.invalid, "\(url.lastPathComponent) was saved by a newer Tandem (schema \(file.project.schemaVersion)).")
                }
                return file
            } catch let error as DecodingError {
                throw ServiceError(.invalid, "\(url.lastPathComponent) couldn't be read: \(DecodingErrorText.describe(error))")
            }
        }
    }
}

public struct WaitingResult: Codable, Sendable {
    public var projects: [WaitingProject]
}

public struct WaitingProject: Codable, Sendable {
    public var name: String
    public var path: String
    /// Nil when the project couldn't be read (see `error`).
    public var revision: Int?
    /// Mike's comments for the agent, earliest first. `tandem comments` has
    /// what's said and playing at each.
    public var comments: [NoteComment]
    /// What agents handed back for Mike to look at, in timeline order.
    public var handback: [LookHere]
    /// Agent edits Mike hasn't reviewed, oldest first.
    public var reviewPending: [PendingReview]
    public var error: String?

    init(name: String, path: String, revision: Int?, comments: [NoteComment], handback: [LookHere], reviewPending: [PendingReview], error: String? = nil) {
        self.name = name
        self.path = path
        self.revision = revision
        self.comments = comments
        self.handback = handback
        self.reviewPending = reviewPending
        self.error = error
    }

    init(status: StatusResult, comments: CommentsResult, path: String) {
        self.init(
            name: status.name, path: path, revision: status.revision,
            comments: comments.comments.map { NoteComment(id: $0.id, time: $0.time, text: $0.text) },
            handback: status.handback ?? [], reviewPending: status.reviewPending ?? []
        )
    }
}

extension WaitingResult: ReadableResult {
    public var readableText: String {
        guard !projects.isEmpty else { return "No projects here." }
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
        return projects.map { project in
            if let error = project.error { return "\(project.name): \(error)" }
            let parts = [
                count(project.comments.count, "comment for the agent", "comments for the agent"),
                count(project.handback.count, "place to look at", "places to look at"),
                count(project.reviewPending.count, "edit waiting for review", "edits waiting for review"),
            ].compactMap { $0 }
            return "\(project.name): \(parts.isEmpty ? "nothing waiting" : parts.joined(separator: ", "))"
        }.joined(separator: "\n")
    }
}
