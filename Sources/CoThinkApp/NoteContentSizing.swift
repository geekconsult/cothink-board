import AppKit
import BoardCore

/// Measures the height a note tile needs so its text fits without clipping.
/// Mirrors NoteTile's reading layout: system-medium font, word-wrapped at the
/// tile width minus the 16pt tile padding on each side, 16pt vertical padding.
enum NoteContentSizing {
    static let minimumHeight: Double = 50
    private static let horizontalPadding: Double = 16
    private static let verticalPadding: Double = 16

    static func fittedSize(for note: Note) -> (width: Double, height: Double)? {
        guard note.shape != .line else { return nil }
        let text = note.text.isEmpty ? (note.shape == .text ? "Empty text" : "Empty note") : note.text
        if note.text.isEmpty && note.shape != nil && note.shape != .text { return nil }
        let font = NSFont.systemFont(ofSize: note.fontSize ?? 15, weight: .medium)
        let lines = text.components(separatedBy: "\n")
        let textWidth = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        // Ellipses and diamonds need extra space at their narrower edges.
        let factor: Double = note.shape == .diamond ? 2 : note.shape == .ellipse ? 1.5 : 1
        var width = max(note.extentMinWidth, ceil(textWidth * factor + horizontalPadding * 2 + 2))
        let hasAttachments = !(note.imagePath ?? "").isEmpty || !(note.assetIDs ?? []).isEmpty
        if hasAttachments { width = max(width, note.width) }
        var height = max(note.extentMinHeight, self.height(for: text, fontSize: note.fontSize ?? 15, width: width) * factor)
        // Image heights are proportional to the tile and attachments can have
        // previews; preserve their existing space rather than collapsing them.
        if hasAttachments { height = max(height, note.height) }
        return (width, ceil(height))
    }

    static func groupTitleWidth(_ group: BoardGroup) -> Double {
        let font = NSFont.systemFont(ofSize: group.fontSize ?? 11, weight: .bold)
        let title = group.title.uppercased() as NSString
        return ceil(title.size(withAttributes: [.font: font, .kern: 1]).width)
    }

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
