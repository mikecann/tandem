import Foundation
import TandemCore

// MARK: - join

/// Finds through-edits, cuts where a clip carries straight on into the
/// next piece of the same file with the same settings, and joins each back
/// into one clip, with the clips linked to it across the cut (camera,
/// screen and voice), so the timeline shows one take where nothing was
/// cut. Putting cuts back with ripple trims leaves them behind. What plays
/// doesn't change (`ThroughEdits` has the rules). A dry run that lists
/// them, and the ones that can't be joined with why, unless `apply`.
public struct JoinRequest: ServiceCall {
    public static let operation = ServiceOperation.join
    /// Only cuts at or after this time.
    public var from: Time?
    /// Only cuts at or before this time.
    public var to: Time?
    /// Join them. Without it this is a dry run that returns the plan.
    public var apply: Bool?
    public var label: String?
    public var author: String?
    /// Refuse unless the project is at this revision.
    public var expectedRevision: Int?

    public init(
        from: Time? = nil, to: Time? = nil, apply: Bool? = nil,
        label: String? = nil, author: String? = nil, expectedRevision: Int? = nil
    ) {
        self.from = from
        self.to = to
        self.apply = apply
        self.label = label
        self.author = author
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeTime(.from)
        to = try c.decodeTime(.to)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> JoinResult {
        try service.join(self, context: context)
    }
}

public struct JoinResult: Codable, Sendable {
    /// The revision the plan was made against.
    public var revision: Int
    /// Each through-edit joined (or that would be), earliest first.
    public var joins: [PlannedJoin]
    /// Cuts that look like through-edits but would play differently
    /// joined, earliest first, and why.
    public var skipped: [SkippedJoin]
    /// The batch that joins them. Pass it to `apply` to run it yourself.
    public var commands: [EditCommand]
    /// Set when the plan was applied.
    public var applied: ApplyResult?
    public var warnings: [String]
}

/// One cut joined, on every track it ran through.
public struct PlannedJoin: Codable, Equatable, Sendable {
    /// Where the cut is.
    public var time: Time
    /// A clip and the clip after it, per track, top track first.
    public var clips: [JoinedClips]
}

public struct JoinedClips: Codable, Equatable, Sendable {
    /// As `timeline` names tracks: V1 is the bottom video track, A1 the
    /// top audio one.
    public var track: String
    public var trackID: String
    /// The clip that stays, playing both.
    public var clipID: String
    /// The clip after it, which goes.
    public var nextClipID: String
}

/// A cut that looks like a through-edit but can't be joined.
public struct SkippedJoin: Codable, Equatable, Sendable {
    public var time: Time
    public var track: String
    public var trackID: String
    public var clipID: String
    public var nextClipID: String
    public var reason: String
}

extension JoinResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        if joins.isEmpty {
            lines.append(skipped.isEmpty ? "No through-edits to join." : "No through-edits that can be joined.")
        } else {
            let count = joins.count == 1 ? "1 through-edit" : "\(joins.count) through-edits"
            lines.append("Join \(count) (\(mode), revision \(revision)), each into one clip that plays what the two did:")
            for join in joins {
                lines.append("  \(join.time)  " + join.clips.map { "\($0.track) \($0.clipID) + \($0.nextClipID)" }.joined(separator: ", "))
            }
        }
        if !skipped.isEmpty {
            let count = skipped.count == 1 ? "1 cut that looks like a through-edit" : "\(skipped.count) cuts that look like through-edits"
            lines.append("Leaves \(count), as joining would change what plays:")
            for skip in skipped {
                lines.append("  \(skip.time)  \(skip.track) \(skip.clipID) + \(skip.nextClipID): \(skip.reason)")
            }
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else if !joins.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to join them.")
        }
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    public func join(_ request: JoinRequest, context: CallContext) throws -> JoinResult {
        if let from = request.from, let to = request.to, to < from {
            throw ServiceError(.badRequest, "`to` (\(to)) can't be before `from` (\(from)).")
        }
        let (project, revision) = coordinator.snapshot()
        if let expected = request.expectedRevision, expected != revision {
            throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
        }
        var range: TimeRange?
        if request.from != nil || request.to != nil {
            let start = request.from ?? .zero
            range = TimeRange(start: start, end: max(request.to ?? project.duration, start))
        }
        // The plan is the command itself, run on a copy.
        var working = project
        let report = ThroughEdits.joinAll(&working, in: range)
        if let problem = ProjectValidator.validate(working).first(where: { $0.severity == .error }) {
            throw ServiceError(.invalid, "Invalid edit: \(problem.message)")
        }
        let tracks = Self.trackLabels(project)
        var result = JoinResult(
            revision: revision,
            joins: report.joins.map { join in
                let clips = join.pairs.sorted { (tracks[$0.trackID]?.order ?? 0) < (tracks[$1.trackID]?.order ?? 0) }.map { pair in
                    JoinedClips(track: tracks[pair.trackID]?.label ?? pair.trackID, trackID: pair.trackID, clipID: pair.clipID, nextClipID: pair.nextClipID)
                }
                return PlannedJoin(time: join.time, clips: clips)
            },
            skipped: report.skipped.map { skip in
                SkippedJoin(
                    time: skip.time, track: tracks[skip.pair.trackID]?.label ?? skip.pair.trackID, trackID: skip.pair.trackID,
                    clipID: skip.pair.clipID, nextClipID: skip.pair.nextClipID, reason: skip.reason
                )
            },
            commands: report.joins.isEmpty ? [] : [.joinThroughEdits(range: range)],
            applied: nil,
            warnings: []
        )
        guard request.apply == true, !report.joins.isEmpty else { return result }
        let count = report.joins.count
        let label = request.label ?? (count == 1 ? "Join 1 through-edit" : "Join \(count) through-edits")
        let applied = try apply(ApplyRequest(label: label, author: request.author, commands: result.commands, expectedRevision: revision), context: context)
        result.applied = applied
        // The cuts it left are listed already.
        let listed = Set(ThroughEdits.warnings(report, in: project))
        result.warnings = applied.warnings.filter { !listed.contains($0) }
        return result
    }

    /// Each track's name as `timeline` gives it ("V2 Camera") and where it
    /// shows: video tracks top to bottom, then audio ones.
    static func trackLabels(_ project: Project) -> [String: (label: String, order: Int)] {
        var labels: [String: (label: String, order: Int)] = [:]
        for (index, track) in project.videoTracks.enumerated().reversed() {
            labels[track.id] = ("V\(index + 1) \(track.name)", labels.count)
        }
        for (index, track) in project.audioTracks.enumerated() {
            labels[track.id] = ("A\(index + 1) \(track.name)", labels.count)
        }
        return labels
    }
}
