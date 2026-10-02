import Foundation

/// Mike's comments: notes he leaves at a moment on the timeline for the
/// next round of agent edits ("cut the umm here"). They're markers of kind
/// `comment`, so they move with the edits around them, and the agent that
/// does what one asks removes it, in the same batch as the fix.
extension Project {
    /// The comments waiting, earliest first.
    public var comments: [Marker] {
        markers.filter { $0.kind == .comment }.sorted { $0.time < $1.time }
    }
}

/// The edits that add, change and remove comments.
public enum CommentEdits {
    /// A comment saying `text` at `time`, or nil when there's nothing to say.
    public static func add(_ text: String, at time: Time, id: String = IDs.make("mk")) -> EditBatch? {
        let text = tidy(text)
        guard !text.isEmpty else { return nil }
        return EditBatch(label: "Add comment", commands: [
            .addMarker(marker: Marker(id: id, time: max(.zero, time), name: text, kind: .comment))
        ])
    }

    /// The comment saying `text` instead. Emptied, it goes; unchanged,
    /// there's nothing to do (nil).
    public static func edit(_ comment: Marker, to text: String) -> EditBatch? {
        let text = tidy(text)
        if text.isEmpty { return remove([comment.id]) }
        guard text != comment.name else { return nil }
        return EditBatch(label: "Edit comment", commands: [
            .updateMarker(markerID: comment.id, patch: .object(["name": .string(text)]))
        ])
    }

    /// Takes comments away: Mike deleting his own, or an agent clearing the
    /// ones it has done (`label` "Resolve comment").
    public static func remove(_ ids: [String], label: String? = nil) -> EditBatch {
        EditBatch(
            label: label ?? (ids.count == 1 ? "Delete comment" : "Delete \(ids.count) comments"),
            commands: ids.map { .removeMarker(markerID: $0) }
        )
    }

    /// What a comment keeps of what was typed: no spaces or blank lines at
    /// either end.
    public static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A comment on one line, for the ruler and lists.
    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " / ")
    }
}
