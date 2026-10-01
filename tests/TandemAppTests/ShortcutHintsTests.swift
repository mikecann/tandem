import AppKit
import XCTest
@testable import TandemApp

/// Holding ⌘ shows the buttons' keys; using it for anything else doesn't.
@MainActor
final class ShortcutHintsTests: XCTestCase {
    private func hints() -> ShortcutHints {
        let hints = ShortcutHints()
        hints.isAppActive = { true }
        hints.isMouseDown = { false }
        return hints
    }

    private func wait() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55)!
    }

    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 6)!
    }

    private func click(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testPressingCommandShowsTheKeysAtOnceAndLettingGoHidesThem() {
        let h = hints()
        h.handle(flags(.command))
        XCTAssertTrue(h.showing, "straight away")
        h.handle(flags([]))
        XCTAssertFalse(h.showing)
    }

    func testAShortcutDoesntShowThemUntilCommandIsPressedAgain() {
        let h = hints()
        h.handle(flags(.command))
        h.handle(key("z", .command))
        XCTAssertFalse(h.showing, "⌘Z was an undo, not a look")
        // ⌘⇧Z, then Shift let go with ⌘ still down.
        h.handle(flags([.command, .shift]))
        h.handle(flags(.command))
        wait()
        XCTAssertFalse(h.showing)
        h.handle(flags([]))
        h.handle(flags(.command))
        wait()
        XCTAssertTrue(h.showing, "a fresh press shows them")
    }

    func testAClickWithCommandHidesThem() {
        let h = hints()
        h.handle(flags(.command))
        wait()
        XCTAssertTrue(h.showing)
        h.handle(click(.command))
        XCTAssertFalse(h.showing)
        wait()
        XCTAssertFalse(h.showing, "they stay hidden while ⌘ is still down")
    }

    func testAClickWithoutCommandDoesntStopTheNextPress() {
        let h = hints()
        h.handle(click([]))
        h.handle(flags(.command))
        wait()
        XCTAssertTrue(h.showing)
    }

    func testOtherModifiersDontShowThem() {
        let h = hints()
        h.handle(flags([.command, .option]))
        wait()
        XCTAssertFalse(h.showing)
        h.handle(flags(.shift))
        wait()
        XCTAssertFalse(h.showing)
    }

    func testNothingShowsInTheBackgroundOrMidDrag() {
        let h = hints()
        h.isAppActive = { false }
        h.handle(flags(.command))
        wait()
        XCTAssertFalse(h.showing, "⌘ held in another app")
        h.reset()
        h.isAppActive = { true }
        h.isMouseDown = { true }
        h.handle(flags(.command))
        wait()
        XCTAssertFalse(h.showing, "⌘ held through a drag")
    }

    func testTheBadgesShowTheKeymapsKeys() throws {
        let keymap = try Keymap.load(KeymapTests.bundledKeymapData())
        XCTAssertEqual(Shortcuts.symbol(for: .export, in: keymap), "⌘E")
        XCTAssertEqual(Shortcuts.symbol(for: .toolBlade, in: keymap), "C")
        XCTAssertEqual(Shortcuts.symbol(for: .playPause, in: keymap), "Space")
    }
}
