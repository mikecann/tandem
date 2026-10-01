import Foundation
import TandemCore
import TandemMedia

/// Copies a project into another folder as a project of its own: Duplicate
/// on the project list.
///
/// The copy plays the same files from where they are: every file the
/// project points at inside its old folder (media, Live Photo movies, LUTs)
/// is pointed back at from the new one, so nothing big is copied. The
/// project's own fonts come too, since titles find them by the folder they
/// sit in, and so does the analysis cache, cloned on the same disk so it
/// costs no time or space and proxies, transcripts and cutouts don't have
/// to be made again. It starts fresh: no undo history, nothing waiting for
/// review, and an ID of its own.
public enum ProjectDuplicator {
    /// Duplicates `source` into `folder` and returns the new project file:
    /// the same name, or `Name copy.tandem` when that's taken there.
    @discardableResult
    public static func duplicate(_ source: URL, into folder: URL) throws -> URL {
        let source = source.standardizedFileURL
        let folder = folder.standardizedFileURL
        let (project, revision) = try ProjectFile.load(from: source)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(freeName(for: source.lastPathComponent, in: folder))
        let old = ProjectFolder(root: source.deletingLastPathComponent())
        let new = ProjectFolder(root: folder)
        var copy = try relocated(project, from: old.root, to: new.root)
        copy.id = IDs.make("prj")
        if old.root.standardizedFileURL != new.root.standardizedFileURL {
            merge(old.assetsFolder.appendingPathComponent("font", isDirectory: true), into: new.assetsFolder.appendingPathComponent("font", isDirectory: true))
            // On another disk it would be a real copy of every proxy; the
            // copy makes its own instead.
            if sameVolume(old.root, new.root) { merge(old.cacheFolder, into: new.cacheFolder) }
        }
        ProjectFile.forgetHistory(of: target)
        try ProjectFile.save(copy, revision: revision, to: target)
        return target
    }

    /// The project with every file it points at reached from `newFolder`:
    /// relative when the file is inside it, absolute otherwise.
    public static func relocated(_ project: Project, from oldFolder: URL, to newFolder: URL) throws -> Project {
        let old = ProjectFolder(root: oldFolder)
        let new = ProjectFolder(root: newFolder)
        guard old.root.standardizedFileURL != new.root.standardizedFileURL else { return project }
        var map: [String: String] = [:]
        for reference in ProjectArchiver.references(in: project) {
            map[reference.stored] = new.path(for: old.url(forPath: reference.stored))
        }
        return try ProjectArchiver.rewritten(project, map: map).project
    }

    /// `ESLint.tandem`, or `ESLint copy.tandem`, `ESLint copy 2.tandem`...
    /// whichever is free in `folder`.
    static func freeName(for fileName: String, in folder: URL) -> String {
        let file = URL(fileURLWithPath: fileName)
        let ext = file.pathExtension.isEmpty ? ProjectFile.fileExtension : file.pathExtension
        let base = file.deletingPathExtension().lastPathComponent
        let taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
        var name = "\(base).\(ext)"
        var counter = 1
        while taken.contains(name.lowercased()) {
            name = counter == 1 ? "\(base) copy.\(ext)" : "\(base) copy \(counter).\(ext)"
            counter += 1
        }
        return name
    }

    /// Copies what `source` has that `destination` doesn't, folder by
    /// folder. On APFS each file is cloned, so it's instant and shares the
    /// disk space until one side changes. Anything already there is kept.
    static func merge(_ source: URL, into destination: URL) {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isFolder) else { return }
        guard fileManager.fileExists(atPath: destination.path) else {
            try? fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fileManager.copyItem(at: source, to: destination)
            return
        }
        guard isFolder.boolValue else { return }
        for name in (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? [] {
            merge(source.appendingPathComponent(name), into: destination.appendingPathComponent(name))
        }
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let first = volume(a), let second = volume(b) else { return false }
        return first.isEqual(second)
    }
}
