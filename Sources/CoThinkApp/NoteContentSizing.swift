import AppKit

/// Measures the height a note tile needs so its text fits without clipping.
/// Mirrors NoteTile's reading layout: system-medium font, word-wrapped at the
/// tile width minus the 16pt tile padding on each side, 16pt vertical padding.
enum NoteContentSizing {
    static let minimumHeight: Double = 50
    private static let horizontalPadding: Double = 16
    private static let verticalPadding: Double = 16

    static func height(for text: String, fontSize: Double, width: Double) -> Double {
        let contentWidth = max(20, width - horizontalPadding * 2)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let storage = NSTextStorage(string: text.isEmpty ? " " : text, attributes: attrs)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let measured = layout.usedRect(for: container).height
        let total = measured + verticalPadding * 2 + 2
        return max(minimumHeight, total.rounded(.up))
    }
}
