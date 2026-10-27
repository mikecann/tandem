import Foundation
import TandemCore
import TandemMedia
import TandemRender

// Plain-text forms of every result, shared by the CLI's default output and
// MCP tool results. They lead with the answer, keep IDs visible (agents need
// them for the next command) and say what to do next when something is
// missing.

extension StatusResult: ReadableResult {
    public var readableText: String {
        var lines = ["\(name) (\((path as NSString).lastPathComponent))"]
        let saved = dirty ? "unsaved changes" : "saved"
        lines.append("  revision \(revision), \(saved), \(duration) long, \(width)x\(height) at \(CommandText.number(frameRate)) fps")
        lines.append("  \(tracks) tracks, \(clips) clips, \(media) media files, \(markers) markers")
        if headless {
            lines.append("  open in: nothing else, read from the file for this command")
        } else if let openIn {
            let serving = openIn.port.map { ", serving the API on port \($0)" } ?? ""
            lines.append("  open in: \(openIn.owner == "app" ? "the Tandem app" : "tandem \(openIn.owner)") (pid \(openIn.pid))\(serving)")
        }
        if let undo { lines.append("  undo: \(undo)") }
        if let redo { lines.append("  redo: \(redo)") }
        if recoveredEdits { lines.append("  recovered unsaved edits from the journal after a crash") }
        if let pending = reviewPending, !pending.isEmpty {
            // The latest few; the JSON has them all.
            var names = pending.suffix(3).map { "\($0.label) by \($0.author)" }
            if pending.count > names.count { names.append("\(pending.count - names.count) more") }
            let count = pending.count == 1 ? "1 agent edit" : "\(pending.count) agent edits"
            lines.append("  waiting for Mike's review: \(count) (\(names.joined(separator: "; ")))")
        }
        if let handback, !handback.isEmpty {
            var names = handback.prefix(3).map { "\($0.start) \(CommentEdits.oneLine($0.name))" }
            if handback.count > names.count { names.append("\(handback.count - names.count) more") }
            lines.append("  things to look at, handed back and not yet watched: \(handback.count) (\(names.joined(separator: "; ")))")
        }
        let active = jobs.filter { $0.state == .queued || $0.state == .running }
        if active.isEmpty {
            lines.append("  background jobs: none")
        } else {
            lines.append("  background jobs:")
            for job in active {
                let progress = job.state == .running ? " \(Int(job.progress * 100))%" : ""
                lines.append("    \(job.kind.rawValue) \(job.mediaID) \(job.state.rawValue)\(progress)")
            }
        }
        for export in exports {
            lines.append("  exporting \((export.output as NSString).lastPathComponent) \(Int(export.progress * 100))%")
        }
        for warning in warnings ?? [] { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

extension MediaResult: ReadableResult {
    public var readableText: String {
        guard !items.isEmpty else {
            return "No media in the project yet. Put files in the project folder and run `tandem media --refresh`."
        }
        var lines: [String] = []
        if !added.isEmpty { lines.append("Added \(added.count) new file\(added.count == 1 ? "" : "s").") }
        let idWidth = items.map(\.id.count).max() ?? 0
        for item in items {
            var parts = [item.id.padding(toLength: idWidth, withPad: " ", startingAt: 0), item.path, item.role.rawValue]
            if let duration = item.duration { parts.append(duration.description) }
            if let w = item.width, let h = item.height { parts.append("\(w)x\(h)") }
            if let codec = item.undecodableCodec { parts.append(MediaItem.codecName(codec)) }
            if let clip = item.livePhotoVideo { parts.append("Live Photo, motion clip \((clip as NSString).lastPathComponent)") }
            if let take = item.takeID { parts.append("take \(take) +\(TimeText.duration(item.takeOffset ?? .zero))") }
            if let delay = item.pictureDelay, delay != .zero { parts.append("picture \(SyncResult.milliseconds(delay)) late, shown in sync") }
            if let corrected = item.pictureDelayCorrected { parts.append("in sync as recorded (Record It took out \(SyncResult.milliseconds(corrected)))") }
            parts.append(item.clips == 1 ? "1 clip" : "\(item.clips) clips")
            if !item.exists { parts.append("MISSING FILE") }
            parts.append(Self.analysisSummary(item.analysis))
            lines.append(parts.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }
}

extension MediaResult {
    /// "transcript ready, proxy 45%, matte queued", leaving out analyses
    /// nobody has asked for yet. A failure says why.
    static func analysisSummary(_ analysis: [String: AnalysisState]) -> String {
        let order = ["converted", "transcript", "loudness", "waveform", "thumbnails", "proxy", "matte", "isolatedVoice"]
        let keys = analysis.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        let started = keys.compactMap { key -> String? in
            guard let state = analysis[key], state.state != "none" else { return nil }
            if let progress = state.progress { return "\(key) \(Int(progress * 100))%" }
            if let message = state.message { return "\(key) \(state.state): \(message)" }
            return "\(key) \(state.state)"
        }
        if analysis.isEmpty { return "(no analysis applies)" }
        return started.isEmpty ? "(not analysed yet)" : "(" + started.joined(separator: ", ") + ")"
    }
}

extension TimelineResult: ReadableResult {
    public var readableText: String {
        if let text { return text.hasSuffix("\n") ? String(text.dropLast()) : text }
        if let project, let data = try? ProjectFile.encoder().encode(project), let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "Revision \(revision)"
    }
}

extension TranscriptResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        switch scope {
        case "media": lines.append("Transcript of \(id ?? "") (times are in the file)")
        case "clip": lines.append("Transcript of clip \(id ?? "") (timeline times)")
        default: lines.append("What's said on the timeline")
        }
        if words.isEmpty {
            lines.append(missing.isEmpty ? "(no words)" : "(no words yet)")
        } else {
            lines += Self.lines(words)
        }
        if !missing.isEmpty {
            lines.append("No transcript yet for: \(missing.joined(separator: ", ")). `tandem media` shows progress.")
        }
        return lines.joined(separator: "\n")
    }

    /// Words grouped into lines that break at pauses and run to about 12
    /// words, each starting with its time, with long gaps marked.
    static func lines(_ words: [WordTiming]) -> [String] {
        var lines: [String] = []
        var current: [String] = []
        var lineStart: Time?
        var previousEnd: Time?
        for word in words {
            let gap = previousEnd.map { word.start - $0 } ?? .zero
            if !current.isEmpty && (current.count >= 12 || gap >= Time(seconds: 0.5)) {
                lines.append("\(lineStart!)  \(current.joined(separator: " "))")
                current = []
            }
            if current.isEmpty {
                lineStart = word.start
                if gap >= Time(seconds: 0.5), previousEnd != nil {
                    lines.append("           [pause \(TimeText.duration(gap))]")
                }
            }
            current.append(word.text)
            previousEnd = word.end
        }
        if !current.isEmpty, let lineStart { lines.append("\(lineStart)  \(current.joined(separator: " "))") }
        return lines
    }
}

extension SearchResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if hits.isEmpty {
            lines.append("\"\(phrase)\" isn't said on the timeline.")
        } else {
            lines.append("\"\(phrase)\" on the timeline, \(hits.count) time\(hits.count == 1 ? "" : "s"):")
            for hit in hits {
                let partial = hit.partial ? "  (cut runs through it)" : ""
                lines.append("  \(hit.start)-\(hit.end)  ...\(hit.before) [\(hit.text)] \(hit.after)...  clips \(hit.clipIDs.joined(separator: ","))\(partial)")
            }
        }
        if !unused.isEmpty {
            lines.append("In the source but not on the timeline:")
            for hit in unused {
                lines.append("  \(hit.mediaID) at \(hit.mediaStart)-\(hit.mediaEnd) (file time)  ...\(hit.before) [\(hit.text)] \(hit.after)...")
            }
        }
        if !missing.isEmpty {
            lines.append("Not searched, no transcript yet: \(missing.joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}

extension PausesResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if pauses.isEmpty {
            lines.append("No pauses of \(TimeText.duration(minimum)) or more.")
        } else {
            lines.append("\(pauses.count) pause\(pauses.count == 1 ? "" : "s") of \(TimeText.duration(minimum)) or more, \(TimeText.duration(total)) in all:")
            for pause in pauses {
                lines.append("  \(pause.start)-\(pause.end)  \(TimeText.duration(pause.duration))  ...\(pause.before) | \(pause.after)...\(pause.sound.map(\.readableText) ?? "")")
            }
        }
        if !missing.isEmpty {
            lines.append("No transcript yet for \(missing.joined(separator: ", ")), so pauses there aren't listed.")
        }
        for warning in warnings ?? [] { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

extension PauseSound {
    /// What the sound under a pause has, after its line in `pauses`.
    var readableText: String {
        if runsThrough {
            return "  no real pause: the voice runs through it" + (heard.first.map { " (\($0.start)-\($0.end))" } ?? "")
        }
        var parts = ["heard as \(TimeText.duration(duration))"]
        if !heard.isEmpty { parts.append(heardText) }
        return "  " + parts.joined(separator: ", ")
    }

    /// Where the sound no word accounts for is, like "sound at
    /// 01:02.300-01:02.650 on Voice".
    var heardText: String {
        "sound at " + heard.map { "\($0.start)-\($0.end) on \($0.tracks.joined(separator: " and "))" }.joined(separator: ", ")
    }
}

extension TightenResult {
    /// The keeps by kind, like "0.400s after a sentence, 0.080s mid-sentence".
    var keepsText: String {
        var parts: [String] = []
        if let sentence { parts.append("\(TimeText.duration(sentence)) after a sentence") }
        if let comma { parts.append("\(TimeText.duration(comma)) after a comma") }
        if let mid { parts.append("\(TimeText.duration(mid)) mid-sentence") }
        return parts.joined(separator: ", ")
    }
}

extension TightenResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        let mode = applied == nil ? "dry run" : "applied"
        let bySentence = sentence != nil || comma != nil || mid != nil
        if cuts.isEmpty && widened.isEmpty {
            if bySentence {
                lines.append("Nothing to tighten: keeping \(keepsText), no pause would lose a frame.")
            } else {
                lines.append("Nothing to tighten: no pauses of \(TimeText.duration(minimum)) or more that would lose a frame.")
            }
        } else {
            if bySentence {
                let midMinimum = midMinimum.map { ", comma and mid-sentence ones of \(TimeText.duration($0)) or more" } ?? ""
                lines.append("Keep \(keepsText) (sentence pauses of \(TimeText.duration(minimum)) or more\(midMinimum); \(mode), revision \(revision)):")
            } else {
                lines.append("Shorten \(pausesCut) pause\(pausesCut == 1 ? "" : "s") of \(TimeText.duration(minimum)) or more to \(TimeText.duration(keep)) (\(mode), revision \(revision)):")
            }
            // One line a pause: one with sound in it can be cut either side.
            var index = 0
            while index < cuts.count {
                let cut = cuts[index]
                var ranges = ["\(cut.cut.start)-\(cut.cut.end)"]
                while index + 1 < cuts.count, cuts[index + 1].pause.start == cut.pause.start {
                    index += 1
                    ranges.append("\(cuts[index].cut.start)-\(cuts[index].cut.end)")
                }
                index += 1
                let kind = bySentence ? (cut.kind.map { " \($0.rawValue)" } ?? "") : ""
                // Sound left in beside the cut is worth a listen.
                let beside = cut.pause.sound.flatMap { $0.heard.isEmpty ? nil : ", beside \($0.heardText)" } ?? ""
                lines.append("  \(cut.pause.start)-\(cut.pause.end)  \(TimeText.duration(cut.pause.duration))\(kind) -> cut \(ranges.joined(separator: ", "))  ...\(cut.pause.before) | \(cut.pause.after)...\(beside)")
            }
            if !widened.isEmpty {
                lines.append("Widen \(widened.count) join\(widened.count == 1 ? "" : "s") to their keep, from silence in the take:")
                for widen in widened {
                    lines.append("  \(widen.pause.start)-\(widen.pause.end)  \(TimeText.duration(widen.pause.duration)) \(widen.kind.rawValue) -> +\(TimeText.duration(widen.added)) at the join at \(widen.at) (\(TimeText.duration(widen.tail)) after, \(TimeText.duration(widen.head)) before)  ...\(widen.pause.before) | \(widen.pause.after)...")
                }
            }
            var change = "Removes \(TimeText.duration(removed))"
            if added > .zero { change += ", adds \(TimeText.duration(added))" }
            lines.append("\(change): \(durationBefore) -> \(durationAfter).")
        }
        if !protected.isEmpty {
            lines.append("Left \(protected.count) protected pause\(protected.count == 1 ? "" : "s") alone: \(protected.map { "\($0.start)-\($0.end)" }.joined(separator: ", ")).")
        }
        lines += skippedText
        for warning in warnings { lines.append("Warning: \(warning)") }
        if let applied {
            lines.append("Applied as revision \(applied.revision) (\"\(applied.label)\"). Undo with `tandem undo`.")
        } else if !cuts.isEmpty || !widened.isEmpty {
            lines.append("Nothing changed yet. Run again with --apply (or apply: true) to make the cut.")
        }
        return lines.joined(separator: "\n")
    }
}

extension TightenResult {
    /// The pauses left alone for what's in their sound, by why.
    var skippedText: [String] {
        func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var lines: [String] = []
        let heard = skipped.filter { $0.reason == .sound || $0.reason == .speech }
        if !heard.isEmpty {
            lines.append("Left \(plural(heard.count, "pause")) with sound in \(heard.count == 1 ? "it" : "them") alone (listen with tandem clip):")
            for skip in heard {
                let why = skip.reason == .speech
                    ? "no real pause, the voice runs through it"
                    : (skip.pause.sound.map { "\($0.heardText), no quiet long enough beside it" } ?? "sound in it")
                lines.append("  \(skip.pause.start)-\(skip.pause.end)  \(TimeText.duration(skip.pause.duration))  ...\(skip.pause.before) | \(skip.pause.after)...  \(why)")
            }
        }
        let short = skipped.filter { $0.reason == .short }
        if !short.isEmpty {
            lines.append("Left \(plural(short.count, "pause")) alone that \(short.count == 1 ? "is" : "are") under the minimum measured from the sound: \(short.map { "\($0.pause.start)-\($0.pause.end)" + ($0.pause.sound.map { " (\(TimeText.duration($0.duration)))" } ?? "") }.joined(separator: ", ")).")
        }
        let notClean = skipped.filter { $0.reason == .notClean }
        if !notClean.isEmpty {
            lines.append("Left \(plural(notClean.count, "pause")) alone whose join check --cuts wouldn't call clean:")
            for skip in notClean {
                let sides = [("start", skip.startEdge), ("end", skip.endEdge)].compactMap { name, edge in
                    edge.map { "\(name) \($0.verdict.rawValue) (\(String(format: "%.1f", $0.margin)) dB under the speech)" }
                }
                lines.append("  \(skip.pause.start)-\(skip.pause.end)  \(sides.joined(separator: ", "))")
            }
        }
        return lines
    }
}

extension ApplyResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = []
        if dryRun {
            lines.append("Dry run of \"\(label)\" at revision \(revision): it would work.")
        } else if repeated {
            lines.append("Already applied \"\(label)\" (same idempotency key) as revision \(revision). Nothing changed.")
        } else {
            lines.append("Applied \"\(label)\" by \(author) as revision \(revision).")
        }
        if !createdIDs.isEmpty {
            // Big batches create hundreds of IDs; the JSON result has them all.
            let shown = createdIDs.prefix(12).joined(separator: ", ")
            let more = createdIDs.count > 12 ? ", and \(createdIDs.count - 12) more (--json lists them all)" : ""
            lines.append("Created: \(shown)\(more)")
        }
        var changes: [String] = []
        if !added.isEmpty { changes.append("\(added.count) clip\(added.count == 1 ? "" : "s") added") }
        if !removed.isEmpty { changes.append("\(removed.count) removed (\(removed.joined(separator: ", ")))") }
        if !changed.isEmpty { changes.append("\(changed.count) changed") }
        if !changes.isEmpty { lines.append(changes.joined(separator: ", ") + ". Timeline is \(duration) long.") }
        for warning in warnings { lines.append("Warning: \(warning)") }
        return lines.joined(separator: "\n")
    }
}

extension UndoResult: ReadableResult {
    public var readableText: String {
        let verb = action == "undo" ? "Undid" : "Redid"
        if let labels, let authors, labels.count > 1, labels.count == authors.count {
            let steps = zip(labels, authors).map { "\"\($0)\" (by \($1))" }.joined(separator: ", ")
            return "\(verb) \(labels.count) edits: \(steps). Now at revision \(revision)."
        }
        return "\(verb) \"\(label)\" (by \(author)). Now at revision \(revision)."
    }
}

extension HistoryResult: ReadableResult {
    public var readableText: String {
        var lines = ["Revision \(revision)."]
        if undo.isEmpty {
            lines.append("Nothing to undo.")
        } else {
            lines.append("Undo, newest first:")
            for entry in undo { lines.append("  \(entry.label)  (\(entry.author))\(Self.place(entry.start, entry.end, entry.tracks))") }
        }
        if let redo { lines.append("Redo: \(redo)") }
        if let edits, !edits.isEmpty {
            lines.append("Edits, newest first (kept across restarts; tandem diff --since <revision> shows what each did to the clips):")
            lines += Self.editLines(edits)
        } else if !events.isEmpty {
            lines.append("Recent changes:")
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            for event in events {
                lines.append("  \(formatter.string(from: event.date))  r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func place(_ start: Time?, _ end: Time?, _ tracks: [String]?) -> String {
        guard let start, let end else { return "" }
        return "  " + EditPlace(start: start, end: end, tracks: tracks ?? []).description
    }

    /// One line per edit, with a run of Tandem finding new media (which
    /// can be dozens) on one line.
    static func editLines(_ edits: [HistoryEdit]) -> [String] {
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        func when(_ date: Date) -> String {
            Calendar.current.isDateInToday(date) ? time.string(from: date) : day.string(from: date)
        }
        var lines: [String] = []
        var index = 0
        while index < edits.count {
            let edit = edits[index]
            if edit.kind == .opened {
                let before = edit.revision > 0 ? " (edits before it weren't recorded, or were made somewhere that kept no history)" : ""
                lines.append("  r\(edit.revision)  \(when(edit.date))  the history starts here\(before)")
                index += 1
                continue
            }
            var run = index + 1
            while run < edits.count, edits[run].label == edit.label, edits[run].author == edit.author, edits[run].kind == edit.kind,
                  edit.label == EditBatch.mediaScanLabel {
                run += 1
            }
            if run - index > 1 {
                let oldest = edits[run - 1]
                lines.append("  r\(oldest.revision)-r\(edit.revision)  \(when(oldest.date))-\(when(edit.date))  \(edit.label) x\(run - index)  (\(edit.author))")
                index = run
                continue
            }
            var line = "  r\(edit.revision)  \(when(edit.date))  "
            switch edit.kind {
            case .undo: line += "Undo \(edit.label)"
            case .redo: line += "Redo \(edit.label)"
            default: line += edit.label
            }
            line += "  (\(edit.author))" + place(edit.start, edit.end, edit.tracks)
            if let summary = edit.summary { line += "  " + summary }
            lines.append(line)
            index += 1
        }
        return lines
    }
}

extension ValidateResult: ReadableResult {
    public var readableText: String {
        if issues.isEmpty { return "Revision \(revision) is valid. No problems found." }
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.count - errors
        var lines = ["Revision \(revision): \(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")."]
        for issue in issues {
            lines.append("  \(issue.severity.rawValue): \(issue.message)")
        }
        return lines.joined(separator: "\n")
    }
}

extension ImageResult: ReadableResult {
    public var readableText: String {
        var at = time.map { " at \($0)" } ?? ""
        if let times {
            at = ": \(times.count) frame\(times.count == 1 ? "" : "s"), at " + times.map(\.description).joined(separator: ", ")
        }
        let head = path.map { "Wrote \($0) (\(bytes) bytes)\(at)." } ?? "PNG\(at), \(bytes) bytes (base64 in the JSON result)."
        return ([head] + warnings.map { "Warning: \($0)" }).joined(separator: "\n")
    }
}

extension ExportOutcome: ReadableResult {
    public var readableText: String {
        var used = preset
        if soundOnly {
            used += ", sound only"
        } else if let width, let height, let codec, let videoBitrate {
            used += ": \(width)x\(height) \(codec.displayName) at \(ExportPlan.megabits(videoBitrate))"
            if let format { used += ", \(format) format" }
        }
        var text = "Wrote \(path) (\(used), \(duration) long) in \(String(format: "%.1f", elapsed))s."
        if let lufs = integratedLUFS, let peak = truePeakDBTP {
            text += String(format: " Loudness %.1f LUFS, true peak %.1f dBTP", lufs, peak)
            if let target = loudnessTarget {
                // The project's target, so a -16 master doesn't read as a miss.
                text += " (mastered to \(ExportPlan.decibels(target)) LUFS"
                if let ceiling = truePeakCeiling { text += ", peaks under \(ExportPlan.decibels(ceiling)) dBTP" }
                text += ")"
            }
            text += "."
        }
        if let tracks {
            text += " Only \(SoundText.list(tracks)) \(tracks.count == 1 ? "plays" : "play"), at the timeline's own level (not mastered)."
        }
        return ([text] + warnings.map { "Warning: \($0)" }).joined(separator: "\n")
    }
}

extension LoudnessResult: ReadableResult {
    public var readableText: String {
        if let curve {
            var lines = SoundText.curve(curve, tracks: tracks, peaks: peaks)
            if let gains { lines += SoundText.gains(gains, start: curve.start, end: curve.end) }
            return lines.joined(separator: "\n")
        }
        var lines = [String(
            format: "Speech is levelled to %.1f LUFS; export brings the mix to %.1f LUFS with true peaks under %.1f dBTP.",
            speechLoudness, target, truePeakCeiling
        )]
        if media.isEmpty {
            lines.append("No media with sound.")
        }
        for item in media {
            if let lufs = item.integratedLUFS, let peak = item.truePeakDBTP {
                lines.append(String(format: "  %@  %@  %.1f LUFS, peak %.1f dBTP, range %.1f LU", item.mediaID, item.path, lufs, peak, item.loudnessRange ?? 0))
            } else {
                let state = item.state == "none" ? "" : " (\(item.state))"
                lines.append("  \(item.mediaID)  \(item.path)  not measured yet\(state)")
            }
        }
        // A take has hundreds of pieces, so clips are summed up per track:
        // how many, the spread of their gains and the most common one. The
        // JSON lists every clip.
        struct Group {
            var track: String
            var normalizeTo: Double?
            var gains: [Double] = []
            var normalizeGains: [Double] = []
        }
        var groups: [Group] = []
        for clip in clips where clip.normalizeTo != nil || clip.gainDB != 0 {
            if let index = groups.firstIndex(where: { $0.track == clip.track && $0.normalizeTo == clip.normalizeTo }) {
                groups[index].gains.append(clip.gainDB)
                if let gain = clip.normalizeGainDB { groups[index].normalizeGains.append(gain) }
            } else {
                var group = Group(track: clip.track, normalizeTo: clip.normalizeTo)
                group.gains.append(clip.gainDB)
                if let gain = clip.normalizeGainDB { group.normalizeGains.append(gain) }
                groups.append(group)
            }
        }
        let speech = clips.filter(\.speech)
        let unlevelled = speech.filter { $0.normalizeTo != speechLoudness || $0.gainDB != 0 }.count
        if !speech.isEmpty && unlevelled > 0 {
            lines.append("\(unlevelled) of \(speech.count) speech clips aren't at the speech level; normalizeSpeech sets them.")
        }
        lines += peakLines(speech: speech)
        if !groups.isEmpty {
            lines.append("Clip levels by track (clip gain is added after levelling):")
            let width = groups.map(\.track.count).max() ?? 0
            for group in groups {
                let count = group.gains.count
                var parts = ["  " + group.track.padding(toLength: width, withPad: " ", startingAt: 0), count == 1 ? "1 clip" : "\(count) clips"]
                if let target = group.normalizeTo {
                    if group.normalizeGains.isEmpty {
                        parts.append(String(format: "levelled to %.1f LUFS once measured", target))
                    } else {
                        parts.append(String(format: "levelled to %.1f LUFS (%@)", target, Self.spread(group.normalizeGains)))
                    }
                }
                if group.gains.contains(where: { $0 != 0 }) { parts.append("gain " + Self.spread(group.gains)) }
                lines.append(parts.joined(separator: "  "))
            }
        }
        return lines.joined(separator: "\n")
    }
}

extension LoudnessResult {
    /// Where levelling lifts speech over the true peak ceiling: the clips
    /// a limiter holds, by track, and the ones nothing holds yet.
    func peakLines(speech: [ClipLevel]) -> [String] {
        func level(_ value: Double) -> String { String(format: "%+.1f", value) }
        var lines: [String] = []
        var tracks: [String] = []
        for clip in clips where clip.limiterCeiling != nil && !tracks.contains(clip.track) { tracks.append(clip.track) }
        for track in tracks {
            let held = clips.filter { $0.track == track && $0.limiterCeiling != nil }
            let ceiling = held.compactMap(\.limiterCeiling).max()!
            let under = String(format: "%.1f dBFS", ceiling)
            let peaks = held.compactMap(\.peakDBTP)
            if held.count == 1 {
                let would = peaks.first.map { ", which would peak at \(level($0)) dBTP," } ?? ""
                lines.append("A limiter holds the 1 clip on \(track)\(would) under \(under).")
            } else {
                let would = peaks.max().map { " (they'd peak at up to \(level($0)) dBTP)" } ?? ""
                lines.append("Limiters hold \(held.count) clips on \(track)\(would) under \(under).")
            }
        }
        let over = speech.filter { !$0.muted && $0.limiterCeiling == nil && ($0.peakDBTP ?? -.infinity) > truePeakCeiling }
        if let loudest = over.compactMap(\.peakDBTP).max() {
            let clips = over.count == 1 ? "1 speech clip peaks" : "\(over.count) speech clips peak"
            lines.append("\(clips) over the \(String(format: "%.1f", truePeakCeiling)) dBTP ceiling once levelled (up to \(level(loudest)) dBTP), which export's limiter squashes; normalizeSpeech holds them with a compressor and a limiter.")
        }
        return lines
    }

    /// "+3.9 dB", or "+0.4 to +5.8 dB (99 at +0.4 dB)" for a spread.
    static func spread(_ values: [Double]) -> String {
        let rounded = values.map { ($0 * 10).rounded() / 10 }
        guard let low = rounded.min(), let high = rounded.max() else { return "" }
        if low == high { return String(format: "%+.1f dB", low) }
        var text = String(format: "%+.1f to %+.1f dB", low, high)
        var counts: [Double: Int] = [:]
        for value in rounded { counts[value, default: 0] += 1 }
        if let (common, count) = counts.max(by: { $0.value < $1.value }), count * 2 >= rounded.count {
            text += String(format: " (%d at %+.1f dB)", count, common)
        }
        return text
    }
}

extension WatchResult: ReadableResult {
    public var readableText: String {
        guard changed else { return "No change. Still at revision \(revision)." }
        var lines = ["Changed. Now at revision \(revision)."]
        for event in events {
            lines.append("  r\(event.revision ?? 0)  \(event.kind.rawValue)  \(event.label ?? "")  (\(event.author ?? "?"))")
        }
        if events.isEmpty { lines.append("  (made by another process; read the timeline to see what changed)") }
        return lines.joined(separator: "\n")
    }
}

extension EffectsResult: ReadableResult {
    public var readableText: String {
        var lines: [String] = ["Effects (addEffect {\"type\": ..., \"params\": {...}}):"]
        for effect in effects {
            lines.append("  \(effect.type)  \(effect.domain.rawValue)  \(effect.summary)")
            for param in effect.params {
                var range = ""
                if let min = param.min, let max = param.max { range = " \(CommandText.number(min))...\(CommandText.number(max))" }
                let unit = param.unit.map { " \($0)" } ?? ""
                lines.append("    \(param.key): \(param.kind.rawValue)\(range)\(unit), default \(Self.text(param.defaultValue))")
            }
        }
        lines.append("Transitions: " + transitions.map { "\($0.type.rawValue) (\(TimeText.duration($0.defaultDuration)))" }.joined(separator: ", "))
        lines.append("Layouts (applyLayout): " + layouts.map { "\($0.preset.rawValue) (\($0.name))" }.joined(separator: ", "))
        lines.append("Animatable parameters (setKeyframes): " + animatable.joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    static func text(_ value: ParamValue) -> String {
        switch value {
        case .number(let n): return CommandText.number(n)
        case .bool(let b): return b ? "true" : "false"
        case .string(let s): return "\"\(s)\""
        case .point(let p): return "(\(p.x), \(p.y))"
        case .color(let c): return TimelineDump.hex(c)
        }
    }
}
