import SwiftUI
import TandemCore

/// The card in the viewer's corner while the walkthrough is on a thing an
/// agent asked Mike to look at: its name, the agent's one line, and the
/// keys. It has to read at a glance: the first version showed a paragraph
/// and Mike said he had to read too much to see what it wanted, so the
/// name and note are capped where they're handed back (HandbackNote) and
/// clipped to a line or two here. It's out of the way of the picture,
/// takes no clicks, and goes with the next step, Escape or Mark reviewed;
/// between rounds there's nothing.
struct WalkthroughCard: View {
    let model: EditorModel

    var body: some View {
        if let step = model.walkthrough {
            VStack(alignment: .leading, spacing: 5) {
                Text(step.note.name)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.text.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let more = step.note.note, !more.isEmpty {
                    Text(more)
                        .font(.ui(12))
                        .foregroundStyle(Theme.textSecondary.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.footer(step, keymap: Shortcuts.keymap))
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 340, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.opacity(0.94).color))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.agent.opacity(0.5).color, lineWidth: 1))
            .padding(14)
            .allowsHitTesting(false)
            .accessibilityIdentifier("walkthrough-card")
        }
    }

    /// "Claude · 1 of 3 · ] next · Esc skip", or for a question
    /// "Claude asks · 1 of 3 · ⇧C to answer · ] next · Esc skip". Back and
    /// comment stay on their keys; the footer only lists what this card
    /// wants, so it's one short grey line.
    static func footer(_ step: WalkthroughStep, keymap: Keymap) -> String {
        let who = ActivityLog.displayName(step.note.author)
        var parts = ["\(step.note.question ? "\(who) asks" : who) · \(step.index + 1) of \(step.count)"]
        if step.note.question, let comment = Shortcuts.symbol(for: .addComment, in: keymap) { parts.append("\(comment) to answer") }
        if let next = Shortcuts.symbol(for: .nextAgentChange, in: keymap) { parts.append("\(next) next") }
        parts.append("Esc skip")
        return parts.joined(separator: " · ")
    }
}
