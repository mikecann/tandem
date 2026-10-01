import AppKit
import Observation
import SwiftUI

/// Holding ⌘ shows each button's key on the button, so the keys can be
/// learned at a glance instead of by hovering one tooltip at a time.
///
/// The keys show the moment ⌘ goes down on its own (Mike wanted them
/// straight away, not after a hold), and go the moment it's let go or used:
/// a shortcut, a ⌘-click or a ⌘-scroll to zoom hides them, and they don't
/// come back until ⌘ is pressed again.
@MainActor
@Observable
final class ShortcutHints {
    static let shared = ShortcutHints()

    /// True while the keys are on the buttons.
    private(set) var showing = false

    /// Overridable for tests: the app is frontmost, a mouse button is down.
    @ObservationIgnored var isAppActive: () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored var isMouseDown: () -> Bool = { NSEvent.pressedMouseButtons != 0 }

    /// ⌘ was used for something since it went down.
    @ObservationIgnored private var spent = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// Watches the app's events. Called once at launch.
    func install() {
        guard monitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { event in
            MainActor.assumeIsolated { ShortcutHints.shared.handle(event) }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShortcutHints.shared.reset() }
        }
    }

    func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.type {
        case .flagsChanged:
            if !flags.contains(.command) {
                reset()
            } else if flags == .command {
                if !spent && !showing && isAppActive() && !isMouseDown() { showing = true }
            } else {
                // ⌘ with Shift or Option: a chord on its way.
                spent = true
                hide()
            }
        default:
            // A key, a click or a scroll: whatever ⌘ is down for, it isn't
            // for looking at the keys.
            if flags.contains(.command) { spent = true }
            hide()
        }
    }

    /// For smoke tests (`tandem://simulate?press=cmd`): `flags` held on
    /// their own for `seconds`, with the app taken as frontmost, then let go.
    func simulatePress(_ flags: NSEvent.ModifierFlags, for seconds: TimeInterval) {
        let wasActive = isAppActive
        isAppActive = { true }
        handle(Self.flagsChanged(flags))
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            MainActor.assumeIsolated {
                let hints = ShortcutHints.shared
                hints.handle(Self.flagsChanged([]))
                hints.isAppActive = wasActive
            }
        }
    }

    static func flagsChanged(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        )!
    }

    /// Back to nothing held.
    func reset() {
        spent = false
        hide()
    }

    private func hide() {
        if showing { showing = false }
    }
}

extension View {
    /// Shows the command's key just under the view (or over it, for
    /// buttons with something below) while ⌘ is held (`ShortcutHints`).
    /// Nothing shows for a command with no key, or for nil.
    func shortcutHint(_ command: EditorCommand?, edge: VerticalEdge = .bottom) -> some View {
        modifier(ShortcutHintMark(command: command, edge: edge))
    }
}

/// The keys one editor window's buttons show while ⌘ is held, and where:
/// each button's frame in the window, top-left points. Buttons report
/// their frames only while the keys show.
@MainActor
@Observable
final class HintBoard {
    struct Badge: Equatable {
        var symbol: String
        var frame: CGRect
        var edge: VerticalEdge
    }

    private(set) var badges: [String: Badge] = [:]

    func set(_ id: String, _ badge: Badge?) {
        if badges[id] != badge { badges[id] = badge }
    }
}

private struct ShortcutHintMark: ViewModifier {
    let command: EditorCommand?
    let edge: VerticalEdge
    @Environment(HintBoard.self) private var board: HintBoard?
    @State private var id = UUID().uuidString

    func body(content: Content) -> some View {
        content.background {
            if ShortcutHints.shared.showing, let board, let command, let symbol = Shortcuts.symbol(for: command) {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { board.set(id, HintBoard.Badge(symbol: symbol, frame: frame, edge: edge)) }
                        .onChange(of: frame) { _, moved in board.set(id, HintBoard.Badge(symbol: symbol, frame: moved, edge: edge)) }
                        .onDisappear { board.set(id, nil) }
                }
            }
        }
    }
}

/// Draws a window's keys over everything in it, the timeline and viewer
/// included (AppKit views that would cover anything SwiftUI drew under
/// them), each just under or over its button.
struct ShortcutHintsOverlay: View {
    let board: HintBoard

    var body: some View {
        ZStack(alignment: .topLeading) {
            if ShortcutHints.shared.showing {
                ForEach(board.badges.sorted { $0.key < $1.key }, id: \.key) { _, badge in
                    ShortcutKeyBadge(symbol: badge.symbol)
                        .position(x: badge.frame.midX, y: badge.edge == .bottom ? badge.frame.maxY + 11 : badge.frame.minY - 11)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The editor runs under the title bar, so its frames are measured
        // from the window's top; so is this.
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The overlay's host: it draws, and every click, scroll and drag goes
/// through it to the editor underneath.
final class ShortcutHintsHostingView: NSHostingView<ShortcutHintsOverlay> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// A key as the hints draw it: dark text on amber, like the Export button.
struct ShortcutKeyBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.ui(10.5, .semibold))
            .foregroundStyle(Theme.onAmber.color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.amber.color))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
