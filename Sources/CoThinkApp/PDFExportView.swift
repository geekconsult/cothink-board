import SwiftUI
import AppKit
import WebKit
import PDFKit
import UniformTypeIdentifiers
import BoardCore
import BoardPDFRendering

private struct PDFWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PDFExportView: View {
    let board: Board
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview: BoardPDFPreview
    @State private var template: BoardPDFTemplate = .editorial

    init(board: Board, projectFolder: URL) {
        self.board = board
        _preview = StateObject(wrappedValue: BoardPDFPreview(board: board, projectFolder: projectFolder))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export as PDF").font(.title2.bold())
                    Text("Choose a template for \(board.title)").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close PDF export")
                    .keyboardShortcut(.cancelAction).disabled(preview.saving)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("TEMPLATE").font(.caption.bold()).foregroundStyle(.secondary).tracking(1)
                    ForEach(BoardPDFTemplate.allCases) { choice in
                        Button { template = choice } label: {
                            HStack(alignment: .center, spacing: 12) {
                                templateSwatch(choice)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(choice.title).font(.headline)
                                    Text(choice.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                                if template == choice { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(template == choice ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(template == choice ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel("\(choice.title), \(choice.subtitle)").disabled(preview.saving)
                    }
                    Text("Includes a canvas overview, note text, attached images and relationships. Images: up to 5 MB each, 20 MB total.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    Spacer()
                }.padding(20).frame(width: 285)
                Divider()
                ZStack {
                    Color(nsColor: .controlBackgroundColor).opacity(0.6)
                    PDFWebView(webView: preview.webView).padding(14)
                    if preview.loading { ProgressView("Preparing preview…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                if let error = preview.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                if preview.saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.disabled(preview.saving)
                Button("Save PDF…") { save() }.keyboardShortcut(.defaultAction).disabled(preview.loading || preview.saving || !preview.ready)
            }.padding(16)
        }
        .frame(minWidth: 840, minHeight: 610)
        .onAppear { preview.load(board: board, template: template) }
        .onChange(of: template) { _, newValue in preview.load(board: board, template: newValue) }
    }

    private func templateSwatch(_ choice: BoardPDFTemplate) -> some View {
        let bg: Color = choice == .editorial ? Color(hex: "#F4E6D7") : choice == .studio ? Color(hex: "#E4EDF9") : Color(hex: "#F1F1F1")
        let accent: Color = choice == .editorial ? Color(hex: "#B86442") : choice == .studio ? Color(hex: "#355FA3") : .black
        return VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(accent).frame(width: 18, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.75)).frame(width: 28, height: 5)
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.25)).frame(width: 33, height: 3)
            RoundedRectangle(cornerRadius: 2).fill(accent.opacity(0.25)).frame(width: 25, height: 3)
        }.padding(8).frame(width: 50, height: 59).background(bg, in: RoundedRectangle(cornerRadius: 6))
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(board.title).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preview.savePDF(to: url) { success in if success { dismiss() } }
    }
}
