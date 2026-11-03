import Foundation
import AppKit
import UniformTypeIdentifiers
import BoardCore

/// Renders the saved board model, independently of the app window and its scroll position.
func captureBoard(_ board: Board, store: BoardStore) throws -> MCPToolContent {
    let notes = Dictionary(board.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let points = board.connections.flatMap { edge -> [ConnectionPoint] in
        guard let from = notes[edge.from], let to = notes[edge.to] else { return [] }
        return edge.controlPoints(from: from, to: to)
    }
    let minX = min(0, (board.notes.map(\.x) + board.groups.map(\.x) + points.map(\.x)).min() ?? 0) - 35
    let minY = min(0, (board.notes.map(\.y) + board.groups.map(\.y) + points.map(\.y)).min() ?? 0) - 35
    let right = max(500, (board.notes.map { $0.x + $0.width } + board.groups.map { $0.x + $0.width } + points.map(\.x)).max() ?? 0) + 35
    let bottom = max(280, (board.notes.map { $0.y + $0.height } + board.groups.map { $0.y + $0.height } + points.map(\.y)).max() ?? 0) + 35
    let worldWidth = right - minX, worldHeight = bottom - minY
    let scale = min(2048 / worldWidth, 2048 / worldHeight)
    let width = max(1, Int(ceil(worldWidth * scale))), height = max(1, Int(ceil(worldHeight * scale)))
    let root = (board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? store.defaultProjectFilesDirectory(for: board.id)).standardizedFileURL.resolvingSymlinksInPath()
    var images: [String: String] = [:], missing = 0, remaining = 20 * 1024 * 1024
    func add(_ url: URL, key: String) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else { return }
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true,
              let size = info.fileSize, size <= 5 * 1024 * 1024, size <= remaining,
              let data = try? Data(contentsOf: url) else { missing += 1; return }
        remaining -= size
        images[key] = "data:\(mime);base64,\(data.base64EncodedString())"
    }
    var used = Set(board.notes.flatMap { $0.assetIDs ?? [] })
    if let id = board.wallpaperAssetID { used.insert(id) }
    for asset in board.projectAssets where used.contains(asset.id) {
        let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { missing += 1; continue }
        add(url, key: asset.id)
    }
    for note in board.notes {
        if let path = note.imagePath, !path.isEmpty { add(URL(fileURLWithPath: path), key: "legacy:\(note.id)") }
    }
    let svg = BoardPDFHTML.svg(board: board, images: images).replacingOccurrences(of: "<svg xmlns=", with: "<svg width=\"\(width)\" height=\"\(height)\" xmlns=")
    guard let image = NSImage(data: Data(svg.utf8)), let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ToolFailure(message: "Could not create board overview image") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ToolFailure(message: "Could not encode board overview PNG") }
    let metadata: [String: Any] = ["board_id": board.id, "revision": board.revision, "width": width, "height": height, "board_bounds": ["x": minX, "y": minY, "width": worldWidth, "height": worldHeight], "omitted_images": missing, "description": "Reconstructed overview of the saved board, not a screenshot of the current app window. Note text may be abbreviated; use get_board_context for full text and positions."]
    let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    return MCPToolContent(blocks: [["type": "text", "text": String(decoding: data, as: UTF8.self)], ["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]])
}
