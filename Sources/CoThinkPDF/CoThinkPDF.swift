import Foundation
import AppKit
import BoardCore
import BoardPDFRendering

private struct PDFRequest: Decodable {
    let board: Board
    let projectFolder: String
    let template: String
    let destination: String
    let overwrite: Bool
}

@main struct CoThinkPDF {
    @MainActor static func main() {
        func fail(_ message: String) -> Never {
            let payload = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
            FileHandle.standardOutput.write(payload); exit(1)
        }
        do {
            let request = try JSONDecoder().decode(PDFRequest.self, from: FileHandle.standardInput.readDataToEndOfFile())
            guard let template = BoardPDFTemplate(rawValue: request.template) else { fail("Unknown PDF template") }
            let destination = URL(fileURLWithPath: request.destination)
            guard request.destination.hasPrefix("/"), destination.pathExtension.lowercased() == "pdf" else { fail("destination must be an absolute PDF path") }
            if !request.overwrite && FileManager.default.fileExists(atPath: destination.path) { fail("Destination already exists; set overwrite to true to replace it") }
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            let preview = BoardPDFPreview(board: request.board, projectFolder: URL(fileURLWithPath: request.projectFolder, isDirectory: true))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 794, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = preview.webView
            preview.load(board: request.board, template: template)
            let loadDeadline = Date().addingTimeInterval(45)
            while preview.loading && Date() < loadDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard !preview.loading, preview.ready else { fail(preview.error ?? "PDF preview timed out") }
            var finished = false, success = false
            preview.savePDF(to: destination, overwrite: request.overwrite) { result in success = result; finished = true }
            let saveDeadline = Date().addingTimeInterval(90)
            while !finished && Date() < saveDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard finished && success else { fail(preview.error ?? "PDF export timed out") }
            let result = try JSONSerialization.data(withJSONObject: ["path": destination.path, "template": template.rawValue, "revision": request.board.revision])
            FileHandle.standardOutput.write(result)
            window.close()
        } catch { fail(error.localizedDescription) }
    }
}
