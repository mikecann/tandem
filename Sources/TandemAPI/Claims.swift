import Foundation
import TandemCore
import TandemMedia

// MARK: - claims

/// `tandem claims`: the proof list. Every line Mike says on the timeline
/// that names something or makes a claim (`QualityCheck.claims`), what's on
/// screen over it now, and the agent's answer for it: a shot and a link, or
/// why nothing needs showing.
///
/// The answers live in `<name>.claims.json` beside the project
/// (`ProjectFile.claimsURL`), which this writes and the agent edits. Each
/// run reads the agent's answers back, matches them to the lines by their
/// words (so a cut that moves a line keeps its answer), adds any new lines
/// and writes the file again. `tandem check` reads the same file for its
/// `bareClaim` notes. With `markdown` it also writes the short list Mike
/// skims before the B-roll is built.
public struct ClaimsRequest: ServiceCall {
    public static let operation = ServiceOperation.claims
    /// Where to write the list for Mike, as Markdown: absolute, or relative
    /// to the project folder.
    public var markdown: String?

    public init(markdown: String? = nil) {
        self.markdown = markdown
    }

    public func run(on service: TandemService, context: CallContext) async throws -> ClaimsResult {
        try service.claims(self)
    }
}

/// One line in the proof list, with its answer.
public struct ClaimEntry: Codable, Equatable, Sendable {
    public var id: String
    public var start: Time
    public var end: Time
    public var said: String
    /// The words that made it a claim.
    public var because: [String]
    /// What's on screen while he says it, top first, or empty when it's
    /// the camera alone.
    public var onScreen: [String]
    /// How much of it is the camera full screen with nothing over it, 0 to 1.
    public var bare: Double
    public var shot: String?
    public var link: String?
    public var skip: String?

    public var isAnswered: Bool { shot != nil || link != nil || skip != nil }
}

public struct ClaimsResult: Codable, Sendable {
    public var revision: Int
    /// The claims file: answer each claim in it.
    public var file: String
    public var claims: [ClaimEntry]
    /// Answered lines that are no longer said on the timeline, kept in the
    /// file in case a cut brings them back.
    public var gone: [ClaimEntry]
    /// Where the list for Mike was written, when it was asked for.
    public var markdown: String?
    public var warnings: [String]

    public var answered: Int { claims.filter(\.isAnswered).count }
    /// Bare claims (camera full screen, nothing over most of it) with no
    /// skip: what `tandem check` notes.
    public var bareCount: Int { claims.filter { $0.bare > QualityCheck.claimBareShare && $0.skip == nil }.count }
}

extension ClaimsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let open = claims.count - answered
        lines.append("\(claims.count) line\(claims.count == 1 ? "" : "s") that name something or make a claim (revision \(revision)): \(answered) answered, \(open) to fill in, \(bareCount) bare on camera with no skip.")
        lines.append("Claims file: \(file)")
        for claim in claims {
            lines.append("")
            lines.append("\(claim.start)-\(claim.end)  \(claim.id)  \"\(claim.said)\"")
            lines.append("    because: \(claim.because.joined(separator: ", "))   on screen: \(Self.onScreen(claim))")
            if let shot = claim.shot { lines.append("    shot: \(shot)") }
            if let link = claim.link { lines.append("    link: \(link)") }
            if let skip = claim.skip { lines.append("    skip: \(skip)") }
        }
        if !gone.isEmpty {
            lines.append("")
            lines.append("\(gone.count) answered line\(gone.count == 1 ? " is" : "s are") no longer said on the timeline; the file keeps \(gone.count == 1 ? "it" : "them") under \"gone\" in case a cut brings \(gone.count == 1 ? "it" : "them") back.")
        }
        for warning in warnings { lines.append("Warning: \(warning)") }
        lines.append("")
        if open > 0 {
            lines.append("Fill each claim in the file: shot (what will show it: a file or clip you placed, or a description) and link (the real page: docs, PR, pricing page, post), or skip (why nothing needs showing). Then run tandem claims again, and tandem claims --markdown <file> for the list to pin for Mike.")
        } else if let markdown {
            lines.append("Wrote the list for Mike to \(markdown): pin it for him before building the B-roll.")
        } else {
            lines.append("Every claim is answered. tandem claims --markdown <file> writes the list to pin for Mike.")
        }
        return lines.joined(separator: "\n")
    }

    /// What's on screen over a claim, in words.
    static func onScreen(_ claim: ClaimEntry) -> String {
        guard !claim.onScreen.isEmpty else { return "camera only" }
        let names = claim.onScreen.joined(separator: ", ")
        guard claim.bare > 0.05 else { return names }
        return "\(names); camera only for \(Int((claim.bare * 100).rounded()))%"
    }

    /// The list Mike skims before the B-roll is built: each line's time, what
    /// he says, and what will show it with its link. Plain, with nothing
    /// to decode.
    public func markdownText(title: String) -> String {
        var lines = ["# What goes on screen: \(title)", ""]
        let skipped = claims.filter { $0.skip != nil && $0.shot == nil }.count
        var intro = "\(claims.count) line\(claims.count == 1 ? "" : "s") where you name something or make a claim, and what shows each as you say it."
        if skipped > 0 { intro += " \(skipped) \(skipped == 1 ? "needs" : "need") nothing extra." }
        lines.append(intro)
        lines.append("")
        for claim in claims {
            let said = claim.said.count > 200 ? String(claim.said.prefix(200)) + "..." : claim.said
            lines.append("- **\(Self.minutes(claim.start))** \"\(said)\"")
            var plan: String
            if let shot = claim.shot {
                plan = shot
            } else if let skip = claim.skip {
                plan = "Nothing extra: \(skip)"
            } else if claim.link != nil {
                plan = "The page itself"
            } else if !claim.onScreen.isEmpty {
                plan = "On screen now: " + claim.onScreen.joined(separator: ", ")
            } else {
                plan = "Nothing planned yet."
            }
            if let link = claim.link { plan += " " + Self.markdownLink(link) }
            lines.append("  " + plan)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 1:06, or 1:02:03 past an hour.
    static func minutes(_ time: Time) -> String {
        let total = Int(time.seconds.rounded(.down))
        let hours = total / 3600, minutes = (total / 60) % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// A link with the page's address as its text, without the scheme.
    static func markdownLink(_ link: String) -> String {
        guard link.hasPrefix("http://") || link.hasPrefix("https://") else { return "(\(link))" }
        var text = link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return "[\(text)](\(link))"
    }
}

// MARK: - The claims file

/// `<name>.claims.json`: what `tandem claims` writes and the agent fills in.
/// Times are written as mm:ss.mmm for reading; the lines are matched back by
/// their words, so the times can be stale.
struct ClaimsFile: Codable {
    struct Entry: Codable {
        var id: String
        var at: String
        var to: String
        var said: String
        var because: [String]
        var onScreen: String
        var shot: String
        var link: String
        var skip: String

        init(_ claim: ClaimEntry) {
            id = claim.id
            at = claim.start.description
            to = claim.end.description
            said = claim.said
            because = claim.because
            onScreen = ClaimsResult.onScreen(claim)
            shot = claim.shot ?? ""
            link = claim.link ?? ""
            skip = claim.skip ?? ""
        }

        private enum CodingKeys: String, CodingKey { case id, at, to, said, because, onScreen, shot, link, skip }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
            to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
            said = try c.decode(String.self, forKey: .said)
            because = try c.decodeIfPresent([String].self, forKey: .because) ?? []
            onScreen = try c.decodeIfPresent(String.self, forKey: .onScreen) ?? ""
            shot = try c.decodeIfPresent(String.self, forKey: .shot) ?? ""
            link = try c.decodeIfPresent(String.self, forKey: .link) ?? ""
            skip = try c.decodeIfPresent(String.self, forKey: .skip) ?? ""
        }

        var answer: ClaimAnswer {
            ClaimAnswer(id: id.isEmpty ? nil : id, said: said, at: TimeText.parse(at), shot: shot, link: link, skip: skip)
        }
    }

    var about = "Every line Mike says that names something or makes a claim. For each, fill in shot (what will show it as he says it: a file or clip you placed, or a description) and link (the real page: docs, PR, pricing page, post), or skip (why nothing needs showing, like \"he's pointing at the screen recording\"). Leave the rest as it is: tandem claims rewrites it, keeps your answers through later cuts (by the words), and tandem check notes any line that's still bare."
    var revision: Int
    var claims: [Entry]
    /// Answered lines no longer said on the timeline.
    var gone: [Entry]

    init(revision: Int, claims: [ClaimEntry], gone: [ClaimEntry]) {
        self.revision = revision
        self.claims = claims.map(Entry.init)
        self.gone = gone.map(Entry.init)
    }

    private enum CodingKeys: String, CodingKey { case about, revision, claims, gone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        claims = try c.decodeIfPresent([Entry].self, forKey: .claims) ?? []
        gone = try c.decodeIfPresent([Entry].self, forKey: .gone) ?? []
    }

    /// Every answer in the file, the lines no longer said included.
    var answers: [ClaimAnswer] { (claims + gone).map(\.answer).filter(\.isAnswered) }

    /// The file's JSON, written by hand so the fields come in the order
    /// they're read (JSONEncoder's order isn't kept): each claim's line,
    /// then the answers to fill in, one field a line.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func entries(_ list: [Entry]) throws -> String {
            guard !list.isEmpty else { return "[]" }
            let items = try list.map { entry in
                let fields = [
                    "\"id\": \(try json(entry.id))", "\"at\": \(try json(entry.at))", "\"to\": \(try json(entry.to))",
                    "\"said\": \(try json(entry.said))", "\"because\": \(try json(entry.because))", "\"onScreen\": \(try json(entry.onScreen))",
                    "\"shot\": \(try json(entry.shot))", "\"link\": \(try json(entry.link))", "\"skip\": \(try json(entry.skip))"
                ]
                return "    {\n      " + fields.joined(separator: ",\n      ") + "\n    }"
            }
            return "[\n" + items.joined(separator: ",\n") + "\n  ]"
        }
        let text = "{\n  \"about\": \(try json(about)),\n  \"revision\": \(revision),\n  \"claims\": \(try entries(claims)),\n  \"gone\": \(try entries(gone))\n}\n"
        return Data(text.utf8)
    }

    /// The answers in the claims file at `url`: nil when there's no file.
    /// A file that won't read is an error that says where, so an agent's
    /// typo is never written over.
    static func answers(at url: URL) throws -> [ClaimAnswer]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(ClaimsFile.self, from: Data(contentsOf: url)).answers
        } catch let error as DecodingError {
            throw ServiceError(.badRequest, "Couldn't read the claims file \(url.path): \(DecodingErrorText.describe(error)) Fix the JSON (only shot, link and skip are yours to change), then run it again.")
        }
    }
}

extension TandemService {
    /// Lists the claims, matches the answers in the claims file to them and
    /// writes the file back (and the list for Mike when asked).
    func claims(_ request: ClaimsRequest) throws -> ClaimsResult {
        let (project, revision) = coordinator.snapshot()
        let (speech, untranscribed) = Self.checkSpeech(project, analysis: analysis)
        var warnings: [String] = []
        if !untranscribed.isEmpty {
            let names = untranscribed.compactMap { project.media($0).map { URL(fileURLWithPath: $0.path).lastPathComponent } }
            if speech.words.isEmpty {
                throw ServiceError(.unavailable, "No transcript yet for \(names.joined(separator: ", ")), so there's nothing to read the claims from. Run tandem wait transcript first.")
            }
            warnings.append("No transcript yet for \(names.joined(separator: ", ")), so what's said where it plays isn't listed.")
        }
        var markdownURL: URL?
        if let path = request.markdown {
            let url = outputURL(path)
            guard url.pathExtension.lowercased() == "md" else {
                throw ServiceError(.badRequest, "Write the list for Mike as a .md file (\(url.lastPathComponent) isn't one): Tandem would take a picture or a video in the folder for media.")
            }
            try checkOutput(url, what: "list")
            markdownURL = url
        }
        let fileURL = ProjectFile.claimsURL(for: session.fileURL)
        let answers = try ClaimsFile.answers(at: fileURL) ?? []

        let found = QualityCheck.claims(in: project, speech: speech)
        let (byClaim, unmatched) = QualityCheck.match(found, answers: answers)
        var names: [String: String] = [:]
        for id in Set(found.flatMap(\.shownClipIDs)) {
            guard let clip = project.clip(id) else { continue }
            names[id] = Self.checkName(clip, in: project)
        }
        let entries = found.map { claim -> ClaimEntry in
            let answer = byClaim[claim.id]
            return ClaimEntry(
                id: claim.id, start: claim.start, end: claim.end, said: claim.said, because: claim.because,
                // Two clips of one file read as one name.
                onScreen: claim.shownClipIDs.compactMap { names[$0] }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }, bare: claim.bare,
                shot: answer?.shot, link: answer?.link, skip: answer?.skip
            )
        }
        let gone = unmatched.map { answer in
            ClaimEntry(
                id: answer.id ?? "", start: answer.at ?? .zero, end: answer.at ?? .zero, said: answer.said,
                because: [], onScreen: [], bare: 0, shot: answer.shot, link: answer.link, skip: answer.skip
            )
        }
        for entry in entries where entry.skip != nil && entry.shot != nil {
            warnings.append("\(entry.id) has a shot and a skip: it counts as shown only once the shot is on the timeline, so leave skip empty, or the shot if nothing needs showing.")
        }
        for entry in entries {
            if let link = entry.link, !link.hasPrefix("http://"), !link.hasPrefix("https://") {
                warnings.append("\(entry.id)'s link \"\(link)\" isn't a web address: give the real page (https://...), or put a file in shot.")
            }
        }

        var result = ClaimsResult(revision: revision, file: fileURL.path, claims: entries, gone: gone, markdown: nil, warnings: warnings)
        let data = try ClaimsFile(revision: revision, claims: entries, gone: gone).encoded()
        if (try? Data(contentsOf: fileURL)) != data {
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                throw ServiceError(.unavailable, "Couldn't write the claims file \(fileURL.path): \(error.localizedDescription)")
            }
        }
        if let markdownURL {
            do {
                try Data(result.markdownText(title: project.name).utf8).write(to: markdownURL, options: .atomic)
            } catch {
                throw ServiceError(.unavailable, "Couldn't write the list for Mike to \(markdownURL.path): \(error.localizedDescription)")
            }
            result.markdown = markdownURL.path
        }
        return result
    }

    /// The answers in the project's claims file, for `tandem check`: nil
    /// when there's none, with a warning when it won't read.
    static func claimAnswers(for projectURL: URL, warnings: inout [String]) -> [ClaimAnswer]? {
        do {
            return try ClaimsFile.answers(at: ProjectFile.claimsURL(for: projectURL))
        } catch {
            warnings.append(((error as? ServiceError)?.message ?? "\(error)") + " Until then, every bare claim is noted.")
            return nil
        }
    }
}
