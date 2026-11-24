import Foundation

struct PersonCamera: Decodable {
    let id: String
    let tour: Int?
    let camera: BoardCamera
}

struct BoardCamera: Codable, Equatable {
    let x, y, width, height, zoom: CGFloat

    init?(viewport: CGRect, zoom: CGFloat) {
        guard viewport.width > 0, viewport.height > 0, zoom > 0 else { return nil }
        x = viewport.midX / zoom
        y = viewport.midY / zoom
        width = viewport.width / zoom
        height = viewport.height / zoom
        self.zoom = zoom
    }
    var payload: [String: CGFloat] { ["x":x, "y":y, "width":width, "height":height, "zoom":zoom] }
    func fittedZoom(in size: CGSize) -> CGFloat {
        min(zoom, size.width / width, size.height / height)
    }
    func scrollOrigin(in size: CGSize, document: CGSize, scale: CGFloat) -> CGPoint {
        CGPoint(x: max(0,min(x * scale - size.width / 2,document.width - size.width)),
                y: max(0,min(y * scale - size.height / 2,document.height - size.height)))
    }
}
