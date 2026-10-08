import Foundation
import IOKit.pwr_mgt

/// A macOS power assertion, held from when it's made until `release()`.
/// Exports keep the Mac from idling to sleep with one, and the app's player
/// keeps the display on with one while the timeline plays.
public final class PowerAssertion: @unchecked Sendable {
    public enum Kind: Sendable {
        /// The Mac doesn't idle to sleep; the display still can.
        case system
        /// The display stays on, so the screen saver and the lock screen
        /// keep away (and the Mac stays awake too).
        case display

        var type: String {
            switch self {
            case .system: return kIOPMAssertionTypePreventUserIdleSystemSleep
            case .display: return kIOPMAssertionTypePreventUserIdleDisplaySleep
            }
        }
    }

    private let lock = NSLock()
    private var id: IOPMAssertionID?

    /// `reason` shows in `pmset -g assertions`. Nil when macOS won't make
    /// it, which only means the Mac may sleep as usual.
    public init?(_ kind: Kind, reason: String) {
        var made = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kind.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &made)
        guard result == kIOReturnSuccess else { return nil }
        id = made
    }

    /// Lets it go. Again does nothing.
    public func release() {
        let held: IOPMAssertionID? = lock.withLock {
            defer { id = nil }
            return id
        }
        if let held { IOPMAssertionRelease(held) }
    }

    deinit {
        release()
    }
}
