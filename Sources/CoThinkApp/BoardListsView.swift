import SwiftUI
import BoardCore

private let organizationColors: [(String, String)] = [("Gray", "#7A8BA8"), ("Red", "#E35D5D"), ("Orange", "#E89B50"), ("Yellow", "#E8C353"), ("Green", "#68AD83"), ("Blue", "#669AD2"), ("Purple", "#A080C7")]

struct ListManagerView: View {
    @ObservedObject var model: BoardViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var draft: BoardList?
    @State private var tags = ""
    @State private var confirmDelete = false
    @State private var confirmDiscard = false

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
            VStack {
                HStack { Text("Lists").font(.headline); Spacer(); Button { model.createList() } label: { Image(systemName: "plus") }.help("New list") }
                List(selection: $selectedID) {
                    ForEach(model.boardLists) { list in
                        HStack { Label(list.title, systemImage: "folder"); if list.flagged { Image(systemName: "flag.fill").font(.caption) } }.tag(list.id)
                    }
                }
            }.frame(width: 200).padding()
            Divider()
            if let list = draft {
                Form {
                    TextField("Name", text: binding(\.title))
                    TextField("Description", text: binding(\.description), axis: .vertical).lineLimit(3...6)
                    TextField("Tags (comma separated)", text: $tags)
                    Toggle("Flagged", isOn: binding(\.flagged))
                    Picker("Color", selection: binding(\.color)) { ForEach(organizationColors, id: \.1) { Text($0.0).tag($0.1) } }
                    Text("Boards").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading) {
                            ForEach(model.boards) { board in
                                Toggle(board.title, isOn: Binding(get: { draft?.boardIDs.contains(board.id) == true }, set: { enabled in
                                    guard var updated = draft else { return }
                                    if enabled { if !updated.boardIDs.contains(board.id) { updated.boardIDs.append(board.id) } }
                                    else { updated.boardIDs.removeAll { $0 == board.id } }
                                    draft = updated
                                }))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 100)
                    HStack {
                        Button("Delete List", role: .destructive) { confirmDelete = true }
                        Spacer()
                        Button("Save") {
                            var updated = list
                            updated.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                            if model.saveList(updated) { draft = model.boardLists.first { $0.id == updated.id } }
                        }.keyboardShortcut(.defaultAction)
                    }
                }.padding()
            } else { Text("Select a list or create one.").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
        }
        .onChange(of: selectedID) { _, id in draft = model.boardLists.first { $0.id == id }; tags = draft?.tags.joined(separator: ", ") ?? "" }
        .confirmationDialog("Delete this list? Boards will remain available.", isPresented: $confirmDelete) {
            Button("Delete List", role: .destructive) { if let draft { model.deleteList(draft) }; selectedID = nil; draft = nil }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
        }
    }

    private func close() {
        if let draft, let saved = model.boardLists.first(where: { $0.id == draft.id }),
           draft != saved || tags != saved.tags.joined(separator: ", ") {
            confirmDiscard = true
        } else { dismiss() }
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
