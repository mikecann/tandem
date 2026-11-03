import Foundation
import TandemAPI
import TandemCore
import TandemMedia

/// Finds the long pauses in the take and cuts them out with ripple deletes,
/// so the camera, screen and voice stay in sync and B-roll and music follow.
///
/// It plans exactly as `tandem tighten --min <minimum> --keep <keep>` does
/// (`SoundTightening`), so a tighten from the app and one from an agent
/// agree: each cut in a real pause in the sound, never through sound the
/// transcript doesn't know about, with a clean join.
enum PauseTightening {
    /// The plan for pauses between words of `minimum` or more (found the
    /// way `tandem pauses` finds them, from words trimmed to the voice and
    /// placed through the cuts), leaving `keep` of pause between the words'
    /// sound, only pauses wholly inside `within` if given. Locked tracks
    /// aren't tightened, so their words don't count.
    static func plan(
        in project: Project,
        transcript: (MediaItem) -> Transcript?,
        folder: ProjectFolder,
        minimum: Time,
        keep: Time,
        within: TimeRange? = nil
    ) async -> SoundTightening.Plan {
        var unlocked = project
        for index in unlocked.audioTracks.indices where unlocked.audioTracks[index].locked {
            unlocked.audioTracks[index].clips = []
        }
        let cleaned = await SoundTightening.withoutPhantoms(
            TranscriptTools.speechMap(unlocked, transcripts: transcript), from: within?.start, to: within?.end, project: project, folder: folder
        )
        let map = cleaned.map
        let rules = TranscriptTools.PauseRules.uniform(keep: keep, minimum: minimum)
        let pauses = SoundTightening.candidates(in: map, rules: rules, from: within?.start, to: within?.end)
        var plan = await SoundTightening.plan(
            pauses, rules: rules, snug: false, from: within?.start, to: within?.end, map: map, project: project, folder: folder
        )
        // The popover lists the words left out, as tandem tighten does: one
        // could be a real word said very quietly.
        plan.warnings = SoundTightening.phantomWarning(cleaned.phantoms) + plan.warnings
        return plan
    }

    /// What a plan is made from. The popover keeps the plan for these, so a
    /// change to any of them (an edit, a slider, the in and out markers
    /// moving with "Only between in and out" on) makes a new one.
    struct Settings: Hashable {
        var revision: Int
        var minimum: Time
        var keep: Time
        var within: TimeRange?
    }

    /// One batch cutting every planned pause, latest first so earlier cuts
    /// don't move under later ones. It's only applied to the project at
    /// `revision`, the one it was planned on: an agent's edit landing while
    /// the popover shows the plan would move the pauses under it.
    static func batch(_ cuts: [PlannedCut], madeAt revision: Int) -> EditBatch? {
        guard !cuts.isEmpty else { return nil }
        let total = cuts.reduce(0) { $0 + $1.cut.duration.seconds }
        let pauses = Set(cuts.map(\.pause.start)).count
        return EditBatch(
            label: String(format: "Tighten %d %@ (%.1f s)", pauses, pauses == 1 ? "pause" : "pauses", total),
            commands: TranscriptTools.commands(for: cuts),
            expectedRevision: revision
        )
    }

    /// What the popover says under the plan: pauses left alone for sound in
    /// them, and the plan's warnings, such as a file that couldn't be heard
    /// so its pauses were cut from the transcript alone.
    static func notes(for plan: SoundTightening.Plan) -> [String] {
        var notes: [String] = []
        let heard = plan.skipped.filter { $0.reason == .sound || $0.reason == .speech }.count
        if heard > 0 {
            notes.append(String(format: "Leaves %d %@ with sound in %@: a breath, another voice or an app.", heard, heard == 1 ? "pause" : "pauses", heard == 1 ? "it" : "them"))
        }
        return notes + plan.warnings
    }
}
