import AppKit
import TandemCore

/// A clip's speed as the timeline's Speed menu and the inspector offer it:
/// presets from half to double speed, and Custom…, which asks for any
/// percentage Tandem can play.
enum ClipSpeed {
    /// The presets: 1 is normal speed.
    static let presets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func isPreset(_ speed: Double) -> Bool {
        presets.contains { abs($0 - speed) < 0.001 }
    }

    /// "110%", "87.5%".
    static func title(_ speed: Double) -> String {
        text(speed) + "%"
    }

    /// The percentage Custom… starts with: "110" for 1.1.
    static func text(_ speed: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: speed * 100)) ?? "\(speed * 100)"
    }

    enum Problem: Error, Equatable {
        case notANumber, outOfRange

        var message: String {
            switch self {
            case .notANumber: return "Type the speed as a percentage, like 110 or 110%."
            case .outOfRange: return "The speed has to be more than 0% and at most \(ClipSpeed.title(Editing.maximumSpeed))."
            }
        }
    }

    /// What was typed into Custom…: "110" or "110%" is 1.1, spaces aside.
    /// Anything Core's setSpeed wouldn't take is a problem that says why.
    static func parse(_ typed: String) -> Result<Double, Problem> {
        var text = typed.filter { !$0.isWhitespace }
        if text.hasSuffix("%") { text.removeLast() }
        // Plain digits, so "1e3", "inf" and "0x10" aren't speeds.
        guard text.range(of: #"^[+-]?(\d+\.?\d*|\.\d+)$"#, options: .regularExpression) != nil,
              let percent = Double(text) else { return .failure(.notANumber) }
        let speed = percent / 100
        guard speed > 0, speed <= Editing.maximumSpeed else { return .failure(.outOfRange) }
        return .success(speed)
    }

    /// Sets the speed as the presets do: linked clips change with it and
    /// later clips move to fit. One undo step.
    static func batch(clipID: String, speed: Double) -> EditBatch {
        EditBatch(label: "Speed \(title(speed))", commands: [.setSpeed(clipID: clipID, speed: speed, ripple: true)])
    }

    /// Asks for Custom…'s percentage, starting from `typed`, and saying
    /// what was wrong with the last try when there's a `problem`. Nil when
    /// Mike cancels. Tests answer it themselves: a modal alert can't be
    /// clicked.
    @MainActor static var ask: @MainActor (_ typed: String, _ problem: String?) -> String? = { typed, problem in
        let alert = NSAlert()
        alert.messageText = "Custom speed"
        alert.informativeText = problem ?? "A percentage of normal speed: 50% is half speed, 200% twice as fast."
        alert.addButton(withTitle: "Set speed")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: typed)
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}

extension EditorModel {
    /// Custom… on a clip's Speed menu, in the timeline and the inspector:
    /// asks for a percentage, starting from the clip's speed, and sets it.
    /// Something that isn't a speed asks again, saying why.
    func customSpeed(clipID: String) {
        guard let clip = project.clip(clipID) else { return }
        var typed = ClipSpeed.text(clip.speed)
        var problem: String?
        while let answer = ClipSpeed.ask(typed, problem) {
            switch ClipSpeed.parse(answer) {
            case .success(let speed):
                apply(ClipSpeed.batch(clipID: clipID, speed: speed))
                return
            case .failure(let why):
                typed = answer
                problem = why.message
            }
        }
    }
}
