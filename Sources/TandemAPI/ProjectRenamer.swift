import Foundation
import TandemCore
import TandemMedia

/// Renames a project: Rename on the project list.
///
/// The file and the name Tandem shows both change. So do the files beside
/// it in `.tandem/` that go by the file's name (the agent edits waiting for
/// review, the undo history, the journal, the backups and the list's icon),
/// so the project keeps everything it had. Its media, cache and exports
/// don't change.
public enum ProjectRenamer {
    /// Renames the project at `url` to `name` and returns its new file.
    @discardableResult
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let url = url.standardizedFileURL
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = problem(with: name) { throw ServiceError(.badRequest, problem) }
        let old = url.deletingPathExtension().lastPathComponent
        if let lock = ProjectSession.liveLock(for: url) {
            let owner = lock.owner == .app ? "the Tandem app" : "another tandem command"
            throw ServiceError(.locked, "\(old) is open in \(owner), so it can't be renamed now. Close it there first.")
        }
        let target = url.deletingLastPathComponent().appendingPathComponent("\(name).\(ProjectFile.fileExtension)")
        let fileManager = FileManager.default
        let onlyCase = target.path.lowercased() == url.path.lowercased()
        if !onlyCase && fileManager.fileExists(atPath: target.path) {
            throw ServiceError(.badRequest, "There's already a project called \(name) in that folder.")
        }
        var (project, revision) = try ProjectFile.load(from: url)

        if target.path != url.path {
            try move(url, to: target)
            let companions: [(URL) -> URL] = [ProjectFile.journalURL(for:), ProjectFile.undoHistoryURL(for:), ProjectFile.reviewURL(for:), iconURL(for:)]
            for companion in companions {
                let from = companion(url)
                let to = companion(target)
                // Whatever an older file of the new name left behind isn't
                // this project's.
                if !onlyCase { try? fileManager.removeItem(at: to) }
                if fileManager.fileExists(atPath: from.path) { try? move(from, to: to) }
            }
            for backup in ProjectFile.backups(of: url) {
                let stamp = backup.deletingPathExtension().lastPathComponent.dropFirst(old.count)
                try? move(backup, to: backup.deletingLastPathComponent().appendingPathComponent("\(name)\(stamp).\(ProjectFile.fileExtension)"))
            }
            // Nothing holds it (checked above), so a lock file left is stale.
            try? fileManager.removeItem(at: ProjectSession.lockURL(for: url))
        }
        if project.name != name {
            project.name = name
            try ProjectFile.save(project, revision: revision, to: target)
        }
        return target
    }

    /// Why `name` can't be a project's name, or nil when it can.
    public static func problem(with name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Give it a name." }
        if name.contains("/") || name.contains(":") { return "A name can't have / or : in it." }
        if name.hasPrefix(".") { return "A name can't start with a full stop: the file would be hidden." }
        if name.count > 120 { return "That name's too long for a file." }
        return nil
    }

    /// The project list's icon for a project file (the app keeps it there).
    static func iconURL(for projectURL: URL) -> URL {
        ProjectFile.supportFolder(for: projectURL).appendingPathComponent("\(projectURL.deletingPathExtension().lastPathComponent).icon.png")
    }

    /// A move that also changes only a name's case, which the disk sees as
    /// the same name.
    private static func move(_ from: URL, to: URL) throws {
        let fileManager = FileManager.default
        guard from.path.lowercased() == to.path.lowercased() else {
            try fileManager.moveItem(at: from, to: to)
            return
        }
        let step = from.deletingLastPathComponent().appendingPathComponent(".renaming-\(UUID().uuidString)")
        try fileManager.moveItem(at: from, to: step)
        try fileManager.moveItem(at: step, to: to)
    }
}
