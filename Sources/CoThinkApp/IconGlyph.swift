import SwiftUI
import BoardCore

/// Renders a note icon as a stroke glyph, aspect-fit and centered inside the given rect.
/// Uses the same parsed geometry as the PDF export — one geometry source everywhere.
struct IconGlyph: Shape {
    let icon: NoteIcon

    func path(in rect: CGRect) -> Path {
        let glyph = NoteIcon.glyphSize(width: rect.width, height: rect.height)
        let scale = glyph / NoteIcon.svgViewBox
        let originX = rect.midX - glyph / 2
        let originY = rect.midY - glyph / 2
        var path = Path()
        for command in icon.geometry {
            switch command {
            case .moveTo(let x, let y):
                path.move(to: CGPoint(x: originX + x * scale, y: originY + y * scale))
            case .lineTo(let x, let y):
                path.addLine(to: CGPoint(x: originX + x * scale, y: originY + y * scale))
            case .curve(let x1, let y1, let x2, let y2, let x, let y):
                path.addCurve(to: CGPoint(x: originX + x * scale, y: originY + y * scale),
                              control1: CGPoint(x: originX + x1 * scale, y: originY + y1 * scale),
                              control2: CGPoint(x: originX + x2 * scale, y: originY + y2 * scale))
            case .quad(let x1, let y1, let x, let y):
                path.addQuadCurve(to: CGPoint(x: originX + x * scale, y: originY + y * scale),
                                  control: CGPoint(x: originX + x1 * scale, y: originY + y1 * scale))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}
