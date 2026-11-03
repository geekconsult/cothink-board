import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import BoardCore

@main
struct CoThinkApp: App {
    @StateObject private var model = BoardViewModel()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.addNote() }.keyboardShortcut("n", modifiers: .command).disabled(model.board == nil)
                Button("New Board") { model.createBoard() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Board") {
                Button("Group Selection or Draw Group") { NotificationCenter.default.post(name: .createGroupCommand, object: nil) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.board == nil)
                Button("Connect Selected Note") { model.beginConnection() }.keyboardShortcut("l", modifiers: .command).disabled(model.selectedNoteID == nil)
                Button("Delete Selection") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(!model.hasSelection)
                Button("Change Wallpaper…") { NotificationCenter.default.post(name: .wallpaperCommand, object: nil) }.disabled(model.board == nil)
                Divider()
                Button("Export Board…") { model.exportBoard() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.board == nil)
                Button("Export Board as PDF…") { NotificationCenter.default.post(name: .exportPDFCommand, object: nil) }.disabled(model.board == nil)
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Board Change") { model.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("Redo Board Change") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                Button("Zoom In") { NotificationCenter.default.post(name: .zoomInCommand, object: nil) }.keyboardShortcut("+", modifiers: .command).disabled(model.board == nil)
                Button("Zoom Out") { NotificationCenter.default.post(name: .zoomOutCommand, object: nil) }.keyboardShortcut("-", modifiers: .command).disabled(model.board == nil)
                Divider()
                Button("Actual Size") { NotificationCenter.default.post(name: .zoomResetCommand, object: nil) }.keyboardShortcut("0", modifiers: .command).disabled(model.board == nil)
            }
        }
    }
}

@MainActor
final class BoardViewModel: ObservableObject {
    @Published var boards: [Board] = []
    @Published var boardLists: [BoardList] = []
    @Published var history: [Change] = []
    @Published var draftBlocked = false
    @Published var board: Board?
    @Published var selectedNoteID: String?
    @Published var selectedNoteIDs: Set<String> = []
    var hasSelection: Bool { selectedNoteID != nil || !selectedNoteIDs.isEmpty || selectedGroupID != nil || selectedConnectionID != nil }
    @Published var selectedGroupID: String?
    @Published var selectedConnectionID: String?
    @Published var connectingFrom: String?
    @Published var error: String?
    private var store: BoardStore?

    init() {
        do {
            store = try BoardStore()
            try refresh()
            if boards.isEmpty { createBoard() }
            else if let first = boards.first { selectBoard(first.id) }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() throws {
        guard let store else { return }
        boards = try store.list()
        boardLists = try store.lists()
        if let current = board {
            if boards.contains(where: { $0.id == current.id }) {
                let updated = try store.get(current.id)
                if updated.revision != current.revision { board = updated }
                history = try store.history(current.id)
            } else {
                board = nil
                clearSelection()
            }
        }
    }

    func poll() {
        do { try refresh() } catch { self.error = error.localizedDescription }
    }

    func defaultProjectFilesDirectory(for boardID: String) -> URL {
        if let store { return store.defaultProjectFilesDirectory(for: boardID) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoThinkBoard/Projects", isDirectory: true)
            .appendingPathComponent(boardID, isDirectory: true)
    }

    func selectBoard(_ id: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        do { board = try store?.get(id); history = try store?.history(id) ?? []; clearSelection() }
        catch { self.error = error.localizedDescription }
    }

    func createBoard() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        do {
            guard let store else { return }
            let created = try store.create(title: "Untitled board", actor: "user")
            try refresh()
            board = created
            history = try store.history(created.id)
            clearSelection()
        } catch { self.error = error.localizedDescription }
    }

    func deleteBoard() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        guard let current = board else { return }
        do {
            try store?.delete(current.id, expectedRevision: current.revision)
            board = nil
            clearSelection()
            try refresh()
            if let first = boards.first { selectBoard(first.id) }
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func createList() -> BoardList? {
        do { guard let store else { return nil }; let created = try store.createList(title: "Untitled list"); try refresh(); return created }
        catch { self.error = error.localizedDescription; return nil }
    }
    func saveList(_ list: BoardList) -> Bool {
        do { _ = try store?.replaceList(list, expectedRevision: list.revision); try refresh(); return true }
        catch { self.error = error.localizedDescription; try? refresh(); return false }
    }
    @discardableResult
    func deleteList(_ list: BoardList) -> Bool {
        do { guard let store else { return false }; try store.deleteList(list.id, expectedRevision: list.revision); try refresh(); return true }
        catch { self.error = error.localizedDescription; try? refresh(); return false }
    }
    func saveBoardSettings(_ updated: Board) -> Bool {
        do {
            guard let store else { return false }
            board = try store.replace(updated, expectedRevision: updated.revision, actor: "user")
            try refresh(); return true
        } catch { self.error = error.localizedDescription; try? refresh(); return false }
    }

    @discardableResult
    func mutate(_ edit: (inout Board) -> Void) -> Bool {
        guard let current = board, let store else { return false }
        var changed = current
        edit(&changed)
        do {
            board = try store.replace(changed, expectedRevision: current.revision, actor: "user")
            boards = try store.list()
            history = try store.history(changed.id)
            return true
        } catch {
            self.error = "Could not save the change. The board may have changed elsewhere. \(error.localizedDescription)"
            poll()
            return false
        }
    }

    func addNote(x: Double = 500, y: Double = 300) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        let id = UUID().uuidString
        mutate { $0.notes.append(Note(id: id, text: "New idea", x: x, y: y, width: 190, height: 100, color: "#FFF1AF")) }
        selectedNoteID = id
        selectedNoteIDs = []
        selectedGroupID = nil
        selectedConnectionID = nil
    }

    func addGroup() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        let id = UUID().uuidString
        mutate { $0.groups.append(BoardGroup(id: id, title: "Group", x: 350, y: 200, width: 500, height: 320, color: "#DCECE9")) }
        selectedGroupID = id
        selectedNoteIDs = []
        selectedNoteID = nil
        selectedConnectionID = nil
    }

    func createGroup(in rect: BoardRect, selectedMembers: Set<String>? = nil) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board else { return }
        let members = current.notes.filter { selectedMembers?.contains($0.id) ?? rect.containsCenter(of: $0) }.map(\.id)
        var group = BoardGroup(title: "Group", x: rect.x, y: rect.y, width: max(80, rect.width), height: max(50, rect.height), color: "#DCECE9")
        group.memberIDs = members
        if mutate({ board in
            for i in board.groups.indices { board.groups[i].memberIDs?.removeAll { members.contains($0) } }
            board.groups.append(group)
        }) {
            selectedGroupID = group.id; selectedNoteID = nil; selectedNoteIDs = []; selectedConnectionID = nil
        }
    }

    func selectNotes(in rect: BoardRect) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board else { return }
        selectedNoteIDs = Set(current.notes.filter { rect.containsCenter(of: $0) }.map(\.id))
        selectedNoteID = nil; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
    }

    func groupSelectedNotes() {
        guard let board, !selectedNoteIDs.isEmpty else { return }
        let notes = board.notes.filter { selectedNoteIDs.contains($0.id) }
        guard let first = notes.first else { return }
        let minX = notes.map(\.x).min() ?? first.x, minY = notes.map(\.y).min() ?? first.y
        let maxX = notes.map { $0.x + $0.width }.max() ?? first.x + first.width
        let maxY = notes.map { $0.y + $0.height }.max() ?? first.y + first.height
        let left = max(0, minX - 24), top = max(0, minY - 36)
        createGroup(in: BoardRect(x: left, y: top, width: maxX - left + 24, height: maxY - top + 24), selectedMembers: selectedNoteIDs)
    }

    func lockNotes(in groupID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board, let group = current.groups.first(where: { $0.id == groupID }) else { return }
        let rect = BoardRect(x: group.x, y: group.y, width: group.width, height: group.height)
        let members = current.notes.filter { rect.containsCenter(of: $0) }.map(\.id)
        mutate { board in
            for i in board.groups.indices {
                if board.groups[i].id == groupID { board.groups[i].memberIDs = members }
                else { board.groups[i].memberIDs?.removeAll { members.contains($0) } }
            }
        }
    }

    func unlockNote(_ id: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, board?.groupContaining(noteID: id) != nil else { return }
        mutate { _ = $0.unlockNote(id: id) }
    }

    func lockNote(_ id: String, to groupID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board, current.notes.contains(where: { $0.id == id }),
              current.groups.contains(where: { $0.id == groupID }), current.groupContaining(noteID: id)?.id != groupID else { return }
        mutate { _ = $0.lockNote(id: id, toGroup: groupID) }
    }

    func beginConnection() {
        guard let id = selectedNoteID else { return }
        connectingFrom = connectingFrom == id ? nil : id
    }

    func connect(from: String, to: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, from != to, let current = board,
              current.notes.contains(where: { $0.id == from }), current.notes.contains(where: { $0.id == to }) else { return }
        if !current.connections.contains(where: { $0.from == from && $0.to == to }) {
            _ = mutate { $0.connections.append(Connection(from: from, to: to)) }
        }
        connectingFrom = nil
    }

    func chooseNote(_ id: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        if let from = connectingFrom, from != id {
            connect(from: from, to: id)
        }
        selectedNoteID = id
        selectedNoteIDs = []
        selectedGroupID = nil
        selectedConnectionID = nil
    }

    func chooseGroup(_ id: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        selectedGroupID = id; selectedNoteID = nil; selectedNoteIDs = []; selectedConnectionID = nil
    }

    func deleteSelection() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        var notes = selectedNoteIDs
        if let note = selectedNoteID { notes.insert(note) }
        let group = selectedGroupID, connection = selectedConnectionID
        guard !notes.isEmpty || group != nil || connection != nil else { return }
        mutate { board in
            if !notes.isEmpty {
                board.notes.removeAll { notes.contains($0.id) }
                board.connections.removeAll { notes.contains($0.from) || notes.contains($0.to) }
                for i in board.groups.indices { board.groups[i].memberIDs?.removeAll { notes.contains($0) } }
            }
            if let group { board.groups.removeAll { $0.id == group } }
            if let connection { board.connections.removeAll { $0.id == connection } }
        }
        clearSelection()
    }

    func clearSelection() {
        selectedNoteID = nil; selectedNoteIDs = []; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
    }

    func undo() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        guard let current = board else { return }
        do { board = try store?.undo(current.id, actor: "user", expectedRevision: current.revision); try refresh() }
        catch { self.error = error.localizedDescription }
    }

    func redo() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        guard let current = board else { return }
        do { board = try store?.redo(current.id, actor: "user", expectedRevision: current.revision); try refresh() }
        catch { self.error = error.localizedDescription }
    }

    func exportBoard() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        guard let board else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(board.title).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(board).write(to: url, options: .atomic)
        } catch { self.error = error.localizedDescription }
    }

    func importBoard() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try JSONDecoder().decode(Board.self, from: Data(contentsOf: url))
            board = try store?.importBoard(imported, actor: "user")
            try refresh()
            clearSelection()
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: BoardViewModel
    @AppStorage("showBoardSidebar") private var showBoardSidebar = true
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoom = 1.0
    @State private var pinchMagnification: CGFloat = 1
    @State private var search = ""
    @State private var editingObjectID: String?
    @State private var editingGroupTitle = false
    @State private var inlineText = ""
    @State private var inlineSaveTask: Task<Void, Never>?
    @State private var showingDeleteBoard = false
    @State private var showingMCP = false
    @State private var showingProjectFiles = false
    @State private var wallpaperBoard: Board?
    @State private var pdfExportBoard: Board?
    @State private var showingListManager = false
    @State private var editingListID: String?
    @State private var listToDelete: BoardList?
    @State private var showingDeleteList = false
    @State private var showingBoardSettings = false
    @State private var draggingID: String?
    @State private var draggingSelection = false
    @State private var viewport = CGRect.zero
    @State private var scrollRequest: CGPoint?
    @State private var dragTranslation: CGSize = .zero
    @State private var resizeState: ResizeState?
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var connectionDrag: ConnectionDrag?
    @State private var routePointDrag: RoutePointDrag?
    @State private var drawingGroup = false
    @FocusState private var canvasFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            toolbar(model.board)
            Divider()
            HSplitView {
                if showBoardSidebar {
                    sidebar.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                }
                if let board = model.board {
                    boardCanvas(board).frame(minWidth: 400)
                    if showInspector {
                        InspectorView(model: model, board: board)
                            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").font(.largeTitle)
                        Text("No board selected").font(.title2)
                        Text("Create or import a board to begin.").foregroundStyle(.secondary)
                        if !showBoardSidebar {
                            Button("Show boards") { toggleSidebar() }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(workspaceBackground)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .tint(colorScheme == .dark
              ? Color(red: 1.0, green: 0.71, blue: 0.54)
              : Color(red: 0.58, green: 0.25, blue: 0.13))
        .onReceive(timer) { _ in model.poll() }
        .onReceive(NotificationCenter.default.publisher(for: .createGroupCommand)) { _ in requestGroup() }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectFiles)) { _ in openProjectFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperCommand)) { _ in openWallpaper() }
        .onReceive(NotificationCenter.default.publisher(for: .exportPDFCommand)) { _ in openPDFExport() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomInCommand)) { _ in zoomStep(1) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOutCommand)) { _ in zoomStep(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomResetCommand)) { _ in zoom = 1.0 }
        .onExitCommand { model.connectingFrom = nil; selectionStart = nil; selectionEnd = nil; connectionDrag = nil; drawingGroup = false }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete this board?", isPresented: $showingDeleteBoard) {
            Button("Delete Board", role: .destructive) { model.deleteBoard() }
        } message: { Text("This removes the board and its history from this Mac.") }
        .confirmationDialog("Delete this list?", isPresented: $showingDeleteList) {
            Button("Delete List", role: .destructive) { if let list = listToDelete { model.deleteList(list) }; listToDelete = nil }
        } message: { Text("Boards in the list will remain available.") }
        .sheet(isPresented: $showingProjectFiles) {
            if let board = model.board {
                ProjectFilesView(model: model, boardID: board.id)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .sheet(isPresented: $showingListManager) { ListManagerView(model: model, initialListID: editingListID).frame(minWidth: 650, minHeight: 470) }
        .sheet(isPresented: $showingBoardSettings) { if let board = model.board { BoardSettingsView(model: model, board: board).frame(width: 450) } }
        .sheet(item: $wallpaperBoard) { board in WallpaperSettingsView(model: model, board: board) }
        .sheet(item: $pdfExportBoard) { board in
            PDFExportView(board: board, projectFolder: board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model.defaultProjectFilesDirectory(for: board.id))
        }
    }

    var workspaceBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.10, green: 0.12, blue: 0.17), Color(red: 0.16, green: 0.13, blue: 0.16)]
                : [Color(red: 0.97, green: 0.95, blue: 0.92), Color(red: 0.89, green: 0.93, blue: 0.94)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ).ignoresSafeArea()
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MascotLogo().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CoThink").font(.headline)
                    Text("Your boards").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editingListID = nil; showingListManager = true } label: { Image(systemName: "folder.badge.gearshape") }.help("Create, rename, or delete lists")
                Button(action: model.createBoard) { Image(systemName: "plus") }.help("New board")
            }.padding(18)
            TextField("Search boards and notes", text: $search)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 8)
            List(selection: Binding(get: { model.board?.id }, set: { if let id = $0 { model.selectBoard(id) } })) {
                ForEach(model.boardLists) { list in
                    Section {
                        ForEach(model.boards.filter { list.boardIDs.contains($0.id) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.notes.contains(where: { $0.text.localizedCaseInsensitiveContains(search) })) }) { board in
                            boardSidebarLabel(board).tag(board.id)
                        }
                    } header: {
                        HStack {
                            Label(list.title, systemImage: "folder")
                            if list.flagged { Image(systemName: "flag.fill") }
                            Spacer()
                            Menu {
                                Button("Rename or Edit…") { editingListID = list.id; showingListManager = true }
                                Button("Delete List…", role: .destructive) { listToDelete = list; showingDeleteList = true }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().help("Edit or delete \(list.title)")
                                .accessibilityLabel("Actions for \(list.title)")
                        }.foregroundStyle(Color(hex: list.color)).help(list.description)
                    }
                }
                Section("All boards") {
                ForEach(model.boards.filter { board in
                    search.isEmpty || board.title.localizedCaseInsensitiveContains(search) || (board.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(search) }) || board.notes.contains(where: { $0.text.localizedCaseInsensitiveContains(search) })
                }) { board in
                    boardSidebarLabel(board).tag(board.id)
                }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Import", systemImage: "square.and.arrow.down", action: model.importBoard)
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                    if !model.draftBlocked { showingBoardSettings = true }
                } label: { Image(systemName: "slider.horizontal.3") }.disabled(model.board == nil).help("Board settings")
                Button { showingDeleteBoard = true } label: { Image(systemName: "trash") }.disabled(model.board == nil).help("Delete board")
            }.padding(14)
        }.background(.regularMaterial)
    }

    func boardSidebarLabel(_ board: Board) -> some View {
        HStack {
            Label(board.title, systemImage: "square.grid.2x2")
            if board.flagged == true { Image(systemName: "flag.fill").font(.caption) }
        }.foregroundStyle(Color(hex: board.color ?? "#7A8BA8"))
    }

    func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showBoardSidebar.toggle()
        }
    }

    func toggleInspector() {
        if showInspector {
            NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
            guard !model.draftBlocked else { return }
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showInspector.toggle()
        }
    }

    func openProjectFiles() {
        guard model.board != nil else { return }
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        showingProjectFiles = true
    }

    func openWallpaper() {
        finishInlineEditing()
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        wallpaperBoard = model.board
    }

    func openPDFExport() {
        finishInlineEditing()
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        pdfExportBoard = model.board
    }

    func requestGroup() {
        guard model.board != nil else { return }
        if !model.selectedNoteIDs.isEmpty {
            model.groupSelectedNotes()
            drawingGroup = false
        } else {
            drawingGroup.toggle()
            canvasFocused = true
        }
    }

    func zoomStep(_ direction: Double) {
        // Round to one decimal first so repeated steps don't drift (e.g. 0.7 + 0.1 → 0.7999…)
        let base = (zoom * 10).rounded()
        zoom = min(2.0, max(0.5, (base + direction) / 10))
    }

    func toolbar(_ board: Board?) -> some View {
        HStack(spacing: 10) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .frame(width: 22, height: 24)
            }
            .help(showBoardSidebar ? "Hide boards (⌘⌥1)" : "Show boards (⌘⌥1)")
            .accessibilityLabel(showBoardSidebar ? "Hide boards" : "Show boards")
            .accessibilityValue(showBoardSidebar ? "Visible" : "Hidden")
            .keyboardShortcut("1", modifiers: [.command, .option])

            VStack(alignment: .leading, spacing: 3) {
                Text(board?.title ?? "CoThink Board").font(.headline).lineLimit(1)
                if model.connectingFrom != nil {
                    Text("Select another note to connect").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if drawingGroup {
                    Text("Drag on the canvas to draw a group · Esc to cancel").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !model.selectedNoteIDs.isEmpty {
                    Text("\(model.selectedNoteIDs.count) notes selected · Choose Group to lock them together").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)

            Button("Note", systemImage: "plus.square") { model.addNote() }.modifier(GlassControl()).help("Add a note (⌘N)").disabled(board == nil)
            Button(drawingGroup ? "Cancel group" : "Group", systemImage: "square.dashed") { requestGroup() }
                .modifier(GlassControl()).help("Group selected notes or draw a group (⇧⌘G)").disabled(board == nil)
            Button("Connect", systemImage: "arrow.up.right") {
                model.beginConnection()
            }.modifier(GlassControl()).disabled(model.selectedNoteID == nil || board == nil).help("Select a note then select another (⌘L), or drag its connection handle")
            Divider().frame(height: 24)
            Button { zoomStep(-1) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out (⌘−)").disabled(board == nil)
            Text("\(Int(zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 40).help("Pinch with the trackpad to zoom the canvas")
            Button { zoomStep(1) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in (⌘+)").disabled(board == nil)
            Menu {
                Button { appearanceMode = "system" } label: { themeLabel("System", selected: appearanceMode == "system") }
                Button { appearanceMode = "light" } label: { themeLabel("Light", selected: appearanceMode == "light") }
                Button { appearanceMode = "dark" } label: { themeLabel("Dark", selected: appearanceMode == "dark") }
            } label: {
                Image(systemName: appearanceMode == "dark" ? "moon.stars" : appearanceMode == "light" ? "sun.max" : "circle.lefthalf.filled")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .modifier(GlassControl())
            .help("Appearance: system, light or dark")
            .accessibilityLabel("Appearance")
            .accessibilityValue(appearanceMode.capitalized)
            Button("Files", systemImage: "folder", action: openProjectFiles)
                .help("Manage files for this board")
                .disabled(board == nil)
            Button(action: openWallpaper) { Image(systemName: "photo.on.rectangle.angled") }
                .help("Change board wallpaper").accessibilityLabel("Board wallpaper").disabled(board == nil)
            Button("MCP", systemImage: "point.3.connected.trianglepath.dotted") { showingMCP.toggle() }
                .help("Connect an AI agent")
                .popover(isPresented: $showingMCP) { MCPSetupView() }
            Menu {
                Button("Export as JSON…", action: model.exportBoard)
                Button("Export as PDF…", action: openPDFExport)
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().disabled(board == nil)
            Divider().frame(height: 24)
            Button(action: toggleInspector) {
                Image(systemName: "sidebar.right")
                    .frame(width: 22, height: 24)
            }
            .help(showInspector ? "Hide inspector (⌘⌥2)" : "Show inspector (⌘⌥2)")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
            .accessibilityValue(showInspector ? "Visible" : "Hidden")
            .keyboardShortcut("2", modifiers: [.command, .option])
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1) }
    }

    @ViewBuilder
    func themeLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    func boardCanvas(_ board: Board) -> some View {
        let noteRects = board.notes.map { note in
            let note = displayed(note)
            return BoardRect(x: note.x, y: note.y, width: note.width, height: note.height)
        }
        let routeRects = board.connections.flatMap { edge -> [BoardRect] in
            guard let from = board.notes.first(where: { $0.id == edge.from }), let to = board.notes.first(where: { $0.id == edge.to }) else { return [] }
            return displayedConnection(edge).controlPoints(from: displayed(from), to: displayed(to)).map { BoardRect(x: $0.x, y: $0.y, width: 0, height: 0) }
        }
        let extent = BoardRect.canvasExtent(containing: noteRects + board.groups.map { displayedGroupRect($0) } + routeRects)
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                WallpaperBackgroundView(board: board,
                                        folder: board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model.defaultProjectFilesDirectory(for: board.id),
                                        width: extent.width, height: extent.height, colorScheme: colorScheme)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        finishInlineEditing()
                        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                        guard !model.draftBlocked else { return }
                        model.clearSelection()
                        showInspector = false
                        canvasFocused = true
                    }
                    .onTapGesture(count: 2, coordinateSpace: .local) { point in
                        model.addNote(x: max(0, point.x - 95), y: max(0, point.y - 50))
                    }
                    .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("boardCanvas"))
                        .onChanged { value in
                            if selectionStart == nil {
                                finishInlineEditing()
                                NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                                guard !model.draftBlocked else { return }
                                selectionStart = value.startLocation
                            }
                            selectionEnd = value.location
                        }.onEnded { value in
                            defer { selectionStart = nil; selectionEnd = nil }
                            guard let start = selectionStart, !model.draftBlocked else { return }
                            let rect = BoardRect.selection(fromX: start.x, fromY: start.y, toX: value.location.x, toY: value.location.y)
                            guard rect.width >= 20, rect.height >= 20 else { return }
                            if drawingGroup {
                                model.createGroup(in: rect)
                                drawingGroup = false
                            } else { model.selectNotes(in: rect) }
                            canvasFocused = true
                        })
                ForEach(board.groups) { group in groupView(group) }
                ForEach(board.connections) { edge in
                    if let from = board.notes.first(where: { $0.id == edge.from }), let to = board.notes.first(where: { $0.id == edge.to }) {
                        ConnectionView(from: displayed(from), to: displayed(to), edge: displayedConnection(edge), selected: model.selectedConnectionID == edge.id, canvasWidth: extent.width, canvasHeight: extent.height)
                            .onTapGesture {
                                selectConnection(edge.id)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                selectConnection(edge.id)
                                if model.selectedConnectionID == edge.id { showInspector = true }
                            })
                    }
                }
                ForEach(board.notes) { note in noteView(note, board: board) }
                if let start = selectionStart, let end = selectionEnd {
                    let rect = BoardRect.selection(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y)
                    Rectangle().fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
                        .allowsHitTesting(false)
                }
                if let drag = connectionDrag, let source = board.notes.first(where: { $0.id == drag.source }) {
                    let start = CGPoint(x: source.x + source.width, y: source.y + source.height / 2)
                    Canvas { context, _ in
                        var path = Path(); path.move(to: start); path.addLine(to: drag.point)
                        context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }.frame(width: extent.width, height: extent.height).allowsHitTesting(false)
                }
                if let note = board.notes.first(where: { $0.id == model.selectedNoteID }) {
                    resizeHandles(id: note.id, rect: BoardRect(x: note.x, y: note.y, width: note.width, height: note.height), isNote: true)
                    connectionHandle(note, board: board)
                } else if let group = board.groups.first(where: { $0.id == model.selectedGroupID }) {
                    resizeHandles(id: group.id, rect: BoardRect(x: group.x, y: group.y, width: group.width, height: group.height), isNote: false)
                } else if let edge = board.connections.first(where: { $0.id == model.selectedConnectionID }),
                          let from = board.notes.first(where: { $0.id == edge.from }), let to = board.notes.first(where: { $0.id == edge.to }) {
                    routeHandles(edge, from: displayed(from), to: displayed(to))
                }
            }
            .frame(width: extent.width, height: extent.height)
            .background(ScrollViewportObserver(viewport: $viewport, request: $scrollRequest))
            .coordinateSpace(name: "boardCanvas")
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: extent.width * zoom, height: extent.height * zoom, alignment: .topLeading)
        }
        .overlay(alignment: .bottomTrailing) {
            BoardMinimap(board: board, extent: CGSize(width: extent.width, height: extent.height), zoom: zoom, viewport: viewport) { scrollRequest = $0 }
                .padding(14)
        }
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onDeleteCommand {
            guard !(NSApp.keyWindow?.firstResponder is NSTextView), !(NSApp.keyWindow?.firstResponder is NSTextField) else { return }
            model.deleteSelection()
        }
        .simultaneousGesture(MagnificationGesture()
            .onChanged { value in
                let factor = value / pinchMagnification
                pinchMagnification = value
                zoom = min(2.0, max(0.5, zoom * Double(factor)))
            }
            .onEnded { _ in pinchMagnification = 1 })
    }

    func selectConnection(_ id: String) {
        finishInlineEditing()
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        model.selectedConnectionID = id; model.selectedNoteIDs = []; model.selectedNoteID = nil; model.selectedGroupID = nil
        canvasFocused = true
    }

    func displayedConnection(_ edge: Connection) -> Connection {
        var edge = edge
        if let drag = routePointDrag, drag.edge.id == edge.id { edge.routePoints = drag.points }
        return edge
    }

    func routeHandles(_ edge: Connection, from: Note, to: Note) -> some View {
        let points = displayedConnection(edge).controlPoints(from: from, to: to)
        return ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            Circle().fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: 13, height: 13).contentShape(Rectangle().inset(by: -9))
                .position(x: point.x, y: point.y)
                .help("Drag to adjust the connection path")
                .accessibilityLabel("Connection path point \(index + 1)")
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if routePointDrag == nil {
                        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                        guard !model.draftBlocked, let current = model.board?.connections.first(where: { $0.id == edge.id }) else { return }
                        let initial = current.controlPoints(from: from, to: to)
                        guard initial.indices.contains(index) else { return }
                        routePointDrag = RoutePointDrag(edge: current, index: index, origin: initial[index], points: initial)
                    }
                    guard routePointDrag?.edge.id == edge.id, routePointDrag?.index == index, let origin = routePointDrag?.origin else { return }
                    routePointDrag?.points[index] = ConnectionPoint(x: max(0, origin.x + value.translation.width / zoom), y: max(0, origin.y + value.translation.height / zoom))
                }.onEnded { _ in
                    guard let drag = routePointDrag, drag.edge.id == edge.id, drag.index == index else { return }
                    routePointDrag = nil
                    guard model.board?.connections.first(where: { $0.id == edge.id }) == drag.edge else { model.error = "The connection changed elsewhere. Please adjust it again."; return }
                    model.mutate { board in if let i = board.connections.firstIndex(where: { $0.id == edge.id }) { board.connections[i].routePoints = drag.points } }
                })
        }
    }

    func displayed(_ note: Note) -> Note {
        var result = note
        if let state = resizeState, state.id == note.id {
            let rect = state.preview
            result.x = rect.x; result.y = rect.y; result.width = rect.width; result.height = rect.height
        } else if draggingSelection, let board = model.board {
            let delta = board.selectionMovement(noteIDs: model.selectedNoteIDs, dx: dragTranslation.width / zoom, dy: dragTranslation.height / zoom)
            if delta.noteIDs.contains(note.id) { result.x += delta.dx; result.y += delta.dy }
        } else if draggingID == note.id {
            result.x = max(0, note.x + dragTranslation.width / zoom)
            result.y = max(0, note.y + dragTranslation.height / zoom)
        } else if let groupID = draggingID, let group = model.board?.groups.first(where: { $0.id == groupID }), group.memberIDs?.contains(note.id) == true {
            if let delta = model.board?.groupMovement(id: group.id, dx: dragTranslation.width / zoom, dy: dragTranslation.height / zoom) {
                result.x = note.x + delta.dx
                result.y = note.y + delta.dy
            }
        }
        return result
    }

    func connectionHandle(_ note: Note, board: Board) -> some View {
        let shown = displayed(note)
        return Image(systemName: "arrow.right.circle.fill")
            .font(.system(size: 19))
            .foregroundStyle(Color.accentColor, Color(nsColor: .controlBackgroundColor))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .position(x: shown.x + shown.width, y: shown.y + shown.height / 2)
            .help("Drag to another note to connect, or click and select a note")
            .accessibilityLabel("Connect note")
            .onTapGesture { model.beginConnection() }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("boardCanvas"))
                .onChanged { value in connectionDrag = ConnectionDrag(source: note.id, point: value.location) }
                .onEnded { value in
                    defer { connectionDrag = nil }
                    guard let drag = connectionDrag else { return }
                    let point = value.location
                    if let target = board.notes.reversed().first(where: { $0.id != drag.source && point.x >= $0.x && point.x <= $0.x + $0.width && point.y >= $0.y && point.y <= $0.y + $0.height }) {
                        model.connect(from: drag.source, to: target.id)
                    }
                })
    }

    func resizeHandles(id: String, rect: BoardRect, isNote: Bool) -> some View {
        let shown = resizeState?.id == id ? resizeState!.preview : rect
        return ForEach(ResizeCorner.allCases, id: \.self) { corner in
            let left = corner == .topLeft || corner == .bottomLeft
            let top = corner == .topLeft || corner == .topRight
            Circle().fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                .frame(width: 10, height: 10)
                .contentShape(Rectangle().inset(by: -8))
                .position(x: left ? shown.x : shown.x + shown.width, y: top ? shown.y : shown.y + shown.height)
                .help("Drag to resize")
                .accessibilityLabel("Resize \(corner.rawValue)")
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    if resizeState == nil {
                        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                        guard !model.draftBlocked else { return }
                        resizeState = ResizeState(id: id, origin: rect, corner: corner, translation: .zero)
                    }
                    guard resizeState?.id == id else { return }
                    resizeState?.translation = CGSize(width: value.translation.width / zoom, height: value.translation.height / zoom)
                }.onEnded { _ in
                    guard let state = resizeState, state.id == id else { return }
                    let result = state.preview
                    resizeState = nil
                    model.mutate { board in
                        if isNote, let i = board.notes.firstIndex(where: { $0.id == id }) {
                            board.notes[i].x = result.x; board.notes[i].y = result.y
                            board.notes[i].width = result.width; board.notes[i].height = result.height
                        } else if !isNote, let i = board.groups.firstIndex(where: { $0.id == id }) {
                            board.groups[i].x = result.x; board.groups[i].y = result.y
                            board.groups[i].width = result.width; board.groups[i].height = result.height
                        }
                    }
                })
        }
    }

    func noteView(_ note: Note, board: Board) -> some View {
        NoteTile(
            note: displayed(note),
            selected: model.selectedNoteID == note.id || model.selectedNoteIDs.contains(note.id),
            isEditing: editingObjectID == note.id && !editingGroupTitle,
            imagePath: note.imagePath,
            assets: board.projectAssets,
            projectFilesDirectory: board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? model.defaultProjectFilesDirectory(for: board.id),
            text: Binding(get: { inlineText }, set: { inlineText = $0; scheduleInlineSave() }),
            onFinishEditing: finishInlineEditing
        )
            .overlay(alignment: .topTrailing) {
                if let group = board.groupContaining(noteID: note.id) ?? board.groups.last(where: { BoardRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).containsCenter(of: note) }) {
                    let locked = board.groupContaining(noteID: note.id) != nil
                    Button { if locked { model.unlockNote(note.id) } else { model.lockNote(note.id, to: group.id) } } label: {
                        Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                            .font(.system(size: 10, weight: .semibold)).padding(5)
                            .background(.regularMaterial, in: Circle())
                    }.buttonStyle(.plain).padding(5)
                        .help(locked ? "Unlock from group" : "Lock to \(group.title)")
                        .accessibilityLabel(locked ? "Unlock note from group" : "Lock note to \(group.title)")
                }
            }
            .frame(width: displayed(note).width, height: displayed(note).height)
            .position(x: displayed(note).x + displayed(note).width / 2, y: displayed(note).y + displayed(note).height / 2)
            .onTapGesture {
                let clickedAnotherObject = model.selectedNoteID != note.id || model.selectedGroupID != nil
                if editingObjectID != note.id { finishInlineEditing() }
                if NSEvent.modifierFlags.contains(.shift), model.connectingFrom == nil {
                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                    guard !model.draftBlocked else { return }
                    var ids = model.selectedNoteIDs
                    if let selected = model.selectedNoteID { ids.insert(selected) }
                    if ids.contains(note.id) { ids.remove(note.id) } else { ids.insert(note.id) }
                    model.selectedNoteID = nil; model.selectedNoteIDs = ids
                    model.selectedGroupID = nil; model.selectedConnectionID = nil
                } else { model.chooseNote(note.id) }
                canvasFocused = true
                if clickedAnotherObject { showInspector = false }
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                beginInlineEditing(note)
            })
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                if draggingID == nil { finishInlineEditing(); NotificationCenter.default.post(name: .flushBoardDraft, object: nil) }
                guard !model.draftBlocked else { return }
                if draggingID == nil {
                    draggingSelection = model.selectedNoteIDs.contains(note.id)
                    draggingID = draggingSelection ? note.id : (model.board?.groupContaining(noteID: note.id)?.id ?? note.id)
                }
                dragTranslation = value.translation
            }.onEnded { value in
                guard let draggedID = draggingID else { return }
                let wasSelection = draggingSelection
                draggingID = nil; draggingSelection = false; dragTranslation = .zero
                model.mutate { board in
                    let dx = value.translation.width / zoom, dy = value.translation.height / zoom
                    if wasSelection { board.moveSelection(noteIDs: model.selectedNoteIDs, dx: dx, dy: dy); return }
                    if draggedID != note.id { _ = board.moveGroup(id: draggedID, dx: dx, dy: dy); return }
                    guard let index = board.notes.firstIndex(where: { $0.id == note.id }) else { return }
                    board.notes[index].x = max(0, note.x + dx)
                    board.notes[index].y = max(0, note.y + dy)
                }
            })
    }

    func displayedGroupRect(_ group: BoardGroup) -> BoardRect {
        let selectionDelta = draggingSelection ? model.board?.selectionMovement(noteIDs: model.selectedNoteIDs, dx: dragTranslation.width / zoom, dy: dragTranslation.height / zoom) : nil
        let delta = selectionDelta?.groupIDs.contains(group.id) == true ? (dx: selectionDelta!.dx, dy: selectionDelta!.dy) : (draggingID == group.id ? model.board?.groupMovement(id: group.id, dx: dragTranslation.width / zoom, dy: dragTranslation.height / zoom) : nil)
        let dx = delta?.dx ?? 0, dy = delta?.dy ?? 0
        return resizeState?.id == group.id ? resizeState!.preview : BoardRect(x: group.x + dx, y: group.y + dy, width: group.width, height: group.height)
    }

    func groupView(_ group: BoardGroup) -> some View {
        let rect = displayedGroupRect(group)
        var preview = group
        preview.x = rect.x; preview.y = rect.y; preview.width = rect.width; preview.height = rect.height
        return GroupTile(
            group: preview,
            selected: model.selectedGroupID == group.id,
            isEditingTitle: editingObjectID == group.id && editingGroupTitle,
            title: Binding(get: { inlineText }, set: { inlineText = $0; scheduleInlineSave() }),
            onFinishEditing: finishInlineEditing
        )
        .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        .onTapGesture {
            let clickedAnotherObject = model.selectedGroupID != group.id || model.selectedNoteID != nil
            if editingObjectID != group.id { finishInlineEditing() }
            model.chooseGroup(group.id); canvasFocused = true
            if clickedAnotherObject { showInspector = false }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            beginInlineEditing(group)
        })
        .gesture(DragGesture(minimumDistance: 3).onChanged { value in
            if draggingID == nil { finishInlineEditing(); NotificationCenter.default.post(name: .flushBoardDraft, object: nil) }
            guard !model.draftBlocked else { return }
            draggingID = group.id; dragTranslation = value.translation
        }.onEnded { value in
            guard draggingID == group.id else { return }
            draggingID = nil; dragTranslation = .zero
            model.mutate { board in
                _ = board.moveGroup(id: group.id, dx: value.translation.width / zoom, dy: value.translation.height / zoom)
            }
        })
    }

    func beginInlineEditing(_ note: Note) {
        finishInlineEditing()
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        model.chooseNote(note.id)
        editingObjectID = note.id
        editingGroupTitle = false
        inlineText = note.text
        showInspector = true
        canvasFocused = true
    }

    func beginInlineEditing(_ group: BoardGroup) {
        finishInlineEditing()
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !model.draftBlocked else { return }
        model.chooseGroup(group.id)
        editingObjectID = group.id
        editingGroupTitle = true
        inlineText = group.title
        showInspector = true
        canvasFocused = true
    }

    func scheduleInlineSave() {
        guard let id = editingObjectID else { return }
        inlineSaveTask?.cancel()
        let value = inlineText
        let editsGroupTitle = editingGroupTitle
        inlineSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, editingObjectID == id, inlineText == value else { return }
            saveInlineText(value, id: id, editsGroupTitle: editsGroupTitle)
        }
    }

    func saveInlineText(_ value: String, id: String, editsGroupTitle: Bool) {
        guard let board = model.board else { return }
        if editsGroupTitle {
            guard let group = board.groups.first(where: { $0.id == id }), group.title != value else { return }
            model.mutate { current in
                guard let index = current.groups.firstIndex(where: { $0.id == id }) else { return }
                current.groups[index].title = value
            }
        } else {
            guard let note = board.notes.first(where: { $0.id == id }), note.text != value else { return }
            model.mutate { current in
                guard let index = current.notes.firstIndex(where: { $0.id == id }) else { return }
                current.notes[index].text = value
            }
        }
    }

    func finishInlineEditing() {
        guard let id = editingObjectID else { return }
        inlineSaveTask?.cancel()
        saveInlineText(inlineText, id: id, editsGroupTitle: editingGroupTitle)
        editingObjectID = nil
        editingGroupTitle = false
    }
}

struct MascotLogo: View {
    var body: some View {
        if let path = Bundle.main.path(forResource: "Mascot", ofType: "png"), let mascot = NSImage(contentsOfFile: path) {
            Image(nsImage: mascot).resizable().scaledToFit().accessibilityLabel("CoThink mascot")
        } else {
            Image(systemName: "note.text").resizable().scaledToFit().padding(8).foregroundStyle(.secondary)
        }
    }
}

struct GlassControl: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(4).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            content.padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.08)))
        }
    }
}

struct ConnectionDrag {
    let source: String
    var point: CGPoint
}
struct RoutePointDrag {
    let edge: Connection
    let index: Int
    let origin: ConnectionPoint
    var points: [ConnectionPoint]
}

struct ResizeState {
    let id: String
    let origin: BoardRect
    let corner: ResizeCorner
    var translation: CGSize
    var preview: BoardRect { origin.resized(from: corner, dx: translation.width, dy: translation.height) }
}

extension LineStyle {
    var dashPattern: [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [8, 5]
        case .dotted: return [1, 4]
        }
    }
}

struct GroupTile: View {
    let group: BoardGroup
    let selected: Bool
    let isEditingTitle: Bool
    @Binding var title: String
    let onFinishEditing: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            if isEditingTitle {
                TextField("Group name", text: $title)
                    .font(.system(size: group.fontSize ?? 11, weight: .bold))
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit(onFinishEditing)
                    .onChange(of: titleFocused) { _, focused in if !focused { onFinishEditing() } }
                    .onAppear { DispatchQueue.main.async { titleFocused = true } }
                    .onExitCommand(perform: onFinishEditing)
            } else {
                Text(group.title.uppercased()).font(.system(size: group.fontSize ?? 11, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: group.width, height: group.height, alignment: .topLeading)
        .background(Color(hex: group.color).opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: group.strokeColor ?? "#6F7785"), style: StrokeStyle(lineWidth: group.strokeWidth ?? 1, lineCap: .round, dash: (group.strokeStyle ?? .dashed).dashPattern)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1))
    }
}

struct NoteTile: View {
    let note: Note
    let selected: Bool
    let isEditing: Bool
    let imagePath: String?
    let assets: [ProjectAsset]
    let projectFilesDirectory: URL
    @Binding var text: String
    let onFinishEditing: () -> Void
    @FocusState private var textFocused: Bool

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextEditor(text: $text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(Color.readableText(on: note.color))
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .frame(minHeight: imagePath == nil ? 40 : 28)
                        .onChange(of: textFocused) { _, focused in if !focused { onFinishEditing() } }
                        .onAppear { DispatchQueue.main.async { textFocused = true } }
                        .onExitCommand(perform: onFinishEditing)
                } else {
                    Text(note.text.isEmpty ? "Empty note" : note.text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(Color.readableText(on: note.color).opacity(note.text.isEmpty ? 0.66 : 1))
                }
                if let imagePath, let image = NSImage(contentsOfFile: imagePath) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: max(32, note.height * 0.42))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .allowsHitTesting(false)
                }
                ForEach(assets.filter { note.assetIDs?.contains($0.id) == true }) { asset in
                    let url = projectFilesDirectory.appendingPathComponent(asset.relativePath)
                    if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                       let image = NSImage(contentsOf: url) {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: max(28, note.height * 0.35))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help("Open \(asset.name)")
                    } else {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(asset.name, systemImage: assetSymbol(asset.name))
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(asset.name)")
                    }
                }
                Spacer(minLength: 0)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(isEditing ? 8 : 16)
            .background(Color(hex: note.color), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: note.strokeColor ?? "#6F7785"), style: StrokeStyle(lineWidth: note.strokeWidth ?? 1, lineCap: .round, dash: (note.strokeStyle ?? .solid).dashPattern)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
    }

    private func assetSymbol(_ name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension
        if ext.lowercased() == "pdf" { return "doc.richtext" }
        return "doc"
    }
}

struct ConnectionGeometry {
    let path: Path
    let start: CGPoint
    let end: CGPoint
    let startDirection: CGPoint
    let endDirection: CGPoint
    let labelPosition: CGPoint

    init(from: Note, to: Note, edge: Connection) {
        let source = CGPoint(x: from.x + from.width / 2, y: from.y + from.height / 2)
        let target = CGPoint(x: to.x + to.width / 2, y: to.y + to.height / 2)
        let controls = edge.controlPoints(from: from, to: to).map { CGPoint(x: $0.x, y: $0.y) }
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            return length > 0.001 ? CGPoint(x: dx / length, y: dy / length) : CGPoint(x: 1, y: 0)
        }
        let sourceDir = unit(source, controls.first ?? target)
        let targetDir = unit(controls.last ?? source, target)
        func boundary(_ center: CGPoint, _ direction: CGPoint, _ note: Note) -> CGPoint {
            let distance = min(note.width / max(abs(direction.x), 0.0001), note.height / max(abs(direction.y), 0.0001)) / 2
            return CGPoint(x: center.x + direction.x * distance, y: center.y + direction.y * distance)
        }
        let start = boundary(source, sourceDir, from)
        let end = boundary(target, CGPoint(x: -targetDir.x, y: -targetDir.y), to)
        var path = Path(); path.move(to: start)
        if edge.effectiveRoute == .curved, let control = controls.first {
            path.addQuadCurve(to: end, control: control)
            labelPosition = CGPoint(x: (start.x + 2 * control.x + end.x) / 4, y: (start.y + 2 * control.y + end.y) / 4)
        } else {
            for point in controls { path.addLine(to: point) }
            path.addLine(to: end)
            let points = [start] + controls + [end]
            let i = (points.count - 1) / 2
            labelPosition = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
        }
        self.path = path; self.start = start; self.end = end
        self.startDirection = sourceDir; self.endDirection = targetDir
    }
}

struct ConnectionView: View {
    let from: Note
    let to: Note
    let edge: Connection
    let selected: Bool
    let canvasWidth: Double
    let canvasHeight: Double
    var body: some View {
        let geometry = ConnectionGeometry(from: from, to: to, edge: edge)
        return Canvas { context, _ in
            if selected { context.stroke(geometry.path, with: .color(.accentColor.opacity(0.35)), lineWidth: (edge.strokeWidth ?? 1) + 6) }
            context.stroke(geometry.path, with: .color(Color(hex: edge.strokeColor ?? "#6F7785")), style: StrokeStyle(lineWidth: edge.strokeWidth ?? 1, lineCap: .round, dash: (edge.strokeStyle ?? .solid).dashPattern))
            func drawArrow(tip: CGPoint, direction: CGPoint) {
                var arrow = Path(); arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - direction.x * 12 - direction.y * 6, y: tip.y - direction.y * 12 + direction.x * 6))
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - direction.x * 12 + direction.y * 6, y: tip.y - direction.y * 12 - direction.x * 6))
                context.stroke(arrow, with: .color(Color(hex: edge.strokeColor ?? "#6F7785")), lineWidth: max(1, edge.strokeWidth ?? 1))
            }
            if edge.effectiveDirection != .none {
                drawArrow(tip: geometry.end, direction: geometry.endDirection)
                if edge.effectiveDirection == .twoWay {
                    drawArrow(tip: geometry.start, direction: CGPoint(x: -geometry.startDirection.x, y: -geometry.startDirection.y))
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .overlay(alignment: .topLeading) {
            if let label = edge.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(label).font(.system(size: edge.fontSize ?? 11, weight: .medium)).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.secondary.opacity(0.2), lineWidth: 0.5))
                    .position(geometry.labelPosition).allowsHitTesting(false)
            }
        }
        .contentShape(ConnectionHitShape(line: geometry.path).stroke(lineWidth: 14))
    }
}

struct ConnectionHitShape: Shape {
    let line: Path
    func path(in rect: CGRect) -> Path { line }
}

extension Color {
    static func readableText(on hex: String) -> Color {
        let value = Int(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xFFF1AF
        func linear(_ channel: Int) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 255) + 0.7152 * linear((value >> 8) & 255) + 0.0722 * linear(value & 255)
        return luminance > 0.179 ? .black : .white
    }
    init(hex: String) {
        let value = Int(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0xFFF1AF
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

extension Notification.Name {
    static let flushBoardDraft = Notification.Name("CoThinkFlushBoardDraft")
    static let createGroupCommand = Notification.Name("CoThinkCreateGroupCommand")
    static let showProjectFiles = Notification.Name("CoThinkShowProjectFiles")
    static let wallpaperCommand = Notification.Name("CoThinkWallpaperCommand")
    static let exportPDFCommand = Notification.Name("CoThinkExportPDFCommand")
    static let zoomInCommand = Notification.Name("CoThinkZoomInCommand")
    static let zoomOutCommand = Notification.Name("CoThinkZoomOutCommand")
    static let zoomResetCommand = Notification.Name("CoThinkZoomResetCommand")
}

struct MCPSetupView: View {
    @State private var copied = false
    private var executable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cothink-mcp").path
    }
    private var configuration: String {
        let value: [String: Any] = ["mcpServers": ["cothink": ["command": executable, "env": ["COTHINK_MCP_ACTOR": "agent"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect an agent").font(.headline)
            Text("Add this local MCP server to your agent's MCP settings. It uses the same boards as this app.").foregroundStyle(.secondary)
            Text(configuration).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(copied ? "Copied" : "Copy configuration") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration, forType: .string); copied = true
                }
                Spacer()
                Text("Local · stdio").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).frame(width: 450)
    }
}
