import SwiftUI
import TandemCore

/// The card in the viewer's corner while the walkthrough is on a thing an
/// agent asked Mike to look at: its line, the agent's note, and the keys.
/// It's out of the way of the picture, takes no clicks, and goes with the
/// next step, Escape or Mark reviewed; between rounds there's nothing.
struct WalkthroughCard: View {
    let model: EditorModel

    var body: some View {
        if let step = model.walkthrough {
            VStack(alignment: .leading, spacing: 5) {
                Text(step.note.name)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(Theme.text.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let more = step.note.note, !more.isEmpty {
                    Text(more)
                        .font(.ui(12))
                        .foregroundStyle(Theme.textSecondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.footer(step, keymap: Shortcuts.keymap))
                    .font(.ui(10.5))
                    .foregroundStyle(Theme.textFaint.color)
                    .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 380, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel.opacity(0.94).color))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.agent.opacity(0.5).color, lineWidth: 1))
            .padding(14)
            .allowsHitTesting(false)
            .accessibilityIdentifier("walkthrough-card")
        }
    }

    /// "Claude · 1 of 3 · wants your answer · ] next · [ back · Esc skip · ⇧C comment".
    static func footer(_ step: WalkthroughStep, keymap: Keymap) -> String {
        var parts = ["\(ActivityLog.displayName(step.note.author)) · \(step.index + 1) of \(step.count)"]
        if step.note.question { parts.append("wants your answer") }
        if let next = Shortcuts.symbol(for: .nextAgentChange, in: keymap) { parts.append("\(next) next") }
        if let back = Shortcuts.symbol(for: .previousAgentChange, in: keymap) { parts.append("\(back) back") }
        parts.append("Esc skip")
        if let comment = Shortcuts.symbol(for: .addComment, in: keymap) { parts.append("\(comment) comment") }
        return parts.joined(separator: " · ")
    }
}
