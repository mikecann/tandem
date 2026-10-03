import Foundation
import TandemCore
import TandemMedia

// MARK: - sync

/// Puts a take's picture back in step with its sound. A webcam's picture
/// lags its microphone (Mike's by about 0.08 s), so lips and voice drift
/// apart. This sets how late each file's picture is
/// (`MediaItem.pictureDelay`): every clip of the file then shows its
/// picture that much later in the file, in the app, frames, review clips,
/// checks and exports, while its sound and cuts stay put. Without `delay`
/// it says what's set.
public struct SyncRequest: ServiceCall {
    public static let operation = ServiceOperation.sync
    /// How late the picture is, in seconds (0.08 for 80 ms). 0 puts it
    /// back as recorded.
    public var delay: Time?
    /// The files to set it on. Default: every camera take.
    public var media: [String]?
    /// Make it the delay new camera takes get too (Tandem's settings).
    public var makeDefault: Bool?
    public var label: String?
    public var expectedRevision: Int?

    public init(delay: Time? = nil, media: [String]? = nil, makeDefault: Bool? = nil, label: String? = nil, expectedRevision: Int? = nil) {
        self.delay = delay
        self.media = media
        self.makeDefault = makeDefault
        self.label = label
        self.expectedRevision = expectedRevision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delay = try c.decodeTime(.delay)
        media = try c.decodeIfPresent([String].self, forKey: .media)
        makeDefault = try c.decodeIfPresent(Bool.self, forKey: .makeDefault)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
    }

    public func run(on service: TandemService, context: CallContext) async throws -> SyncResult {
        try service.sync(self, context: context)
    }
}

public struct SyncResult: Codable, Sendable {
    public var revision: Int
    /// Every file with a moving picture, camera takes first.
    public var files: [SyncFile]
    /// The delay new camera takes get (Tandem's settings).
    public var defaultDelay: Time
    /// The edit, when the delay changed.
    public var applied: ApplyResult?

    /// "80 ms".
    static func milliseconds(_ time: Time) -> String {
        "\(Int((time.seconds * 1000).rounded())) ms"
    }
}

public struct SyncFile: Codable, Sendable {
    public var id: String
    public var path: String
    public var role: MediaRole
    public var pictureDelay: Time?
    /// The lag its recorder already took out (Record It's Camera delay).
    public var pictureDelayCorrected: Time?
}

extension SyncResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if let applied { lines.append("Applied \"\(applied.label)\" by \(applied.author) as revision \(applied.revision).") }
        if files.isEmpty {
            lines.append("No files with a moving picture yet.")
        } else {
            lines.append("How late each file's picture is against its sound (each clip shows its picture that much later, so lips match the voice):")
            let idWidth = files.map(\.id.count).max() ?? 0
            for file in files {
                let delay = file.pictureDelay.flatMap { $0 == .zero ? nil : $0 }
                var state = delay.map(Self.milliseconds) ?? "as recorded"
                if let corrected = file.pictureDelayCorrected { state += ", in sync as recorded (Record It took out \(Self.milliseconds(corrected)))" }
                lines.append("  \(file.id.padding(toLength: idWidth, withPad: " ", startingAt: 0))  \(file.path)  \(file.role.rawValue)  \(state)")
            }
        }
        lines.append(defaultDelay == .zero
            ? "New camera takes keep their picture as recorded (tandem sync <seconds> --default sets a delay for them)."
            : "New camera takes get \(Self.milliseconds(defaultDelay)) (Tandem's settings).")
        return lines.joined(separator: "\n")
    }
}

extension TandemService {
    public func sync(_ request: SyncRequest, context: CallContext) throws -> SyncResult {
        var settings = TandemSettings.load()
        var applied: ApplyResult?
        if let delay = request.delay {
            guard abs(delay.seconds) <= 1 else {
                throw ServiceError(.badRequest, "\(delay.seconds) s is more than a second. Webcams run about 0.04 to 0.15 s behind their mic; the delay is in seconds, so 80 ms is 0.08.")
            }
            let (project, revision) = coordinator.snapshot()
            if let expected = request.expectedRevision, expected != revision {
                throw ServiceError.wrap(EditError.staleRevision(expected: expected, actual: revision))
            }
            let targets: [MediaItem]
            if let ids = request.media {
                targets = try ids.map { id in
                    guard let item = project.media(id) else { throw ServiceError(.notFound, "No media with ID \(id). tandem sync lists the files.") }
                    guard item.kind == .video, item.hasVideo else { throw ServiceError(.badRequest, "\(item.path) has no moving picture to delay.") }
                    return item
                }
            } else {
                // Takes Record It already corrected are in sync as they are.
                targets = project.media.filter { Self.isCameraTake($0) && $0.pictureDelayCorrected == nil }
            }
            let commands = targets.filter { ($0.pictureDelay ?? .zero) != delay }.map { item in
                EditCommand.updateMedia(mediaID: item.id, patch: .object(["pictureDelay": delay == .zero ? .null : .number(delay.seconds)]))
            }
            if !commands.isEmpty {
                let files = commands.count == 1 ? "1 file" : "\(commands.count) files"
                let label = request.label ?? (delay == .zero ? "Picture as recorded on \(files)" : "Picture delay \(SyncResult.milliseconds(delay)) on \(files)")
                applied = try apply(ApplyRequest(label: label, commands: commands, expectedRevision: request.expectedRevision), context: context)
            }
            if request.makeDefault == true {
                settings.cameraPictureDelay = delay.seconds
                do {
                    try settings.save()
                } catch {
                    throw ServiceError(.unavailable, "Couldn't save Tandem's settings: \(error.localizedDescription)")
                }
            }
        } else if request.media != nil || request.makeDefault == true {
            throw ServiceError(.badRequest, "Give the delay in seconds too, like tandem sync 0.08.")
        }
        let (project, revision) = coordinator.snapshot()
        let files = project.media.filter { $0.kind == .video && $0.hasVideo }
            .sorted { (Self.isCameraTake($0) ? 0 : 1, $0.path) < (Self.isCameraTake($1) ? 0 : 1, $1.path) }
            .map { SyncFile(id: $0.id, path: $0.path, role: $0.role, pictureDelay: $0.pictureDelay, pictureDelayCorrected: $0.pictureDelayCorrected) }
        return SyncResult(revision: revision, files: files, defaultDelay: Time(seconds: settings.cameraPictureDelay), applied: applied)
    }

    static func isCameraTake(_ item: MediaItem) -> Bool {
        item.role == .camera && item.kind == .video && item.hasVideo
    }
}
