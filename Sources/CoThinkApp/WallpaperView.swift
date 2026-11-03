import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BoardCore

struct WallpaperBackgroundView: View {
    let board: Board
    let folder: URL
    let width: Double
    let height: Double
    let colorScheme: ColorScheme
    @State private var image: NSImage?

    private var imageURL: URL? {
        guard let id = board.wallpaperAssetID, let asset = board.projectAssets.first(where: { $0.id == id }) else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { return nil }
        return file
    }

    var body: some View {
        ZStack {
            if let color = board.wallpaperColor { Color(hex: color) }
            else { Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.76 : 0.68) }
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
                    .opacity(board.wallpaperOpacity ?? 0.45).allowsHitTesting(false)
            }
            Canvas { context, size in
                var dots = Path()
                stride(from: 20.0, through: size.width, by: 28).forEach { x in
                    stride(from: 20.0, through: size.height, by: 28).forEach { y in
                        dots.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                    }
                }
                context.fill(dots, with: .color(.secondary.opacity(0.22)))
            }.allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
        .task(id: "\(board.id)|\(board.wallpaperAssetID ?? "")|\(imageURL?.path ?? "")") {
            image = imageURL.flatMap { NSImage(contentsOf: $0) }
        }
    }
}

struct WallpaperSettingsView: View {
    @ObservedObject var model: BoardViewModel
    let original: Board
    @Environment(\.dismiss) private var dismiss
    @State private var useColor: Bool
    @State private var color: String
    @State private var assetID: String?
    @State private var opacity: Double
    @State private var pendingImage: URL?
    @State private var image: NSImage?
    @State private var localError: String?

    init(model: BoardViewModel, board: Board) {
        self.model = model; self.original = board
        _useColor = State(initialValue: board.wallpaperColor != nil)
        _color = State(initialValue: board.wallpaperColor ?? "#F4F1EC")
        _assetID = State(initialValue: board.wallpaperAssetID)
        _opacity = State(initialValue: board.wallpaperOpacity ?? 0.45)
    }

    private var board: Board { model.board?.id == original.id ? model.board! : original }
    private var folder: URL { board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model.defaultProjectFilesDirectory(for: board.id) }
    private var imageAssets: [ProjectAsset] {
        board.projectAssets.filter { UTType(filenameExtension: URL(fileURLWithPath: $0.relativePath).pathExtension)?.conforms(to: .image) == true }
    }
    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: color) }, set: { value in
            guard let rgb = NSColor(value).usingColorSpace(.sRGB) else { return }
            color = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            useColor = true
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board wallpaper").font(.title2.bold())
                    Text(original.title).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close wallpaper settings")
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("BACKGROUND COLOR").font(.caption.bold()).foregroundStyle(.secondary)
                    Picker("Background color", selection: $useColor) {
                        Text("System").tag(false); Text("Custom").tag(true)
                    }.pickerStyle(.segmented)
                    if useColor {
                        ColorPicker("Choose color", selection: colorBinding, supportsOpacity: false)
                        HStack {
                            ForEach(["#F4F1EC", "#FFF1D6", "#E3F0E8", "#DFEAF7", "#EAE1F2", "#242833"], id: \.self) { shade in
                                Button { color = shade } label: {
                                    Circle().fill(Color(hex: shade)).frame(width: 23, height: 23)
                                        .overlay(Circle().stroke(color == shade ? Color.accentColor : .secondary.opacity(0.4), lineWidth: color == shade ? 2 : 1))
                                }.buttonStyle(.plain).help(shade).accessibilityLabel("Color \(shade)")
                            }
                        }
                    }
                    Divider()
                    Text("IMAGE").font(.caption.bold()).foregroundStyle(.secondary)
                    HStack {
                        Button("Choose Image…", systemImage: "photo") { chooseImage() }
                        if !imageAssets.isEmpty {
                            Menu("Project Images") {
                                ForEach(imageAssets) { asset in
                                    Button(asset.name) { assetID = asset.id; pendingImage = nil; refreshImage() }
                                }
                            }
                        }
                    }
                    if pendingImage != nil || assetID != nil {
                        HStack {
                            Text(pendingImage?.lastPathComponent ?? imageAssets.first(where: { $0.id == assetID })?.name ?? "Image unavailable")
                                .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { pendingImage = nil; assetID = nil; image = nil }
                        }
                        HStack {
                            Text("Image strength")
                            Slider(value: $opacity, in: 0...1, step: 0.05)
                            Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 38)
                        }
                    }
                    Text("New images are copied to this board's Project Files folder.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.frame(width: 300, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("PREVIEW").font(.caption.bold()).foregroundStyle(.secondary)
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(useColor ? Color(hex: color) : Color(nsColor: .windowBackgroundColor))
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 260, height: 210).clipped().opacity(opacity)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text("An idea").font(.headline)
                            Text("Your notes stay in focus.").font(.caption)
                        }.foregroundStyle(.black).padding(15).frame(width: 170, alignment: .leading)
                            .background(Color(hex: "#FFF1B8"), in: RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    }.frame(width: 260, height: 210)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.secondary.opacity(0.2)))
                    Text("Wallpaper is saved with this board.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save Wallpaper") { save() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(minWidth: 650, minHeight: 390)
        .onAppear(perform: refreshImage)
        .alert("Wallpaper", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) { Button("OK", role: .cancel) {} } message: { Text(localError ?? "") }
    }

    private func refreshImage() {
        if let pendingImage { image = NSImage(contentsOf: pendingImage); return }
        guard let assetID, let asset = board.projectAssets.first(where: { $0.id == assetID }) else { image = nil; return }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { image = nil; return }
        image = NSImage(contentsOf: file)
    }

    private func chooseImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let selected = NSImage(contentsOf: url) else { localError = "The selected file could not be opened as an image."; return }
        pendingImage = url; assetID = nil; image = selected
    }

    private func save() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked, let latest = model.board, latest.id == original.id else { return }
        guard latest.wallpaperColor == original.wallpaperColor, latest.wallpaperAssetID == original.wallpaperAssetID,
              latest.wallpaperOpacity == original.wallpaperOpacity else { localError = "The wallpaper changed elsewhere. Close and reopen this window to use the latest settings."; return }
        var copied: URL?
        var imported: ProjectAsset?
        do {
            if let pendingImage {
                let targetFolder = latest.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model.defaultProjectFilesDirectory(for: latest.id)
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let source = pendingImage.lastPathComponent
                let stem = pendingImage.deletingPathExtension().lastPathComponent, ext = pendingImage.pathExtension
                var target = targetFolder.appendingPathComponent(source), number = 2
                while FileManager.default.fileExists(atPath: target.path) || latest.projectAssets.contains(where: { $0.relativePath == target.lastPathComponent }) {
                    target = targetFolder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"); number += 1
                }
                try FileManager.default.copyItem(at: pendingImage, to: target)
                copied = target
                imported = ProjectAsset(name: source, relativePath: target.lastPathComponent)
            }
            let chosenID = imported?.id ?? assetID
            if let chosenID, imported == nil, !latest.projectAssets.contains(where: { $0.id == chosenID }) { localError = "That project image is no longer available."; return }
            let path = copied?.deletingLastPathComponent().path
            let success = model.mutate { current in
                if let imported { current.assets = current.projectAssets + [imported] }
                if let path { current.projectFilesPath = path }
                current.wallpaperColor = useColor ? color : nil
                current.wallpaperAssetID = chosenID
                current.wallpaperOpacity = chosenID == nil ? nil : opacity
            }
            if success { dismiss() }
            else { if let copied { try? FileManager.default.removeItem(at: copied) }; localError = model.error ?? "Could not save wallpaper."; model.error = nil }
        } catch {
            if let copied { try? FileManager.default.removeItem(at: copied) }
            localError = "Could not save the wallpaper image. \(error.localizedDescription)"
        }
    }
}
