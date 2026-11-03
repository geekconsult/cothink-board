import SwiftUI
import BoardCore

private let organizationColors: [(String, String)] = [("Gray", "#7A8BA8"), ("Red", "#E35D5D"), ("Orange", "#E89B50"), ("Yellow", "#E8C353"), ("Green", "#68AD83"), ("Blue", "#669AD2"), ("Purple", "#A080C7")]

struct ListManagerView: View {
    @ObservedObject var model: BoardViewModel
    let initialListID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draft: BoardList?
    @State private var baseline: BoardList?
    @State private var tags = ""
    @State private var deletionTarget: BoardList?
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var confirmSwitch = false
    @State private var pendingSelection: String?
    @State private var pendingCreate = false

    private var hasChanges: Bool {
        guard let draft, let baseline else { return false }
        return draft != baseline || tags != baseline.tags.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Manage Lists").font(.headline)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close list manager")
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Lists").font(.headline)
                        Spacer()
                        Button { requestCreate() } label: { Image(systemName: "plus") }
                            .help("New list").accessibilityLabel("New list")
                    }
                    if model.boardLists.isEmpty {
                        Text("No lists yet. Use + to create one.").font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.boardLists) { list in
                                HStack(spacing: 4) {
                                    Button { requestSelection(list.id) } label: {
                                        HStack {
                                            Image(systemName: "folder")
                                            Text(list.title).lineLimit(1)
                                            if list.flagged { Image(systemName: "flag.fill").font(.caption) }
                                            Spacer(minLength: 0)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("Edit list \(list.title)")
                                    Menu {
                                        Button("Rename or Edit…") { requestSelection(list.id) }
                                        Button("Delete List…", role: .destructive) { requestDelete(list) }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                        .menuStyle(.borderlessButton).fixedSize()
                                        .help("Rename or delete \(list.title)")
                                        .accessibilityLabel("Actions for \(list.title)")
                                }.padding(8)
                                    .background(selectedID == list.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }.frame(width: 215).padding()
                Divider()
                if draft != nil {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("List details").font(.title3.bold())
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("List name").font(.caption.bold()).foregroundStyle(.secondary)
                                    TextField("List name", text: binding(\.title)).textFieldStyle(.roundedBorder)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Description").font(.caption.bold()).foregroundStyle(.secondary)
                                    TextField("Describe this list", text: binding(\.description), axis: .vertical)
                                        .textFieldStyle(.roundedBorder).lineLimit(3...6)
                                }
                                TextField("Tags (comma separated)", text: $tags).textFieldStyle(.roundedBorder)
                                Toggle("Flagged", isOn: binding(\.flagged))
                                Picker("Color", selection: binding(\.color)) { ForEach(organizationColors, id: \.1) { Text($0.0).tag($0.1) } }
                                Text("Boards").font(.headline)
                                if model.boards.isEmpty { Text("No boards available.").foregroundStyle(.secondary) }
                                ForEach(model.boards) { board in
                                    Toggle(board.title, isOn: Binding(get: { draft?.boardIDs.contains(board.id) == true }, set: { enabled in
                                        guard var updated = draft else { return }
                                        if enabled { if !updated.boardIDs.contains(board.id) { updated.boardIDs.append(board.id) } }
                                        else { updated.boardIDs.removeAll { $0 == board.id } }
                                        draft = updated
                                    }))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        }
                        Divider()
                        HStack {
                            Button("Delete List…", role: .destructive) { if let baseline { requestDelete(baseline) } }
                            Spacer()
                            Button("Save Changes") { _ = save() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(!hasChanges || (draft?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
                        }.padding(16)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Select a list to rename or edit it.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { select(initialListID ?? model.boardLists.first?.id) }
        .confirmationDialog("Delete this list?", isPresented: $confirmDelete) {
            Button("Delete List", role: .destructive) {
                guard let target = deletionTarget, model.deleteList(target) else { return }
                if selectedID == target.id { select(model.boardLists.first?.id) }
                deletionTarget = nil
            }
        } message: { Text("The list will be deleted. Its boards will remain available.") }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Save changes before switching lists?", isPresented: $confirmSwitch) {
            Button("Save and Continue") { if save() { performPendingAction() } }
            Button("Discard Changes", role: .destructive) { performPendingAction() }
            Button("Cancel", role: .cancel) { pendingSelection = nil; pendingCreate = false }
        }
    }

    private func select(_ id: String?) {
        selectedID = id
        draft = model.boardLists.first { $0.id == id }
        baseline = draft
        tags = draft?.tags.joined(separator: ", ") ?? ""
    }
    private func save() -> Bool {
        guard var updated = draft else { return false }
        updated.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard model.saveList(updated) else { return false }
        select(updated.id)
        return true
    }
    private func requestSelection(_ id: String) {
        guard selectedID != id else { return }
        if hasChanges { pendingSelection = id; pendingCreate = false; confirmSwitch = true }
        else { select(id) }
    }
    private func requestCreate() {
        if hasChanges { pendingSelection = nil; pendingCreate = true; confirmSwitch = true }
        else if let created = model.createList() { select(created.id) }
    }
    private func performPendingAction() {
        if pendingCreate { if let created = model.createList() { select(created.id) } }
        else if let id = pendingSelection { select(id) }
        pendingSelection = nil; pendingCreate = false
    }
    private func requestDelete(_ list: BoardList) {
        deletionTarget = selectedID == list.id ? (baseline ?? list) : list
        confirmDelete = true
    }
    private func close() {
        if hasChanges { confirmDiscard = true } else { dismiss() }
    }
    private func binding<T>(_ keyPath: WritableKeyPath<BoardList, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: keyPath] }, set: { draft?[keyPath: keyPath] = $0 })
    }
}

struct BoardSettingsView: View {
    @ObservedObject var model: BoardViewModel
    @Environment(\.dismiss) private var dismiss
    let board: Board
    @State private var title: String
    @State private var tags: String
    @State private var flagged: Bool
    @State private var color: String
    init(model: BoardViewModel, board: Board) {
        self.model = model; self.board = board
        _title = State(initialValue: board.title); _tags = State(initialValue: (board.tags ?? []).joined(separator: ", "))
        _flagged = State(initialValue: board.flagged ?? false); _color = State(initialValue: board.color ?? "#7A8BA8")
    }
    var body: some View {
        Form {
            Text("Board settings").font(.headline)
            TextField("Name", text: $title)
            TextField("Tags (comma separated)", text: $tags)
            Toggle("Flagged", isOn: $flagged)
            Picker("Color", selection: $color) { ForEach(organizationColors, id: \.1) { Text($0.0).tag($0.1) } }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") {
                guard model.board?.id == board.id else { return }
                var updated = board
                updated.title = title; updated.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }; updated.flagged = flagged; updated.color = color
                if model.saveBoardSettings(updated) { dismiss() }
            }.keyboardShortcut(.defaultAction) }
        }.padding(24)
    }
}
