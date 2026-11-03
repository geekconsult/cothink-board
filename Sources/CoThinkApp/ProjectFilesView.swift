import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BoardCore

struct ProjectFilesView: View {
    @ObservedObject var model: BoardViewModel
    let boardID: String
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var board: Board? { model.board?.id == boardID ? model.board : nil }
    private var folderURL: URL {
        guard let board else { return model.defaultProjectFilesDirectory(for: boardID) }
        return board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? model.defaultProjectFilesDirectory(for: boardID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project Files").font(.title2.bold())
                    Text(board?.title ?? "Board").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("STORAGE LOCATION").font(.caption.bold()).foregroundStyle(.secondary)
                Text(folderURL.path).font(.caption.monospaced()).lineLimit(1).help(folderURL.path)
                HStack {
                    Button("Add Files…", systemImage: "plus") { addFiles() }
                    Button("Choose Folder…", systemImage: "folder.badge.gearshape") { chooseFolder() }
                    Button("Show in Finder", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(folderURL)
                    }
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            if let board, !board.projectAssets.isEmpty {
                List {
                    ForEach(board.projectAssets) { asset in
                        assetRow(asset, board: board)
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("No project files", systemImage: "folder", description: Text("Add images, PDFs, or other files, then attach them to notes."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Files are copied into this board’s project folder. Board JSON stores file links, not the file contents.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.thinMaterial)
        .alert("Project Files", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder
    private func assetRow(_ asset: ProjectAsset, board: Board) -> some View {
        let url = folderURL.appendingPathComponent(asset.relativePath)
        HStack(spacing: 10) {
            Image(systemName: iconName(for: url)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(asset.name).lineLimit(1)
                Text("\(asset.relativePath) · used in \(board.notes.filter { $0.assetIDs?.contains(asset.id) == true }.count) notes\(board.wallpaperAssetID == asset.id ? " · wallpaper" : "")")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Open file")
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help("Show in Finder")
            Button(role: .destructive) { removeAsset(asset.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).help(board.wallpaperAssetID == asset.id ? "Remove file and clear wallpaper (keeps the file on disk)" : "Remove file from this board (keeps the file on disk)")
        }
        .padding(.vertical, 4)
    }

    private func iconName(for url: URL) -> String {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true { return "photo" }
        if url.pathExtension.lowercased() == "pdf" { return "doc.richtext" }
        return "doc"
    }

    private func addFiles() {
        guard let board else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Project"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            var added: [ProjectAsset] = []
            for source in panel.urls {
                let destination = uniqueDestination(for: source.lastPathComponent, in: folderURL)
                try FileManager.default.copyItem(at: source, to: destination)
                added.append(ProjectAsset(name: source.lastPathComponent, relativePath: destination.lastPathComponent))
            }
            let path = folderURL.path
            guard model.mutate({ current in
                guard current.id == board.id else { return }
                current.projectFilesPath = path
                current.assets = (current.assets ?? []) + added
            }) else {
                errorMessage = model.error ?? "Could not update the board."
                return
            }
        } catch {
            errorMessage = "Could not copy the selected file. \(error.localizedDescription)"
        }
    }

    private func chooseFolder() {
        guard let board else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Project Folder"
        guard panel.runModal() == .OK, let destinationFolder = panel.url else { return }

        do {
            try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
            var relocatedAssets: [ProjectAsset] = []
            for asset in board.projectAssets {
                let source = folderURL.appendingPathComponent(asset.relativePath)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    relocatedAssets.append(asset)
                    continue
                }
                if source.deletingLastPathComponent().standardizedFileURL == destinationFolder.standardizedFileURL {
                    relocatedAssets.append(asset)
                    continue
                }
                let target = uniqueDestination(for: source.lastPathComponent, in: destinationFolder)
                try FileManager.default.copyItem(at: source, to: target)
                relocatedAssets.append(ProjectAsset(id: asset.id, name: asset.name, relativePath: target.lastPathComponent))
            }
            let path = destinationFolder.path
            guard model.mutate({ current in
                guard current.id == board.id else { return }
                current.projectFilesPath = path
                current.assets = relocatedAssets
            }) else {
                errorMessage = model.error ?? "Could not update the board."
                return
            }
        } catch {
            errorMessage = "Could not move project files to that folder. \(error.localizedDescription)"
        }
    }

    private func removeAsset(_ id: String) {
        guard model.board?.id == boardID else { return }
        _ = model.mutate { current in
            current.assets?.removeAll { $0.id == id }
            if current.wallpaperAssetID == id { current.wallpaperAssetID = nil }
            for index in current.notes.indices {
                current.notes[index].assetIDs?.removeAll { $0 == id }
            }
        }
    }

    private func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let source = URL(fileURLWithPath: fileName)
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }
}
