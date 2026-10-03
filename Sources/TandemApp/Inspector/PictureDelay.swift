import Foundation
import TandemCore

/// How late a file's picture is against its sound (`MediaItem.pictureDelay`),
/// as the Info tab and Settings offer it: a webcam's picture lags its mic,
/// Mike's by about 80 ms.
enum PictureDelay {
    /// The choices, in milliseconds.
    static let choices = [0, 40, 60, 80, 100, 120, 150]

    static func title(milliseconds: Int) -> String {
        milliseconds == 0 ? "As recorded" : "\(milliseconds) ms"
    }

    static func milliseconds(_ delay: Time?) -> Int {
        Int(((delay?.seconds ?? 0) * 1000).rounded())
    }

    /// Sets `item`'s delay: one undo step.
    static func batch(_ item: MediaItem, milliseconds: Int) -> EditBatch? {
        guard milliseconds != self.milliseconds(item.pictureDelay) else { return nil }
        let value: JSONValue = milliseconds == 0 ? .null : .number(Double(milliseconds) / 1000)
        return EditBatch(
            label: milliseconds == 0 ? "Picture as recorded" : "Picture delay \(milliseconds) ms",
            commands: [.updateMedia(mediaID: item.id, patch: .object(["pictureDelay": value]))]
        )
    }
}
