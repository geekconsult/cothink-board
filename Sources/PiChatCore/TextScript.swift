import Foundation

/// Detects script content to pick a matching local speech voice.
public enum TextScript {
    /// Thai block U+0E00..U+0E7F.
    public static func isThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }
    }
}
