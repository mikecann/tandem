import Foundation

/// The one place a project changes. Every client (the app UI, the CLI in
/// headless mode, the local API that agents use) submits `EditBatch`es here.
///
/// A batch is applied to a copy of the project, validated as a whole, and
/// only then committed, so a failing command leaves nothing half done. Each
/// commit bumps the revision, becomes one undo step, is appended to the
/// crash-recovery journal and is announced to observers.
///
/// All state is guarded by a serial queue, so it is safe to call from any
/// thread. Observers are called on that queue; hop to the main thread in UI
/// code.
public final class ProjectCoordinator: @unchecked Sendable {
    public struct CommitResult: Codable, Equatable, Sendable {
        public var revision: Int
        public var label: String
        public var author: String
        /// IDs of things the batch created (clips, tracks, transitions,
        /// markers), in creation order, so callers can refer to them without
        /// re-reading the whole project.
        public var createdIDs: [String]
        /// Things worth telling the user that didn't block the edit.
        public var warnings: [String]
    }

    public struct ChangeEvent: Sendable {
        public enum Kind: String, Sendable { case edit, undo, redo, reload }
        public var kind: Kind
        public var revision: Int
        public var label: String
        public var author: String
        /// The project either side of the change. Observers run inside the
        /// coordinator and can't read it back, so the review log works out
        /// what an agent's batch did from these.
        public var before: Project?
        public var after: Project?
    }

    private struct UndoEntry {
        var label: String
        var author: String
        var before: Project
        var after: Project
    }

    private let queue = DispatchQueue(label: "com.mikerosoft.tandem.coordinator")
    private var _project: Project
    private var _revision: Int
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var idempotencyResults: [String: CommitResult] = [:]
    /// Revisions made by the app finding new files in the folder. They only
    /// add or refresh media, so a batch read before them can still go ahead.
    private var mediaScanRevisions: Set<Int> = []
    private var observers: [UUID: (ChangeEvent) -> Void] = [:]
    private let journal: ProjectJournal?
    private let sourceFolder: FolderAnchor?
    private let maxUndo = 500

    public init(project: Project, revision: Int = 0, journal: ProjectJournal? = nil, sourceFolder: URL? = nil) {
        self._project = project
        self._revision = revision
        self.journal = journal
        self.sourceFolder = sourceFolder.map(FolderAnchor.init)
    }

    public var project: Project { queue.sync { _project } }
    public var revision: Int { queue.sync { _revision } }

    /// The project and its revision read together, for callers that want to
    /// send `expectedRevision` with their next batch.
    public func snapshot() -> (project: Project, revision: Int) {
        queue.sync { (_project, _revision) }
    }

    /// Whether a caller that read the project at `expected` can still edit
    /// it at `revision`: nothing changed since, or the only changes are
    /// media scans. Media scans add files and refresh their details, which
    /// doesn't change anything an agent read off the timeline, so they
    /// shouldn't fail its `expectedRevision`. Any other edit, an undo or a
    /// reload in between makes it stale.
    public func isCurrent(_ expected: Int, at revision: Int) -> Bool {
        queue.sync { _isCurrent(expected, at: revision) }
    }

    private func _isCurrent(_ expected: Int, at revision: Int) -> Bool {
        guard expected <= revision else { return false }
        return (expected..<revision).allSatisfy { mediaScanRevisions.contains($0 + 1) }
    }

    /// The files' measured loudness by media ID, from whoever owns the
    /// media analysis (the session). A `normalizeSpeech` without
    /// measurements gets these before its batch runs, and the journal
    /// records the batch with them, so replaying it doesn't need the
    /// analysis. Called off the coordinator's queue.
    public var measureSound: (@Sendable (Project) -> [String: MeasuredSound])? {
        get { measureLock.withLock { _measureSound } }
        set { measureLock.withLock { _measureSound = newValue } }
    }
    private var _measureSound: (@Sendable (Project) -> [String: MeasuredSound])?
    private let measureLock = NSLock()

    /// `batch` with the measurements filled in where a command wants them.
    private func measuring(_ batch: EditBatch) -> EditBatch {
        guard batch.commands.contains(where: { if case .normalizeSpeech(nil) = $0 { return true } else { return false } }),
              let measure = measureSound else { return batch }
        let measured = measure(project)
        var filled = batch
        filled.commands = batch.commands.map { command in
            if case .normalizeSpeech(nil) = command { return .normalizeSpeech(measured: measured) }
            return command
        }
        return filled
    }

    public var undoLabel: String? { queue.sync { undoStack.last?.label } }
    public var redoLabel: String? { queue.sync { redoStack.last?.label } }

    @discardableResult
    public func apply(_ submitted: EditBatch) throws -> CommitResult {
        let batch = measuring(submitted)
        return try queue.sync {
            if let key = batch.idempotencyKey, let previous = idempotencyResults[key] {
                return previous
            }
            if let expected = batch.expectedRevision, expected != _revision, batch.changesMedia || !_isCurrent(expected, at: _revision) {
                throw EditError.staleRevision(expected: expected, actual: _revision)
            }
            var working = _project
            var context = EditContext(sourceFolder: sourceFolder?.url)
            let issues = try Editing.apply(batch, to: &working, context: &context)
            let before = _project
            _project = working
            _revision += 1
            if batch.isMediaScan {
                mediaScanRevisions.insert(_revision)
                // Only recent revisions matter; anything older is long stale.
                if mediaScanRevisions.count > maxUndo { mediaScanRevisions = mediaScanRevisions.filter { $0 > _revision - maxUndo } }
            }
            undoStack.append(UndoEntry(label: batch.label, author: batch.author, before: before, after: working))
            if undoStack.count > maxUndo { undoStack.removeFirst(undoStack.count - maxUndo) }
            redoStack.removeAll()
            let result = CommitResult(
                revision: _revision,
                label: batch.label,
                author: batch.author,
                createdIDs: context.createdIDs,
                warnings: context.warnings + ProjectValidator.newWarnings(issues, since: before)
            )
            if let key = batch.idempotencyKey { idempotencyResults[key] = result }
            journal?.append(batch: batch, revision: _revision, seed: context.seed)
            notify(ChangeEvent(kind: .edit, revision: _revision, label: batch.label, author: batch.author, before: before, after: working))
            return result
        }
    }

    /// Undoes the last batch. Returns nil if there is nothing to undo.
    @discardableResult
    public func undo() -> CommitResult? {
        queue.sync {
            guard let entry = undoStack.popLast() else { return nil }
            let replaced = _project
            _project = entry.before
            _revision += 1
            redoStack.append(entry)
            journal?.appendSnapshot(project: _project, revision: _revision, reason: "undo \(entry.label)")
            notify(ChangeEvent(kind: .undo, revision: _revision, label: entry.label, author: entry.author, before: replaced, after: _project))
            return CommitResult(revision: _revision, label: "Undo \(entry.label)", author: entry.author, createdIDs: [], warnings: [])
        }
    }

    @discardableResult
    public func redo() -> CommitResult? {
        queue.sync {
            guard let entry = redoStack.popLast() else { return nil }
            let replaced = _project
            _project = entry.after
            _revision += 1
            undoStack.append(entry)
            journal?.appendSnapshot(project: _project, revision: _revision, reason: "redo \(entry.label)")
            notify(ChangeEvent(kind: .redo, revision: _revision, label: entry.label, author: entry.author, before: replaced, after: _project))
            return CommitResult(revision: _revision, label: "Redo \(entry.label)", author: entry.author, createdIDs: [], warnings: [])
        }
    }

    /// Replaces the whole project, for example after the file changed on
    /// disk while the app was closed. Clears undo history. `label` and
    /// `author` say what it was for the edit history, when it's really an
    /// undo or redo of a headless edit.
    public func reload(_ project: Project, label: String = "Reload", author: String = EditAuthor.system) {
        queue.sync {
            let replaced = _project
            _project = project
            _revision += 1
            undoStack.removeAll()
            redoStack.removeAll()
            // Journaled like an undo: edits after this are relative to the
            // new project, so a replay after a crash has to start from it.
            journal?.appendSnapshot(project: project, revision: _revision, reason: "reload")
            notify(ChangeEvent(kind: .reload, revision: _revision, label: label, author: author, before: replaced, after: project))
        }
    }

    /// What undo would undo, newest first, with the project either side of
    /// each step, so `history` can say where each edit was.
    public func undoSteps(limit: Int = 50) -> [(label: String, author: String, before: Project, after: Project)] {
        queue.sync { undoStack.suffix(limit).reversed().map { ($0.label, $0.author, $0.before, $0.after) } }
    }

    /// Recent undo labels, newest first, for the activity feed.
    public func history(limit: Int = 50) -> [(label: String, author: String)] {
        queue.sync { undoStack.suffix(limit).reversed().map { ($0.label, $0.author) } }
    }

    @discardableResult
    public func observe(_ handler: @escaping (ChangeEvent) -> Void) -> UUID {
        let token = UUID()
        queue.sync { observers[token] = handler }
        return token
    }

    public func removeObserver(_ token: UUID) {
        queue.sync { _ = observers.removeValue(forKey: token) }
    }

    private func notify(_ event: ChangeEvent) {
        for handler in observers.values { handler(event) }
    }
}
