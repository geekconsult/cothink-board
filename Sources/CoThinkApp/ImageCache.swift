import AppKit

/// Shared decoded-image cache keyed by path, file size and mtime, so tiles, the
/// inspector and the mascot decode once instead of on every body evaluation.
/// NSCache evicts under memory pressure and re-decodes on the next miss.
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(atPath path: String) -> NSImage? {
        image(at: URL(fileURLWithPath: path))
    }

    static func image(at url: URL) -> NSImage? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return nil }
        let size = attributes?[.size] as? Int ?? 0
        let key = "\(url.path)|\(size)|\(modified.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
