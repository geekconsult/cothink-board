import Foundation
import AppKit
import Combine
import WebKit
import PDFKit
import UniformTypeIdentifiers
import BoardCore

@MainActor
public final class BoardPDFPreview: NSObject, ObservableObject, WKNavigationDelegate {
    public let webView: WKWebView
    @Published public var loading = true
    @Published public var ready = false
    @Published public var saving = false
    @Published public var error: String?
    private var navigation: WKNavigation?
    private let images: [String: String]

    public init(board: Board, projectFolder: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        images = Self.loadImages(board: board, folder: projectFolder)
        super.init()
        webView.navigationDelegate = self
    }

    public func load(board: Board, template: BoardPDFTemplate) {
        loading = true; ready = false; error = nil
        navigation = webView.loadHTMLString(BoardPDFHTML.render(board: board, template: template, images: images), baseURL: nil)
    }
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        let waitForImages = """
        await Promise.all(Array.from(document.images).map(async image => {
          try { await image.decode(); }
          catch (_) {
            const message = document.createElement('p');
            message.className = 'image-warning';
            message.textContent = 'Image could not be rendered.';
            image.replaceWith(message);
          }
        }));
        await Promise.all(Array.from(document.querySelectorAll('svg image')).map(async image => {
          const probe = new Image(); probe.src = image.getAttribute('href');
          try { await probe.decode(); }
          catch (_) {
            image.remove();
            const caption = document.querySelector('.caption');
            if (caption) caption.append(' Wallpaper image could not be rendered.');
          }
        }));
        await document.fonts.ready;
        document.documentElement.getBoundingClientRect();
        await new Promise(resolve => setTimeout(resolve, 250));
        return true;
        """
        webView.callAsyncJavaScript(waitForImages, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, navigation === self.navigation else { return }
            switch result {
            case .success: self.ready = true
            case .failure(let error): self.error = error.localizedDescription
            }
            self.loading = false
        }
    }
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        self.error = error.localizedDescription; loading = false
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        self.error = error.localizedDescription; loading = false
    }

    public func savePDF(to url: URL, overwrite: Bool = true, completion: @escaping (Bool) -> Void) {
        saving = true; error = nil
        // Collect safe page boundaries from actual rendered lines and blocks, so text and images
        // are not cut by a fixed-height slice. Board text is escaped and page scripts are disabled.
        let measure = """
        (() => {
          window.scrollTo(0, 0);
          const height = Math.ceil(document.documentElement.scrollHeight);
          const width = document.documentElement.clientWidth;
          const pageHeight = (841.89 - 85) * width / (595.28 - 85);
          const candidates = [height];
          const protectedRects = Array.from(document.querySelectorAll('.hero,.section-head,.canvas,.attachment-image,.relation,.note-head')).map(e => {
            const r = e.getBoundingClientRect(); return [r.top + scrollY, r.bottom + scrollY];
          });
          document.querySelectorAll('.note-card').forEach(e => {
            const r = e.getBoundingClientRect();
            if (r.height <= pageHeight) protectedRects.push([r.top + scrollY, r.bottom + scrollY]);
          });
          document.querySelectorAll('.hero,.canvas,.caption,.note-card,.attachment-image,.relation,.empty,.footer').forEach(e => {
            candidates.push(e.getBoundingClientRect().bottom + scrollY + 4);
          });
          document.querySelectorAll('.note-text').forEach(e => {
            const range = document.createRange(); range.selectNodeContents(e);
            Array.from(range.getClientRects()).forEach(r => candidates.push(r.bottom + scrollY + 1));
          });
          return {width, height, breaks: candidates.filter(y => y > 0 && y < height && !protectedRects.some(r => y > r[0] + 1 && y < r[1] - 1))};
        })()
        """
        webView.evaluateJavaScript(measure) { [self] value, failure in
            guard failure == nil, let result = value as? [String: Any], let width = (result["width"] as? NSNumber)?.doubleValue,
                  let height = (result["height"] as? NSNumber)?.doubleValue, width > 0, height > 0, height <= 200_000 else {
                self.error = "Could not prepare this board for PDF export. The document may be too large."
                self.saving = false; completion(false); return
            }
            let breaks = (result["breaks"] as? [NSNumber] ?? []).map(\.doubleValue).sorted()
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: width, height: height)
            self.webView.createPDF(configuration: config) { [self] result in
                do {
                    let source = try result.get()
                    let output = try Self.paginate(source, width: width, height: height, breaks: breaks)
                    guard let document = PDFDocument(data: output), document.pageCount > 0 else { throw PDFExportError.invalidPDF }
                    try output.write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
                    self.saving = false; completion(true)
                } catch {
                    self.error = "Could not create the PDF: \(error.localizedDescription)"
                    self.saving = false; completion(false)
                }
            }
        }
    }

    private enum PDFExportError: LocalizedError {
        case invalidPDF
        var errorDescription: String? { "The PDF could not be rendered." }
    }

    private static func paginate(_ source: Data, width: Double, height: Double, breaks: [Double]) throws -> Data {
        guard let provider = CGDataProvider(data: source as CFData), let input = CGPDFDocument(provider), let page = input.page(at: 1) else { throw PDFExportError.invalidPDF }
        let sourceBox = page.getBoxRect(.mediaBox)
        let sourceScale = sourceBox.width / width
        let a4Width = 595.28, a4Height = 841.89, margin = 42.5
        let scale = (a4Width - 2 * margin) / sourceBox.width
        let available = (a4Height - 2 * margin) / (scale * sourceScale)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw PDFExportError.invalidPDF }
        var mediaBox = CGRect(x: 0, y: 0, width: a4Width, height: a4Height)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw PDFExportError.invalidPDF }
        var start = 0.0
        while start < height - 0.5 {
            let limit = min(height, start + available)
            let end = limit >= height ? height : (breaks.last(where: { $0 > start + min(80, available / 4) && $0 <= limit }) ?? limit)
            let segment = (end - start) * sourceScale
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(mediaBox)
            context.saveGState()
            context.clip(to: CGRect(x: margin, y: a4Height - margin - segment * scale, width: a4Width - 2 * margin, height: segment * scale))
            context.translateBy(x: margin, y: a4Height - margin - segment * scale)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -sourceBox.minX, y: -(sourceBox.minY + sourceBox.height - end * sourceScale))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
            start = end
        }
        context.closePDF()
        return data as Data
    }

    private static func loadImages(board: Board, folder: URL) -> [String: String] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var images: [String: String] = [:]
        var remaining = 20 * 1024 * 1024
        func add(_ url: URL, key: String) {
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), let mime = type.preferredMIMEType else { return }
            images[key] = ""
            guard
                  let attrs = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), attrs.isRegularFile == true,
                  let size = attrs.fileSize, size <= 5 * 1024 * 1024, size <= remaining,
                  let data = try? Data(contentsOf: url) else { return }
            remaining -= size
            images[key] = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        var used = Set(board.notes.flatMap { $0.assetIDs ?? [] })
        if let wallpaperID = board.wallpaperAssetID { used.insert(wallpaperID) }
        for asset in board.projectAssets where used.contains(asset.id) {
            if UTType(filenameExtension: URL(fileURLWithPath: asset.relativePath).pathExtension)?.conforms(to: .image) == true { images[asset.id] = "" }
            let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { continue }
            add(url, key: asset.id)
        }
        for note in board.notes {
            if let path = note.imagePath, !path.isEmpty {
                images["legacy:\(note.id)"] = ""
                add(URL(fileURLWithPath: path), key: "legacy:\(note.id)")
            }
        }
        return images
    }
}
