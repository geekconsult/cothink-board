import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BoardCore

private struct InspectorDraftSnapshot: Equatable {
    var text: String
    var imagePath: String
    var title: String
    var color: String
    var strokeColor: String
    var strokeWidth: Double
    var strokeStyle: LineStyle
    var direction: ConnectionDirection
    var label: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct InspectorView: View {
    @ObservedObject var model: BoardViewModel
    let board: Board
    @State private var title = ""
    @State private var baselineTitle = ""
    @State private var baselineBoardID: String?
    @State private var baselineNote: Note?
    @State private var baselineGroup: BoardGroup?
    @State private var baselineConnection: Connection?
    @State private var strokeColor = "#6F7785"
    @State private var strokeWidth = 1.0
    @State private var strokeStyle: LineStyle = .solid
    @State private var direction: ConnectionDirection = .oneWay
    @State private var label = ""
    @State private var text = ""
    @State private var imagePath = ""
    @State private var color = "#FFF1AF"
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var width = 190.0
    @State private var height = 100.0
    @State private var saveTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var saveStatus = "Saved"
    @Environment(\.scenePhase) private var scenePhase

    private var selectionKey: String { "\(board.id):\(model.selectedNoteID ?? model.selectedGroupID ?? model.selectedConnectionID ?? "board")" }
    private var note: Note? { board.notes.first { $0.id == model.selectedNoteID } }
    private var group: BoardGroup? { board.groups.first { $0.id == model.selectedGroupID } }
    private var connection: Connection? { board.connections.first { $0.id == model.selectedConnectionID } }
    private var draftSnapshot: InspectorDraftSnapshot {
        InspectorDraftSnapshot(text: text, imagePath: imagePath, title: title, color: color,
                               strokeColor: strokeColor, strokeWidth: strokeWidth, strokeStyle: strokeStyle,
                               direction: direction, label: label, x: x, y: y, width: width, height: height)
    }

    var body: some View {
        panel
        .onAppear(perform: loadSelection)
        .onReceive(NotificationCenter.default.publisher(for: .flushBoardDraft)) { _ in savePending() }
        .onChange(of: selectionKey) { _, _ in savePending(); loadSelection() }
        .onChange(of: board.revision) { _, _ in
            if !hasDraft { loadSelection() }
        }
        .onChange(of: draftSnapshot) { _, _ in scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { savePending() } }
        .onDisappear { savePending() }
    }

    private var panel: some View {
        ScrollView { panelStack }
            .background(.regularMaterial)
    }

    private var panelStack: some View {
        VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(inspectorTitle)
                        .font(.headline)
                    Spacer()
                    if hasObjectSelection {
                        Button(role: .destructive, action: model.deleteSelection) { Image(systemName: "trash") }.help("Delete selection")
                    }
                }
                Divider()
                selectionProperties
                HStack { Text(saveStatus).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Reload", action: loadSelection).font(.caption) }
                Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inspectorTitle: String {
        if note != nil { return "Note" }
        if group != nil { return "Group" }
        if connection != nil { return "Connection" }
        return "Board"
    }

    private var hasObjectSelection: Bool { note != nil || group != nil || connection != nil }

    @ViewBuilder
    private var selectionProperties: some View {
        if let note {
            noteProperties(note)
        } else if let group {
            groupProperties(group)
        } else if let connection {
            connectionProperties(connection)
        } else if !model.selectedNoteIDs.isEmpty {
            Text("\(model.selectedNoteIDs.count) notes selected").font(.headline)
            Text("Choose Group to lock the selected notes together, or press Delete to remove them.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            boardProperties
        }
    }

    private func noteProperties(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("IDEA").font(.caption.bold()).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 100).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            imageAttachmentControls
            if let group = board.groupContaining(noteID: note.id) {
                Label("Locked in \(group.title)", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                Button("Unlock from group", systemImage: "lock.open") { model.unlockNote(note.id) }
                    .help("Remove this note from its group so it can move independently")
            }
            geometryFields
            colors
            strokeControls
        }
    }

    private func groupProperties(_ group: BoardGroup) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Group name", text: $text)
            Label("\(group.memberIDs?.count ?? 0) locked notes", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
            Button("Lock notes inside group") { model.lockNotes(in: group.id) }
                .help("Lock notes whose centers are inside this group. Notes move together when you drag any member.")
            geometryFields
            colors
            strokeControls
        }
    }

    private func connectionProperties(_ connection: Connection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("From: \(board.notes.first(where: { $0.id == connection.from })?.text ?? connection.from)").lineLimit(2)
            Text("To: \(board.notes.first(where: { $0.id == connection.to })?.text ?? connection.to)").lineLimit(2)
            TextField("Relationship label", text: $label)
            Picker("Direction", selection: $direction) {
                Text("One-way →").tag(ConnectionDirection.oneWay)
                Text("Two-way ↔").tag(ConnectionDirection.twoWay)
                Text("No arrow").tag(ConnectionDirection.none)
            }
            strokeControls
        }
    }

    private var boardProperties: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("NAME").font(.caption.bold()).foregroundStyle(.secondary)
            TextField("Board name", text: $title)
            Divider()
            Text("\(board.notes.count) notes · \(board.connections.count) connections")
                .font(.caption).foregroundStyle(.secondary)
            if !model.history.isEmpty {
                Text("RECENT ACTIVITY").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(model.history.suffix(8).reversed().enumerated()), id: \.offset) { _, change in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(change.actor).font(.caption.bold())
                        Text("Revision \(change.revision) · \(change.date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            Text("Double-click a note or group title to edit it on the canvas. Double-click empty canvas to add a note; click empty canvas to close this panel.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    var geometryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("POSITION & SIZE").font(.caption.bold()).foregroundStyle(.secondary)
            HStack { numeric("X", $x); numeric("Y", $y) }
            HStack { numeric("W", $width); numeric("H", $height) }
        }
    }

    var imageAttachmentControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(imagePath.isEmpty ? "Attach image…" : "Replace image…", systemImage: "photo", action: chooseImageLocation)
                if !imagePath.isEmpty {
                    Button("Remove", role: .destructive) { imagePath = "" }
                }
            }
            if !imagePath.isEmpty {
                Text(imagePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(imagePath)
                imageAttachmentPreview
            }
        }
    }

    @ViewBuilder
    var imageAttachmentPreview: some View {
        if let image = NSImage(contentsOfFile: imagePath) {
            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Label("Image file not found", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
        }
    }

    func numeric(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder)
        }
    }

    var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FILL COLOR").font(.caption.bold()).foregroundStyle(.secondary)
            ColorPicker("Custom fill", selection: colorBinding($color), supportsOpacity: false)
            HStack(spacing: 7) {
                ForEach(["#FFF1AF", "#F9D8D5", "#DCECE9", "#DAE7F8", "#E8DDF3", "#FFFFFF"], id: \.self) { shade in
                    Button { color = shade } label: {
                        Circle().fill(Color(hex: shade)).frame(width: 23, height: 23)
                            .overlay(Circle().stroke(color == shade ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: color == shade ? 2 : 1))
                    }.buttonStyle(.plain).help(shade)
                }
            }
        }
    }

    func colorBinding(_ value: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: value.wrappedValue) }, set: { newColor in
            guard let rgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
            value.wrappedValue = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }

    var strokeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(connection == nil ? "BORDER" : "LINE").font(.caption.bold()).foregroundStyle(.secondary)
            ColorPicker("Color", selection: colorBinding($strokeColor), supportsOpacity: false)
            HStack {
                Text("Width")
                Slider(value: $strokeWidth, in: 0...12, step: 0.5)
                Text(strokeWidth.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 28)
            }
            Picker("Style", selection: $strokeStyle) {
                Text("Solid").tag(LineStyle.solid)
                Text("Dashed").tag(LineStyle.dashed)
                Text("Dotted").tag(LineStyle.dotted)
            }.pickerStyle(.segmented)
        }
    }

    private func strokeChanged(_ color: String?, _ width: Double?, _ style: LineStyle?, defaultStyle: LineStyle = .solid) -> Bool {
        strokeColor != (color ?? "#6F7785") || strokeWidth != (width ?? 1) || strokeStyle != (style ?? defaultStyle)
    }

    private var hasDraft: Bool {
        if let b = baselineNote { return text != b.text || imagePath != (b.imagePath ?? "") || color != b.color || x != b.x || y != b.y || max(80, width) != b.width || max(50, height) != b.height || strokeChanged(b.strokeColor, b.strokeWidth, b.strokeStyle) }
        if let b = baselineGroup { return text != b.title || color != b.color || x != b.x || y != b.y || max(80, width) != b.width || max(50, height) != b.height || strokeChanged(b.strokeColor, b.strokeWidth, b.strokeStyle, defaultStyle: .dashed) }
        if let b = baselineConnection { return direction != b.effectiveDirection || label != (b.label ?? "") || strokeChanged(b.strokeColor, b.strokeWidth, b.strokeStyle) }
        return title != baselineTitle
    }

    func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        guard hasDraft else { saveStatus = "Saved"; return }
        model.draftBlocked = false
        saveStatus = "Saving…"
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            savePending()
        }
    }

    func savePending() {
        saveTask?.cancel()
        guard !isLoading, let current = model.board, current.id == board.id, current.id == baselineBoardID else { return }
        guard hasDraft else { saveStatus = "Saved"; return }
        if let baseline = baselineNote {
            guard let latest = current.notes.first(where: { $0.id == baseline.id }) else { blockDraft("The note was deleted elsewhere."); return }
            let changed = text != baseline.text || imagePath != (baseline.imagePath ?? "") || color != baseline.color || x != baseline.x || y != baseline.y || max(80, width) != baseline.width || max(50, height) != baseline.height || strokeChanged(baseline.strokeColor, baseline.strokeWidth, baseline.strokeStyle)
            guard changed else { saveStatus = "Saved"; return }
            guard latest == baseline else { blockDraft("The note changed elsewhere."); return }
            if model.mutate({ board in
                guard let i = board.notes.firstIndex(where: { $0.id == baseline.id }) else { return }
                if let group = board.groupContaining(noteID: baseline.id) {
                    _ = board.moveGroup(id: group.id, dx: x - baseline.x, dy: y - baseline.y)
                } else { board.notes[i].x = x; board.notes[i].y = y }
                board.notes[i].text = text
                board.notes[i].imagePath = imagePath.isEmpty ? nil : imagePath
                board.notes[i].width = max(80, width); board.notes[i].height = max(50, height); board.notes[i].color = color
                board.notes[i].strokeColor = strokeColor; board.notes[i].strokeWidth = strokeWidth; board.notes[i].strokeStyle = strokeStyle
            }) {
                baselineNote = model.board?.notes.first(where: { $0.id == baseline.id })
                if let saved = baselineNote { x = saved.x; y = saved.y }
                saveStatus = "Saved"
            }
            else { model.draftBlocked = true; saveStatus = "Not saved" }
        } else if let baseline = baselineGroup {
            guard let latest = current.groups.first(where: { $0.id == baseline.id }) else { blockDraft("The group was deleted elsewhere."); return }
            let changed = text != baseline.title || color != baseline.color || x != baseline.x || y != baseline.y || max(80, width) != baseline.width || max(50, height) != baseline.height || strokeChanged(baseline.strokeColor, baseline.strokeWidth, baseline.strokeStyle, defaultStyle: .dashed)
            guard changed else { saveStatus = "Saved"; return }
            guard latest == baseline else { blockDraft("The group changed elsewhere."); return }
            if model.mutate({ board in
                guard let i = board.groups.firstIndex(where: { $0.id == baseline.id }) else { return }
                _ = board.moveGroup(id: baseline.id, dx: x - baseline.x, dy: y - baseline.y)
                board.groups[i].title = text
                board.groups[i].width = max(80, width); board.groups[i].height = max(50, height); board.groups[i].color = color
                board.groups[i].strokeColor = strokeColor; board.groups[i].strokeWidth = strokeWidth; board.groups[i].strokeStyle = strokeStyle
            }) {
                baselineGroup = model.board?.groups.first(where: { $0.id == baseline.id })
                if let saved = baselineGroup { x = saved.x; y = saved.y }
                saveStatus = "Saved"
            }
            else { model.draftBlocked = true; saveStatus = "Not saved" }
        } else if let baseline = baselineConnection {
            guard let latest = current.connections.first(where: { $0.id == baseline.id }) else { blockDraft("The connection was deleted elsewhere."); return }
            guard direction != baseline.effectiveDirection || label != (baseline.label ?? "") || strokeChanged(baseline.strokeColor, baseline.strokeWidth, baseline.strokeStyle) else { saveStatus = "Saved"; return }
            guard latest == baseline else { blockDraft("The connection changed elsewhere."); return }
            if model.mutate({ board in
                guard let i = board.connections.firstIndex(where: { $0.id == baseline.id }) else { return }
                board.connections[i].arrow = direction != .none
                board.connections[i].direction = direction
                board.connections[i].label = label.isEmpty ? nil : label
                board.connections[i].strokeColor = strokeColor
                board.connections[i].strokeWidth = strokeWidth; board.connections[i].strokeStyle = strokeStyle
            }) { baselineConnection = model.board?.connections.first(where: { $0.id == baseline.id }); saveStatus = "Saved" }
            else { model.draftBlocked = true; saveStatus = "Not saved" }
        } else if current.title != title {
            switch BoardTitleDraft.decision(baseline: baselineTitle, draft: title, current: current.title) {
            case .unchanged: saveStatus = "Saved"; return
            case .invalid: blockDraft("A board needs a name."); return
            case .conflict: blockDraft("The board name changed elsewhere."); return
            case .save: break
            }
            if model.mutate({ $0.title = title }) { baselineTitle = title; saveStatus = "Saved" }
            else { model.draftBlocked = true; saveStatus = "Not saved" }
        } else { saveStatus = "Saved" }
    }

    func blockDraft(_ message: String) {
        if !model.draftBlocked { model.error = "\(message) Your draft is still here. Copy it if needed, then select Reload to discard it." }
        model.draftBlocked = true
        saveStatus = "Not saved"
    }

    func loadSelection() {
        model.draftBlocked = false
        saveTask?.cancel()
        isLoading = true
        defer { isLoading = false; saveStatus = "Saved" }
        baselineBoardID = board.id
        title = board.title; baselineTitle = board.title; baselineNote = note; baselineGroup = group; baselineConnection = connection
        if let note {
            text = note.text; imagePath = note.imagePath ?? ""; color = note.color; x = note.x; y = note.y; width = note.width; height = note.height
            strokeColor = note.strokeColor ?? "#6F7785"; strokeWidth = note.strokeWidth ?? 1; strokeStyle = note.strokeStyle ?? .solid
        } else if let group {
            text = group.title; color = group.color; x = group.x; y = group.y; width = group.width; height = group.height
            strokeColor = group.strokeColor ?? "#6F7785"; strokeWidth = group.strokeWidth ?? 1; strokeStyle = group.strokeStyle ?? .dashed
        } else if let connection {
            direction = connection.effectiveDirection; label = connection.label ?? ""; strokeColor = connection.strokeColor ?? "#6F7785"
            strokeWidth = connection.strokeWidth ?? 1; strokeStyle = connection.strokeStyle ?? .solid
        }
    }

    private func chooseImageLocation() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsOtherFileTypes = false
        open.canChooseFiles = true
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        open.prompt = "Choose Image"
        guard open.runModal() == .OK, let source = open.url else { return }

        let save = NSSavePanel()
        save.allowedContentTypes = [.image]
        save.canCreateDirectories = true
        save.nameFieldStringValue = source.lastPathComponent
        save.directoryURL = source.deletingLastPathComponent()
        save.prompt = "Store Image"
        guard save.runModal() == .OK, let destination = save.url else { return }

        do {
            if source.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            imagePath = destination.path
        } catch {
            model.error = "Could not store the image. \(error.localizedDescription)"
        }
    }
}
