import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import BoardCore

private struct CanvasClipboard: Codable {
    var fragment: BoardFragment
    var sourceFolder: String
}
private let canvasClipboardType = NSPasteboard.PasteboardType("com.cothink.board.objects.v1")

private struct CanvasShortcutMonitor: NSViewRepresentable {
    var handle: (NSEvent) -> Bool
    final class Coordinator {
        var handle: (NSEvent) -> Bool
        var monitor: Any?
        weak var view: NSView?
        init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window else { return event }
            return coordinator.handle(event) ? nil : event
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

/// The armed canvas tool. `.note` is the default: every other case trades the
/// empty-canvas click away from creating notes.
enum CanvasTool: Equatable {
    case note, select, shape(NoteShape)
}

/// Resolved once per canvas frame and passed down, so note tiles never
/// recompute selectionMovement themselves.
struct CanvasDragMovement {
    var noteIDs: Set<String>
    var groupIDs: Set<String>
    var dx: Double
    var dy: Double
}

@main
struct CoThinkApp: App {
    @StateObject private var model = BoardViewModel()
    @StateObject private var cloudAccount = CloudAccount()
    @StateObject private var agentSession = AgentChatSession()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model, agentSession: agentSession)
                .environmentObject(cloudAccount)
                .onAppear { cloudAccount.start(model) }
                .frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { NotificationCenter.default.post(name: .newNoteCommand, object: nil) }.keyboardShortcut("n", modifiers: .command).disabled(model.board == nil || model.homeVisible)
                Button("New Board") { model.createBoard() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appSettings) {
                Button("Account & Sync…") { cloudAccount.showingPanel = true }
            }
            CommandMenu("Board") {
                Button("Group Selection or Draw Group") { NotificationCenter.default.post(name: .createGroupCommand, object: nil) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.board == nil || model.homeVisible)
                Button("Connect Selected Note") { model.beginConnection() }.keyboardShortcut("l", modifiers: .command).disabled(model.selectedNoteID == nil || model.homeVisible)
                Button("Delete Selection") { NotificationCenter.default.post(name: .requestDeleteSelectionCommand, object: nil) }.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(!model.hasSelection || model.homeVisible)
                Button("Change Wallpaper…") { NotificationCenter.default.post(name: .wallpaperCommand, object: nil) }.disabled(model.board == nil || model.homeVisible)
                Button("Tidy Mindmap Tree") { model.tidyTree(rootID: nil) }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(model.board == nil || model.homeVisible)
                Divider()
                Button("Export Board…") { model.exportBoard() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.board == nil || model.homeVisible)
                Button("Export Board as PDF…") { NotificationCenter.default.post(name: .exportPDFCommand, object: nil) }.disabled(model.board == nil || model.homeVisible)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Board Change") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command).disabled(model.homeVisible)
                Button("Redo Board Change") { model.redo() }
                    .keyboardShortcut("y", modifiers: .command).disabled(model.homeVisible)
            }
            CommandGroup(replacing: .pasteboard) {
                let editingText = NSApp.keyWindow?.firstResponder is NSTextView
                Button("Cut") {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { textView.cut(nil) }
                    else { model.copySelection(); model.deleteSelection() }
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!editingText && (!model.hasSelection || model.homeVisible))
                Button("Copy") {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { textView.copy(nil) }
                    else { model.copySelection() }
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!editingText && (!model.hasSelection || model.homeVisible))
                Button("Paste") {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { textView.paste(nil) }
                    else { model.pasteSelection() }
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!editingText && (!model.canPaste || model.homeVisible))
                Button("Select All") {
                    if let textView = NSApp.keyWindow?.firstResponder as? NSTextView { textView.selectAll(nil) }
                    else { model.selectAllNotes() }
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!editingText && ((model.board?.notes.isEmpty ?? true) || model.homeVisible))
            }
            CommandMenu("View") {
                Button("Zoom In") { NotificationCenter.default.post(name: .zoomInCommand, object: nil) }.keyboardShortcut("+", modifiers: .command).disabled(model.board == nil || model.homeVisible)
                Button("Zoom Out") { NotificationCenter.default.post(name: .zoomOutCommand, object: nil) }.keyboardShortcut("-", modifiers: .command).disabled(model.board == nil || model.homeVisible)
                Divider()
                Button("Actual Size") { NotificationCenter.default.post(name: .zoomResetCommand, object: nil) }.keyboardShortcut("0", modifiers: .command).disabled(model.board == nil || model.homeVisible)
            }
        }
    }
}

@MainActor
final class BoardViewModel: ObservableObject {
    private var clipboardChangeCount = -1
    private var pasteCount = 0
    @Published var boards: [Board] = []
    @Published var deskIDs: Set<String> = []
    @Published var pinnedListID: String?
    @Published var boardLists: [BoardList] = []
    @Published var lastOpened: [String: Date] = [:]
    @Published var history: [Change] = []
    @Published var draftBlocked = false
    @Published var board: Board?
    @Published var selectedNoteID: String?
    @Published var selectedNoteIDs: Set<String> = []
    var hasSelection: Bool { selectedNoteID != nil || !selectedNoteIDs.isEmpty || selectedGroupID != nil || selectedConnectionID != nil }

    var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.data(forType: canvasClipboardType) != nil { return true }
        return pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func selectAllNotes() {
        guard let board, !board.notes.isEmpty else { return }
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        selectedNoteIDs = Set(board.notes.map(\.id)); selectedNoteID = nil; selectedGroupID = nil; selectedConnectionID = nil
    }
    var selectionCount: Int { (selectedNoteID != nil ? 1 : 0) + selectedNoteIDs.count + (selectedGroupID != nil ? 1 : 0) + (selectedConnectionID != nil ? 1 : 0) }
    @Published var selectedGroupID: String?
    @Published var selectedConnectionID: String?
    @Published var connectingFrom: String?
    /// Note the canvas should drop into inline editing as soon as it appears —
    /// set by every note-creation path so new notes open straight into typing.
    @Published var pendingInlineEditID: String?
    @Published var error: String?
    /// True while the Home page is showing; board-canvas menu commands disable themselves.
    @Published var homeVisible = true
    private(set) var store: BoardStore?

    init(storeDirectory: URL? = nil) {
        do {
            store = try BoardStore(directory: storeDirectory)
            try refresh()
            if boards.isEmpty { createBoard() }
            else if let first = boards.first { selectBoard(first.id) }
        } catch { self.error = error.localizedDescription }
    }

    func refresh() throws {
        guard let store else { return }
        let snapshot = try store.pollSnapshot(currentBoardID: board?.id)
        if snapshot.boards != boards { boards = snapshot.boards }
        if snapshot.deskIDs != deskIDs { deskIDs = snapshot.deskIDs }
        if snapshot.pinnedListID != pinnedListID { pinnedListID = snapshot.pinnedListID }
        if snapshot.lists != boardLists { boardLists = snapshot.lists }
        if snapshot.history != history { history = snapshot.history }
        if snapshot.lastOpened != lastOpened { lastOpened = snapshot.lastOpened }
        if snapshot.board?.revision != board?.revision || snapshot.board?.editedAt != board?.editedAt {
            board = snapshot.board
            if snapshot.board == nil { clearSelection() }
        }
    }

    func switchWorkspace(to next: BoardStore) throws {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { throw CloudAccountError.draft }
        store = next
        clearSelection()
        board = nil
        history = []
        pendingInlineEditID = nil
        try refresh()
        if let first = boards.first { selectBoard(first.id) }
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
        do { board = try store?.get(id); try? store?.markOpened(id); history = try store?.history(id) ?? []; clearSelection() }
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
        guard let current = board else { return }
        deleteBoard(id: current.id)
    }

    func deleteBoard(id: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        guard let target = boards.first(where: { $0.id == id }) else { return }
        do {
            try store?.delete(target.id, expectedRevision: target.revision)
            if board?.id == target.id { board = nil; clearSelection() }
            try refresh()
            if board == nil, let first = boards.first { selectBoard(first.id) }
        } catch { self.error = error.localizedDescription }
    }

    func moveBoard(id: String, to anchor: BoardAnchor) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let store else { return }
        do { try store.move(boardID: id, to: anchor); try refresh() }
        catch { self.error = error.localizedDescription; try? refresh() }
    }

    func deleteBoards(_ ids: [String]) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        let present = Set(boards.map(\.id))
        let targets = ids.filter { present.contains($0) }
        guard !targets.isEmpty, let store else { return }
        do {
            try store.deleteBoards(targets)
            if let current = board, targets.contains(current.id) { board = nil; clearSelection() }
            try refresh()
            if board == nil, let first = boards.first { selectBoard(first.id) }
        } catch { self.error = error.localizedDescription; try? refresh() }
    }

    @discardableResult
    func createList() -> BoardList? {
        do { guard let store else { return nil }; let created = try store.createList(title: "Untitled list"); try refresh(); return created }
        catch { self.error = error.localizedDescription; return nil }
    }
    var deskListID: String {
        var id = ":desk"
        while boardLists.contains(where: { $0.id == id }) { id += ":" }
        return id
    }

    var deskList: BoardList {
        var list = BoardList(title: "On Desk")
        list.id = deskListID
        list.boardIDs = boards.filter { deskIDs.contains($0.id) }.map(\.id)
        return list
    }

    func toggleDesk(_ board: Board) {
        do {
            try store?.setOnDesk(board.id, included: !deskIDs.contains(board.id))
            try refresh()
        } catch { self.error = error.localizedDescription; try? refresh() }
    }

    func toggleHomePin(_ list: BoardList) {
        do {
            try store?.setPinnedList(pinnedListID == list.id ? nil : list.id)
            try refresh()
        } catch { self.error = error.localizedDescription; try? refresh() }
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

    func placeReminder(_ id: String, title: String, boardID: String, at point: CGPoint, in boxID: String? = nil) -> Bool {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let board, board.id == boardID else { return false }
        if let boxID {
            guard let index = board.notes.firstIndex(where: { $0.id == boxID && $0.reminderID != nil }) else { return false }
            if !board.notes[index].reminderItems.contains(where: { $0.id == id }) {
                guard mutate({ board in
                    var box = board.notes[index]
                    box.additionalReminders = (box.additionalReminders ?? []) + [ReminderReference(id: id, title: title)]
                    box.height = max(box.height, 60 + Double(box.reminderItems.count) * 60)
                    board.notes[index] = box
                }) else { return false }
            }
            clearSelection()
            selectedNoteID = boxID
            return true
        }
        if let existing = board.notes.first(where: { $0.reminderItems.contains(where: { $0.id == id }) }) {
            chooseNote(existing.id)
            return true
        }
        var card = Note(text: title, x: point.x, y: point.y, width: 240, height: 108, color: "#F6ECD9")
        while board.notes.contains(where: { abs($0.x - card.x) < 8 && abs($0.y - card.y) < 8 }) {
            card.x += 30
            card.y += 30
        }
        card.reminderID = id
        guard mutate({ $0.notes.append(card) }) else { return false }
        clearSelection()
        selectedNoteID = card.id
        return true
    }

    func addNote(x: Double = 500, y: Double = 300) {
        appendNote(Note(id: UUID().uuidString, text: "", x: x, y: y, width: 190, height: 100, color: "#FFF1AF"), opensEditor: true)
    }

    func addShape(_ shape: NoteShape, frame: BoardRect, flipped: Bool) {
        appendNote(Note.makeShape(shape, x: frame.x, y: frame.y, width: frame.width, height: frame.height, flipped: flipped), opensEditor: shape == .text)
    }

    private func appendNote(_ note: Note, opensEditor: Bool) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        mutate { $0.notes.append(note) }
        selectedNoteID = note.id
        selectedNoteIDs = []
        selectedGroupID = nil
        selectedConnectionID = nil
        if opensEditor { pendingInlineEditID = note.id }
    }

    func addAdjacentNote(toRight: Bool, of sourceID: String? = nil) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let anchorID = sourceID ?? selectedNoteID,
              let source = board?.notes.first(where: { $0.id == anchorID }) else { return }
        let note = Note(text: "", x: toRight ? source.x + source.width + 70 : source.x,
                        y: toRight ? source.y : source.y + source.height + 70,
                        width: 190, height: 100, color: "#FFF1AF")
        if mutate({ board in
            board.notes.append(note)
            if toRight { board.connections.append(Connection(from: source.id, to: note.id, direction: .oneWay)) }
        }) {
            selectedNoteID = note.id; selectedNoteIDs = []; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
            pendingInlineEditID = note.id
        }
    }

    /// The Tab key's creation routing — the single table shared by the canvas shortcut
    /// and the inline editor: shift → a tree child of the anchor; plain Tab → a child
    /// when the anchor is already tree-linked, otherwise a plain connected note to its right.
    func addViaTab(from noteID: String, shift: Bool) {
        if shift || board?.isTreeLinked(noteID: noteID) == true { addChild(of: noteID) }
        else { addAdjacentNote(toRight: true, of: noteID) }
    }

    func addChild(of sourceID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board,
              let parent = current.notes.first(where: { $0.id == sourceID }) else { return }
        let lastChild = current.children(of: sourceID).last
        let note = Note(text: "",
                        x: parent.x + parent.width + 60,
                        y: lastChild.map { $0.y + $0.height + 24 } ?? parent.y,
                        width: 200, height: 100, color: "#FFF1AF", parentID: sourceID)
        if mutate({ $0.notes.append(note) }) {
            selectedNoteID = note.id; selectedNoteIDs = []; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
            pendingInlineEditID = note.id
        }
    }

    func addSiblingNote(to noteID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board,
              let index = current.notes.firstIndex(where: { $0.id == noteID }) else { return }
        let sibling = current.notes[index]
        let note = Note(text: "",
                        x: sibling.x, y: sibling.y + sibling.height + 24,
                        width: 200, height: 100, color: "#FFF1AF", parentID: sibling.parentID)
        if mutate({ $0.notes.insert(note, at: index + 1) }) {
            selectedNoteID = note.id; selectedNoteIDs = []; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
            pendingInlineEditID = note.id
        }
    }

    func toggleFold(_ noteID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        mutate { $0.toggleFold(noteID: noteID) }
    }

    func detachNote(_ noteID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, board?.notes.first(where: { $0.id == noteID })?.parentID != nil else { return }
        mutate { try? $0.setNoteParent(noteID, to: nil) }
    }

    func selectSubtree(of noteID: String) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board, current.notes.contains(where: { $0.id == noteID }) else { return }
        selectedNoteIDs = current.descendantIDs(of: noteID).union([noteID])
        selectedNoteID = noteID
        selectedGroupID = nil
        selectedConnectionID = nil
        connectingFrom = nil
    }

    func tidyTree(rootID: String?) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        mutate { $0.tidySubtree(rootID: rootID) }
    }

    func copySelection() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let board else { return }
        var ids = selectedNoteIDs
        if let selectedNoteID { ids.insert(selectedNoteID) }
        // Groups whose every member is selected travel with the copy, so enclosing
        // a cluster and copying reproduces its group boxes too.
        let enclosedGroups = Set(board.groups
            .filter { group in (group.memberIDs ?? []).allSatisfy { ids.contains($0) } }
            .filter { !($0.memberIDs ?? []).isEmpty }
            .map(\.id))
        let fragment = BoardFragment.capture(from: board, noteIDs: ids, groupID: selectedGroupID, connectionID: selectedConnectionID, extraGroupIDs: enclosedGroups)
        guard !fragment.notes.isEmpty || !fragment.groups.isEmpty else { return }
        let folder = board.projectFilesPath ?? defaultProjectFilesDirectory(for: board.id).path
        guard let data = try? JSONEncoder().encode(CanvasClipboard(fragment: fragment, sourceFolder: folder)) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setData(data, forType: canvasClipboardType)
        let plainText = fragment.notes.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !plainText.isEmpty { pasteboard.setString(plainText, forType: .string) }
        clipboardChangeCount = pasteboard.changeCount; pasteCount = 0
    }

    func pasteSelection() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board else { return }
        guard let data = NSPasteboard.general.data(forType: canvasClipboardType),
              let copied = try? JSONDecoder().decode(CanvasClipboard.self, from: data),
              !copied.fragment.notes.isEmpty || !copied.fragment.groups.isEmpty else { pasteTextSelection(); return }
        let fragment = copied.fragment
        guard Set(fragment.notes.map(\.id)).count == fragment.notes.count,
              Set(fragment.groups.map(\.id)).count == fragment.groups.count,
              Set(fragment.assets.map(\.id)).count == fragment.assets.count else { error = "The copied objects are invalid."; return }
        let referenced = Set(fragment.notes.flatMap { $0.assetIDs ?? [] })
        guard referenced.isSubset(of: Set(fragment.assets.map(\.id))) else { error = "The copied note has a missing project file."; return }
        if current.id == fragment.sourceBoardID && !referenced.isSubset(of: Set(current.projectAssets.map(\.id))) {
            error = "A copied project file is no longer linked to this board."; return
        }
        let pasteboard = NSPasteboard.general
        if clipboardChangeCount != pasteboard.changeCount { clipboardChangeCount = pasteboard.changeCount; pasteCount = 0 }
        var addedAssets: [ProjectAsset] = []
        var assetMapping: [String: String] = [:]
        var copiedFiles: [URL] = []
        if current.id != fragment.sourceBoardID && !fragment.assets.isEmpty {
            let destination = current.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultProjectFilesDirectory(for: current.id)
            let sourceFolder = URL(fileURLWithPath: copied.sourceFolder, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for asset in fragment.assets where referenced.contains(asset.id) {
                    guard !asset.relativePath.hasPrefix("/"), !asset.relativePath.split(separator: "/").contains("..") else { throw BoardError.invalid("project file path") }
                    let source = sourceFolder.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
                    guard source.path.hasPrefix(sourceFolder.path + "/") else { throw BoardError.invalid("project file path") }
                    let filename = UUID().uuidString + "-" + URL(fileURLWithPath: asset.name).lastPathComponent
                    let target = destination.appendingPathComponent(filename)
                    try FileManager.default.copyItem(at: source, to: target); copiedFiles.append(target)
                    let added = ProjectAsset(name: asset.name, relativePath: filename)
                    assetMapping[asset.id] = added.id; addedAssets.append(added)
                }
            } catch {
                for file in copiedFiles { try? FileManager.default.removeItem(at: file) }
                self.error = "Could not copy the attached project files: \(error.localizedDescription)"; return
            }
        }
        var inserted: (notes: [String], groups: [String]) = ([], [])
        let offset = Double(pasteCount + 1) * 36
        if mutate({ board in
            board.assets = (board.assets ?? []) + addedAssets
            inserted = fragment.insert(into: &board, offset: offset, assetIDs: assetMapping)
        }) {
            pasteCount += 1
            selectedNoteIDs = []; selectedNoteID = nil; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
            if inserted.groups.count == 1 { selectedGroupID = inserted.groups[0] }
            else if inserted.notes.count == 1 { selectedNoteID = inserted.notes[0] }
            else { selectedNoteIDs = Set(inserted.notes) }
        } else {
            for file in copiedFiles { try? FileManager.default.removeItem(at: file) }
        }
    }

    func pasteTextSelection() {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked else { return }
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        if clipboardChangeCount != pasteboard.changeCount { clipboardChangeCount = pasteboard.changeCount; pasteCount = 0 }
        let offset = Double(pasteCount + 1) * 36
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0.0) { $0 + max(1, (Double($1.count) / 24).rounded(.up)) }
        let height = min(480, max(100, lineCount * 19 + 48))
        let id = UUID().uuidString
        if mutate({ $0.notes.append(Note(id: id, text: text, x: 500 + offset, y: 300 + offset, width: 220, height: height, color: "#FFF1AF")) }) {
            pasteCount += 1
            selectedNoteID = id; selectedNoteIDs = []; selectedGroupID = nil; selectedConnectionID = nil; connectingFrom = nil
        }
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
        let hidden = current.hiddenNoteIDs()
        let members = current.notes.filter { !hidden.contains($0.id) && (selectedMembers?.contains($0.id) ?? rect.containsCenter(of: $0)) }.map(\.id)
        var group = BoardGroup(title: "Group", x: rect.x, y: rect.y, width: max(80, rect.width), height: max(50, rect.height), color: "#DCECE9")
        group.memberIDs = members
        if mutate({ board in
            for i in board.groups.indices { board.groups[i].memberIDs?.removeAll { members.contains($0) } }
            board.groups.append(group)
        }) {
            selectedGroupID = group.id; selectedNoteID = nil; selectedNoteIDs = []; selectedConnectionID = nil
        }
    }

    func selectNotes(in rect: BoardRect, additive: Bool = false) {
        NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
        guard !draftBlocked, let current = board else { return }
        let hidden = current.hiddenNoteIDs()
        let hits = Set(current.notes.filter { rect.containsCenter(of: $0) && !hidden.contains($0.id) }.map(\.id))
        if additive {
            var ids = selectedNoteIDs.union(hits)
            if let single = selectedNoteID { ids.insert(single) }
            selectedNoteIDs = ids
        } else {
            selectedNoteIDs = hits
        }
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
        let hidden = current.hiddenNoteIDs()
        let members = current.notes.filter { rect.containsCenter(of: $0) && !hidden.contains($0.id) }.map(\.id)
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
                board.deleteNotes(notes)
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
    @StateObject private var presence = BoardPresence()
    @State private var inspectorEditID: String?
    @Environment(\.scenePhase) private var presencePhase
    @EnvironmentObject private var cloudAccount: CloudAccount
    @ObservedObject var model: BoardViewModel
    let agentSession: AgentChatSession
    @AppStorage("showBoardSidebar") private var showBoardSidebar = true
    @AppStorage("inspectorVisibility") private var inspectorVisibilityRaw = InspectorVisibility.automatic.rawValue
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
    @State private var showingDeleteBoards = false
    @State private var showingDeleteSelection = false
    @State private var showingMCP = false
    @State private var showingProjectFiles = false
    @State private var wallpaperBoard: Board?
    @State private var pdfExportBoard: Board?
    @State private var showingListManager = false
    @State private var focusedListID: String?
    @State private var foldedLists = Set<String>()
    @State private var reminderBoxID: String?
    @State private var showingReminders = false
    @State private var editingListID: String?
    @State private var listToDelete: BoardList?
    @State private var showingDeleteList = false
    @State private var showingBoardSettings = false
    @State private var draggingID: String?
    @State private var draggingSelection = false
    @State private var sidebarSelection: Set<String> = []
    @State private var sidebarSelectionAnchor: String?
    @State private var dropRowID: String?
    @State private var dropBelow = false
    @State private var dropVisible = false
    @State private var viewport = CGRect.zero
    @State private var followExtent = CGSize.zero
    @State private var scrollRequest: CGPoint?
    @State private var dragTranslation: CGSize = .zero
    @State private var resizeState: ResizeState?
    @State private var selectionStart: CGPoint?
    @State private var selectionEnd: CGPoint?
    @State private var tool: CanvasTool = .note
    @State private var shapeDraft: CGRect?
    @State private var shapeDraftFlipped = false
    @State private var connectionDrag: ConnectionDrag?
    @State private var routePointDrag: RoutePointDrag?
    @State private var drawingGroup = false
    @State private var showingHome = true
    @FocusState private var canvasFocused: Bool
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var inspectorVisibility: InspectorVisibility {
        InspectorVisibility(rawValue: inspectorVisibilityRaw) ?? .automatic
    }
    private var showInspector: Bool { inspectorVisibility.isVisible(hasSelection: model.hasSelection) }

    private var presenceContext: PresenceContext {
        let boardID = showingHome || presencePhase == .background ? nil : model.board?.id
        let geometryEdit = draggingID ?? resizeState?.id ?? routePointDrag?.edge.id ?? connectionDrag?.source
        let objectID = editingObjectID ?? geometryEdit ?? (showingReminders ? reminderBoxID : inspectorEditID)
        return PresenceContext(login: cloudAccount.expired ? nil : cloudAccount.login, boardID: boardID, editing: objectID)
    }

    var body: some View {
        dialogAndCommandLayer.onOpenURL(perform: openBoardLink)
            .onChange(of: presenceContext, initial: true) { _, context in presence.configure(context); publishBoardCamera() }
            .onDisappear { presence.close() }
    }

    private func publishBoardCamera() {
        presence.updateCamera(BoardCamera(viewport: viewport, zoom: zoom))
    }
    private func fitFollowedCamera() {
        guard let view = presence.followedCamera, viewport.width > 0, viewport.height > 0 else { return }
        zoom = view.fittedZoom(in: viewport.size)
        followExtent = CGSize(width: ceil(view.x + viewport.width / (2 * zoom)),
                              height: ceil(view.y + viewport.height / (2 * zoom)))
    }

    private func openBoardLink(_ url: URL) {
        guard url.scheme == "cothink", url.host == "board",
              let id = url.pathComponents.last, model.boards.contains(where: { $0.id == id }) else { return }
        model.selectBoard(id)
        if model.board?.id == id {
            showingHome = false
            focusedListID = nil
        }
    }

    private var canvasRoot: some View {
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
                        InspectorView(model: model, board: board, presenceID: $inspectorEditID)
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
    }

    /// Switches between the board workspace and the Home page; shared chrome
    /// (background, tint, dialogs, commands) wraps whichever is showing.
    @ViewBuilder
    private var rootContent: some View {
        if showingHome {
            homeLayer
        } else {
            canvasRoot
        }
    }

    private var homeLayer: some View {
        HomeView(model: model,
                 search: $search,
                 onOpenBoard: { id in showingHome = false; model.selectBoard(id) },
                 onNewBoard: {
                     model.createBoard()
                     if model.board != nil { showingHome = false }
                 })
    }

    private var dialogAndCommandLayer: some View {
        let content = rootContent
            .onReceive(NotificationCenter.default.publisher(for: .newNoteCommand)) { _ in
                if !showingHome { addNoteInViewport() }
            }
        let base = content
        .background(workspaceBackground)
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
        .tint(colorScheme == .dark
              ? Color(red: 1.0, green: 0.71, blue: 0.54)
              : Color(red: 0.58, green: 0.25, blue: 0.13))
        .onAppear { model.homeVisible = showingHome; registerAuxiliaryWindows() }
        .onChange(of: showingHome) { _, visible in model.homeVisible = visible }
        .onChange(of: model.board?.id) { _, id in
            followExtent = .zero
            sidebarSelection = id.map { [$0] } ?? []
            sidebarSelectionAnchor = id
            tool = .note
            shapeDraft = nil
        }
        .onChange(of: model.pendingInlineEditID) { _, id in
            guard let id, let note = model.board?.notes.first(where: { $0.id == id }) else { return }
            beginInlineEditing(note)
            model.pendingInlineEditID = nil
        }
        .onReceive(timer) { _ in model.poll(); cloudAccount.tick(); presence.pulse() }
        .onReceive(NotificationCenter.default.publisher(for: .createGroupCommand)) { _ in requestGroup() }
        .onReceive(NotificationCenter.default.publisher(for: .requestDeleteSelectionCommand)) { _ in requestDeleteSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .showProjectFiles)) { _ in openProjectFiles() }
        .onReceive(NotificationCenter.default.publisher(for: .wallpaperCommand)) { _ in openWallpaper() }
        .onReceive(NotificationCenter.default.publisher(for: .exportPDFCommand)) { _ in openPDFExport() }
        .onReceive(NotificationCenter.default.publisher(for: .zoomInCommand)) { _ in zoomStep(1) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOutCommand)) { _ in zoomStep(-1) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomResetCommand)) { _ in presence.stopFollowing(); zoom = 1.0 }
        .onExitCommand {
            if showingHome { showingHome = false }
            else { model.connectingFrom = nil; selectionStart = nil; selectionEnd = nil; connectionDrag = nil; drawingGroup = false; tool = .note; shapeDraft = nil }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        return base
        .confirmationDialog("Delete this board?", isPresented: $showingDeleteBoard) {
            Button("Delete Board", role: .destructive) { model.deleteBoard() }
        } message: { Text("This removes the board and its history. The deletion syncs to its connected web workspace.") }
        .confirmationDialog("Delete \(sidebarSelection.count) boards?", isPresented: $showingDeleteBoards, titleVisibility: .visible) {
            Button("Delete \(sidebarSelection.count) Boards", role: .destructive) {
                model.deleteBoards(Array(sidebarSelection))
                sidebarSelection = []
                sidebarSelectionAnchor = nil
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This removes \(sidebarSelection.count) boards and their history. The deletions sync to their connected web workspace.") }
        .confirmationDialog("Delete this list?", isPresented: $showingDeleteList) {
            Button("Delete List", role: .destructive) { if let list = listToDelete { model.deleteList(list) }; listToDelete = nil }
        } message: { Text("Boards in the list will remain available.") }
        .confirmationDialog("Delete \(model.selectionCount) selected objects?", isPresented: $showingDeleteSelection, titleVisibility: .visible) {
            Button("Delete \(model.selectionCount) Objects", role: .destructive) { model.deleteSelection() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Connections attached to deleted notes are removed too. Undo can restore everything in one step.")
        }
        .sheet(isPresented: $showingProjectFiles) {
            if let board = model.board {
                ProjectFilesView(model: model, boardID: board.id)
                    .frame(minWidth: 640, minHeight: 420)
            }
        }
        .sheet(isPresented: $cloudAccount.showingPanel) { CloudAccountView(account: cloudAccount) }
        .sheet(isPresented: $showingReminders) {
            if let board = model.board {
                BoardRemindersView(board: board, boxID: reminderBoxID) { id, title in
                    let point = CGPoint(x: max(0, viewport.midX / zoom - 120), y: max(0, viewport.midY / zoom - 54))
                    return model.placeReminder(id, title: title, boardID: board.id, at: point, in: reminderBoxID)
                }.id(board.id)
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
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search boards and notes", text: $search)
                        .textFieldStyle(.plain).accessibilityLabel("Search boards and notes")
                        .frame(minWidth: 60)
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
                    }
                }
                .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                Button { editingListID = nil; showingListManager = true } label: { Image(systemName: "folder.badge.gearshape").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).modifier(GlassControl()).help("Create, rename, or delete lists").accessibilityLabel("Manage lists")
                Button {
                    let previousID = model.board?.id
                    model.createBoard()
                    if let board = model.board, board.id != previousID, focusedListID == model.deskListID {
                        model.toggleDesk(board)
                    } else if let id = model.board?.id, id != previousID, var list = model.boardLists.first(where: { $0.id == focusedListID }) {
                        list.boardIDs.append(id)
                        if model.saveList(list) { foldedLists.remove(list.id) } else { focusedListID = nil }
                    }
                } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).modifier(GlassControl()).help("New board").accessibilityLabel("New board")
            }.padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
            Picker("Show lists", selection: $focusedListID) {
                Text("All lists").tag(nil as String?)
                ForEach([model.deskList] + model.boardLists) { list in Text(list.title).tag(Optional(list.id)) }
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            .onChange(of: focusedListID) { _, id in
                if let id { foldedLists.remove(id) }
                sidebarSelection = []
                sidebarSelectionAnchor = nil
            }
            .onChange(of: model.boardLists.map(\.id)) { _, ids in
                if let focusedListID, focusedListID != model.deskListID, !ids.contains(focusedListID) { self.focusedListID = nil }
            }
            List {
                ForEach(visibleLists) { list in
                    Section(isExpanded: Binding(get: { !foldedLists.contains(list.id) || !search.isEmpty }, set: { expanded in
                        if expanded { foldedLists.remove(list.id) } else { foldedLists.insert(list.id) }
                    })) {
                        let boards = boardsInList(list)
                        ForEach(boards) { board in
                            sidebarBoardRow(board)
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1).allowsHitTesting(false) }
                        }
                        if boards.isEmpty {
                            Text(search.isEmpty ? "No boards" : "No matches").font(.caption).foregroundStyle(.secondary).padding(.leading, 14)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: list.id == model.deskListID ? "tray.full" : "folder.fill").foregroundStyle(Color(hex: list.color))
                            Text(list.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                            if list.flagged { Image(systemName: "flag.fill").font(.caption2) }
                            Spacer(minLength: 2)
                            Text(String(list.boardIDs.count)).monospacedDigit().foregroundStyle(.secondary)
                            if list.id != model.deskListID {
                                Menu {
                                    HomePinButton(model: model, list: list)
                                    Button("Rename or Edit…") { editingListID = list.id; showingListManager = true }
                                    Button("Delete List…", role: .destructive) { listToDelete = list; showingDeleteList = true }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for \(list.title)")
                            }
                        }.help(list.title)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in handleBoardDrop(providers, targetList: list) }
                    }
                }
                if focusedListID == nil {
                    Section {
                        ForEach(unfiledBoards) { board in sidebarBoardRow(board) }
                    } header: {
                        Text("Unfiled boards").frame(maxWidth: .infinity, alignment: .leading)
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in handleBoardDrop(providers, targetList: nil) }
                    }
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            HStack(spacing: 9) {
                Button("Import", systemImage: "square.and.arrow.down", action: model.importBoard)
                    .buttonStyle(.plain).modifier(GlassControl()).help("Import board")
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                    if !model.draftBlocked { showingBoardSettings = true }
                } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.plain).modifier(GlassControl()).disabled(model.board == nil).help("Board settings").accessibilityLabel("Board settings")
                Button { sidebarTrashAction() } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).modifier(GlassControl()).disabled(model.board == nil).help("Delete board").accessibilityLabel("Delete board")
            }.padding(.horizontal, 12).padding(.vertical, 12)
        }.background(.thinMaterial)
    }

    func boardSidebarLabel(_ board: Board) -> some View {
        HStack(spacing: 8) {
            if let icon = board.icon, !icon.isEmpty {
                Text(icon).font(.system(size: 15))
            } else {
                Image(systemName: "square.grid.2x2").foregroundStyle(Color(hex: board.color ?? "#7A8BA8"))
            }
            Text(board.title).lineLimit(1)
            if board.flagged == true { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .onDrag { NSItemProvider(object: board.id as NSString) }
    }

    func sidebarBoardRow(_ board: Board) -> some View {
        boardSidebarLabel(board)
            .contentShape(Rectangle())
            .onTapGesture { sidebarRowTap(board.id) }
            .onDrop(of: [UTType.plainText], delegate: SidebarRowDropDelegate(board: board, workspace: self))
            .listRowBackground(Group {
                if model.board?.id == board.id || sidebarSelection.contains(board.id) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.16))
                }
                if dropVisible && dropRowID == board.id {
                    GeometryReader { geo in
                        Capsule().fill(Color.accentColor).frame(width: geo.size.width - 16, height: 3)
                            .frame(maxWidth: .infinity)
                            .offset(y: dropBelow ? geo.size.height - 3 : 0).padding(.horizontal, 8)
                    }
                }
            })
    }

    var visibleLists: [BoardList] {
        ([model.deskList] + model.boardLists).filter { focusedListID == nil || $0.id == focusedListID }
    }

    func boardsInList(_ list: BoardList) -> [Board] {
        HomeBoardScope.list(id: list.id).boards(model.boards, lists: [list], search: search)
    }

    var unfiledBoards: [Board] {
        HomeBoardScope.unfiled.boards(model.boards, lists: [model.deskList] + model.boardLists, search: search)
    }

    var sidebarVisibleOrder: [String] {
        var seen = Set<String>()
        let lists = visibleLists.filter { !foldedLists.contains($0.id) || !search.isEmpty }
        return (lists.flatMap(boardsInList) + (focusedListID == nil ? unfiledBoards : []))
            .map(\.id).filter { seen.insert($0).inserted }
    }

    func sidebarRowTap(_ id: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if sidebarSelection.isEmpty, let current = model.board?.id { sidebarSelection = [current] }
            if sidebarSelection.contains(id) { sidebarSelection.remove(id) } else { sidebarSelection.insert(id) }
            return
        }
        if flags.contains(.shift), let start = sidebarSelectionAnchor ?? model.board?.id {
            let order = sidebarVisibleOrder
            if let i = order.firstIndex(of: start), let j = order.firstIndex(of: id), i != j {
                let (lo, hi) = i < j ? (i, j) : (j, i)
                sidebarSelection = Set(order[lo...hi])
                return
            }
        }
        sidebarSelection = [id]
        sidebarSelectionAnchor = id
        model.selectBoard(id)
    }

    func performReorderDrop(_ providers: [NSItemProvider], target: Board) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.utf8-plain-text", options: nil) { item, _ in
            let boardID: String? = {
                if let text = item as? String { return text as String }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }()
            Task { @MainActor in
                defer { self.dropRowID = nil; self.dropVisible = false; self.dropBelow = false }
                guard let boardID else { return }
                let sibling = self.dropRowID ?? target.id
                let anchor = self.dropBelow ? BoardAnchor.after(sibling) : BoardAnchor.before(sibling)
                self.model.moveBoard(id: boardID, to: anchor)
            }
        }
        return true
    }

    /// Drops a dragged board onto a list header (moves it into the list) or onto the
    /// "All boards" header (removes it from every list). Returns whether the drop is accepted.
    func handleBoardDrop(_ providers: [NSItemProvider], targetList: BoardList?) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.utf8-plain-text", options: nil) { item, _ in
            let boardID: String? = {
                if let text = item as? String { return text as String }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }()
            Task { @MainActor in
                guard let boardID else { return }
                if targetList?.id == self.model.deskListID {
                    if !self.model.deskIDs.contains(boardID), let board = self.model.boards.first(where: { $0.id == boardID }) {
                        self.model.toggleDesk(board)
                    }
                } else if let targetList, let list = self.model.boardLists.first(where: { $0.id == targetList.id }) {
                    guard !list.boardIDs.contains(boardID) else { return }
                    var updated = list
                    updated.boardIDs.append(boardID)
                    _ = self.model.saveList(updated)
                } else if targetList == nil {
                    if self.model.deskIDs.contains(boardID), let board = self.model.boards.first(where: { $0.id == boardID }) {
                        self.model.toggleDesk(board)
                    }
                    for var list in self.model.boardLists where list.boardIDs.contains(boardID) {
                        list.boardIDs.removeAll { $0 == boardID }
                        _ = self.model.saveList(list)
                    }
                }
            }
        }
        return true
    }

    struct SidebarRowDropDelegate: DropDelegate {
        let board: Board
        let workspace: WorkspaceView

        func dropEntered(info: DropInfo) {
            if workspace.dropRowID == board.id { return }
            let order = workspace.sidebarVisibleOrder
            if let old = workspace.dropRowID, let i = order.firstIndex(of: old), let j = order.firstIndex(of: board.id) {
                workspace.dropBelow = j < i
            } else {
                workspace.dropBelow = false
            }
            workspace.dropRowID = board.id
            workspace.dropVisible = true
        }

        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

        // Only the row owning the indicator may hide it; a late dropExited from the
        // previous row must not hide a hover that dropEntered already moved elsewhere.
        func dropExited(info: DropInfo) {
            if workspace.dropRowID == board.id { workspace.dropVisible = false }
        }

        func performDrop(info: DropInfo) -> Bool {
            _ = workspace.performReorderDrop(info.itemProviders(for: [UTType.plainText]), target: board)
            return true
        }
    }

    func sidebarTrashAction() {
        if sidebarSelection.count > 1 { showingDeleteBoards = true }
        else { showingDeleteBoard = true }
    }

    /// Registers auxiliary window factories with the LIVE model/session instances.
    /// Doing this in App.init captured pre-@StateObject instances that never updated.
    func registerAuxiliaryWindows() {
        let model = self.model
        let session = self.agentSession
        AuxiliaryWindowHost.shared.register(id: "agent-chat") {
            let size = NSSize(width: 400, height: 680)
            return AuxiliaryWindowHost.makeWindow(
                title: "Agent chat",
                content: AgentChatWindow(model: model, session: session),
                size: size,
                screenOrigin: AuxiliaryWindowHost.bottomRightOrigin(for: size)
            )
        }
        AuxiliaryWindowHost.shared.register(id: "agent-settings") {
            AuxiliaryWindowHost.makeWindow(
                title: "Agent chat settings",
                content: AgentChatSettingsWindow(model: model, session: session),
                size: NSSize(width: 460, height: 640)
            )
        }
        AuxiliaryWindowHost.shared.register(id: "mcp-servers") {
            AuxiliaryWindowHost.makeWindow(
                title: "MCP servers",
                content: MCPServersWindow(model: model, session: session),
                size: NSSize(width: 540, height: 560)
            )
        }
        AuxiliaryWindowHost.shared.register(id: "chat-history") {
            AuxiliaryWindowHost.makeWindow(
                title: "Chat history",
                content: ChatHistoryWindow(model: model, session: session),
                size: NSSize(width: 480, height: 560)
            )
        }
    }

    func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            showBoardSidebar.toggle()
        }
    }

    func setInspectorVisibility(_ visibility: InspectorVisibility) {
        if showInspector && !visibility.isVisible(hasSelection: model.hasSelection) {
            NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
            guard !model.draftBlocked else { return }
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            inspectorVisibilityRaw = visibility.rawValue
        }
    }

    func toggleInspector() {
        setInspectorVisibility(inspectorVisibility.toggled(hasSelection: model.hasSelection))
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

    func requestDeleteSelection() {
        guard model.hasSelection else { return }
        if model.selectionCount > 1 { showingDeleteSelection = true } else { model.deleteSelection() }
    }

    func focusNoteForContextMenu(_ note: Note) {
        if !(model.selectedNoteID == note.id || model.selectedNoteIDs.contains(note.id)) {
            model.chooseNote(note.id)
        }
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

    func chooseAttachments() {
        guard let board = model.board else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let point = CGPoint(x: max(0, viewport.midX / zoom - 100), y: max(0, viewport.midY / zoom - 50))
        model.importFiles(panel.urls, boardID: board.id, at: point)
    }

    func addNoteInViewport() {
        finishInlineEditing()
        guard viewport.width > 0, viewport.height > 0 else {
            model.addNote()
            return
        }
        let x = max(0, viewport.midX / zoom - 95)
        let y = max(0, viewport.midY / zoom - 50)
        model.addNote(x: x, y: y)
        canvasFocused = true
    }

    func zoomStep(_ direction: Double) {
        presence.stopFollowing()
        // Round to one decimal first so repeated steps don't drift (e.g. 0.7 + 0.1 → 0.7999…)
        let base = (zoom * 10).rounded()
        zoom = min(2.0, max(0.5, (base + direction) / 10))
    }

    private func openReminders(in boxID: String? = nil) {
        reminderBoxID = boxID
        showingReminders = true
    }

    private func reminderMenu(_ board: Board?) -> some View {
        let selectedBox = board?.notes.first { $0.id == model.selectedNoteID && $0.reminderID != nil }
        return Menu {
            if let selectedBox {
                Button("Add to Selected Box…") { openReminders(in: selectedBox.id) }
            }
            Button("New Reminder Box…") { openReminders() }
        } label: {
            Image(systemName: "checklist").frame(width: 24, height: 26)
        } primaryAction: {
            openReminders(in: selectedBox?.id)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Add reminder")
        .help(selectedBox == nil ? "Add a reminder box" : "Add a reminder to the selected box")
    }

    func toolbar(_ board: Board?) -> some View {
        HStack(spacing: 10) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left").frame(width: 22, height: 26)
            }
            .help(showBoardSidebar ? "Hide boards (⌘⌥1)" : "Show boards (⌘⌥1)")
            .accessibilityLabel(showBoardSidebar ? "Hide boards" : "Show boards")
            .accessibilityValue(showBoardSidebar ? "Visible" : "Hidden")
            .keyboardShortcut("1", modifiers: [.command, .option])

            Button { showingHome = true } label: { Image(systemName: "house").frame(width: 22, height: 26) }
                .help("Home — all boards (⌘⇧H)")
                .accessibilityLabel("Home")
                .keyboardShortcut("h", modifiers: [.command, .shift])

            if let board {
                DeskButton(model: model, board: board)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(board.map(\.displayTitle) ?? "CoThink Board")
                    .font(.headline).lineLimit(1)
                if case .select = tool {
                    toolStatusRow("Drag to select · Esc to cancel")
                } else if case .shape(let kind) = tool {
                    toolStatusRow("\(kind.rawValue) · place on canvas · Esc to cancel")
                } else if model.connectingFrom != nil {
                    Text("Select another note to connect").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if drawingGroup {
                    Text("Drag to draw a group · Esc to cancel").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let start = selectionStart, let end = selectionEnd, let board {
                    let hidden = board.hiddenNoteIDs()
                    let count = board.notes.filter { !hidden.contains($0.id) && BoardRect.selection(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y).containsCenter(of: $0) }.count
                    Text("Selecting \(count) note\(count == 1 ? "" : "s")…").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if !model.selectedNoteIDs.isEmpty {
                    Text("\(model.selectedNoteIDs.count) notes selected · ⌘C to copy").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let list = model.boardLists.first(where: { $0.boardIDs.contains(board?.id ?? "") }) {
                    Label(list.title, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 3) {
                Button("Select", systemImage: "cursorarrow") {
                    tool = tool == .select ? .note : .select
                }
                .modifier(WorkspaceToolStyle(isActive: tool == .select))
                .help("Select mode: drag without creating notes (V); click again for the note tool (N)")
                .accessibilityLabel(tool == .select ? "Switch to the note tool" : "Switch to the select tool")
                .accessibilityValue(tool == .select ? "Active" : "Inactive")

                Button("Note", systemImage: "plus.square") { addNoteInViewport() }
                    .modifier(WorkspaceToolStyle())
                    .help("Add a note (⌘N)")
                reminderMenu(board)
                Menu {
                    Button("Rectangle") { tool = .shape(.rectangle) }
                    Button("Ellipse") { tool = .shape(.ellipse) }
                    Button("Diamond") { tool = .shape(.diamond) }
                    Button("Line") { tool = .shape(.line) }
                    Button("Text") { tool = .shape(.text) }
                } label: { Label("Shape", systemImage: "square.on.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .modifier(WorkspaceToolStyle(isActive: { if case .shape = tool { return true }; return false }()))
                    .help("Add a diagram shape")
                Button(drawingGroup ? "Cancel group" : "Group", systemImage: "square.dashed") { requestGroup() }
                    .modifier(WorkspaceToolStyle(isActive: drawingGroup))
                    .help(drawingGroup ? "Cancel drawing a group" : "Group selected notes or draw a group (⇧⌘G)")
                    .accessibilityValue(drawingGroup ? "Active" : "Inactive")
                Button("Connect", systemImage: "arrow.up.right") { model.beginConnection() }
                    .modifier(WorkspaceToolStyle(isActive: model.connectingFrom != nil))
                    .disabled(model.selectedNoteID == nil)
                    .help("Select a note then select another (⌘L), or drag its connection handle")
            }
            .disabled(board == nil)
            .padding(3)
            .modifier(GlassFloatingSurface())

            HStack(spacing: 2) {
                Button { zoomStep(-1) } label: { Image(systemName: "minus").frame(width: 24, height: 26) }
                    .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
                Button { presence.stopFollowing(); zoom = 1.0 } label: {
                    Text("\(Int(zoom * 100))%")
                        .font(.caption.monospacedDigit()).frame(width: 38)
                }
                .help("Reset zoom to 100% (⌘0)")
                .accessibilityLabel("Reset zoom to 100 percent; current zoom \(Int(zoom * 100)) percent")
                Button { zoomStep(1) } label: { Image(systemName: "plus").frame(width: 24, height: 26) }
                    .help("Zoom in (⌘+)").accessibilityLabel("Zoom in")
            }
            .disabled(board == nil)

            Menu {
                Section("Board") {
                    Button("Attach Files…", systemImage: "paperclip", action: chooseAttachments).disabled(board == nil)
                    Button("Reminders…", systemImage: "checklist") { openReminders() }.disabled(board == nil)
                    Button("Project Files…", systemImage: "folder", action: openProjectFiles).disabled(board == nil)
                    Button("Change Wallpaper…", systemImage: "photo.on.rectangle.angled", action: openWallpaper).disabled(board == nil)
                    Button("Export as JSON…", action: model.exportBoard).disabled(board == nil)
                    Button("Export as PDF…", action: openPDFExport).disabled(board == nil)
                }
                Section("View") {
                    Menu("Inspector") {
                        Button { setInspectorVisibility(.automatic) } label: { themeLabel("Automatic", selected: inspectorVisibility == .automatic) }
                        Button { setInspectorVisibility(.shown) } label: { themeLabel("Always Show", selected: inspectorVisibility == .shown) }
                        Button { setInspectorVisibility(.hidden) } label: { themeLabel("Always Hide", selected: inspectorVisibility == .hidden) }
                    }
                    Menu("Appearance") {
                        Button { appearanceMode = "system" } label: { themeLabel("System", selected: appearanceMode == "system") }
                        Button { appearanceMode = "light" } label: { themeLabel("Light", selected: appearanceMode == "light") }
                        Button { appearanceMode = "dark" } label: { themeLabel("Dark", selected: appearanceMode == "dark") }
                    }
                }
                Button("Account & Sync…", systemImage: "person.crop.circle") { cloudAccount.showingPanel = true }
                Section("AI") {
                    Button("Connect an AI Agent…", systemImage: "point.3.connected.trianglepath.dotted") { showingMCP.toggle() }
                }
            } label: { Label("Workspace", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Board, view, and AI actions")
                .accessibilityLabel("Workspace actions")
                .popover(isPresented: $showingMCP) { MCPSetupView() }

            if let board {
                BoardPeopleButton(board: board, account: cloudAccount, presence: presence)
                    .id(board.id)
            }
            Button(action: toggleInspector) {
                Image(systemName: "sidebar.right").frame(width: 22, height: 26)
            }
            .help(showInspector ? "Hide inspector (⌘⌥2)" : "Show inspector (⌘⌥2)")
            .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
            .accessibilityValue("\(showInspector ? "Visible" : "Hidden"), \(inspectorVisibility.rawValue)")
            .keyboardShortcut("2", modifiers: [.command, .option])
            Button { AuxiliaryWindowHost.shared.open(id: "agent-chat") } label: {
                HStack(spacing: 5) {
                    MascotLogo().frame(width: 27, height: 27).padding(3).accessibilityHidden(true)
                    AppVersionLabel()
                }
            }
            .help("Open the agent chat window")
            .accessibilityLabel("Open the agent chat window")
            .disabled(board == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.06)).frame(height: 1) }
    }

    @ViewBuilder
    private func toolStatusRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Button {
                tool = .note
                shapeDraft = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to the note tool (N)")
            .accessibilityLabel("Cancel the active tool")
        }
    }

    @ViewBuilder
    func themeLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func presenceBadges(_ board: Board, indexes: BoardIndexes, hidden: Set<String>, movement: CanvasDragMovement?) -> some View {
        let others = presence.people.filter { $0.id != cloudAccount.login?.user.id }
        let ids = Set(others.flatMap(\.objectIDs)).sorted()
        func anchor(_ id: String) -> CGPoint? {
            if let note = indexes.note(id), !hidden.contains(id) {
                let shown = displayed(note, movement: movement)
                return CGPoint(x: shown.x + shown.width - 4, y: max(10, shown.y + 2))
            }
            if let group = board.groups.first(where: { $0.id == id }) {
                let rect = displayedGroupRect(group, movement: movement)
                return CGPoint(x: rect.x + rect.width - 4, y: max(10, rect.y + 2))
            }
            if let edge = board.connections.first(where: { $0.id == id }),
               !hidden.contains(edge.from), !hidden.contains(edge.to),
               let a = indexes.note(edge.from), let b = indexes.note(edge.to) {
                return ConnectionGeometry(from: displayed(a, movement: movement), to: displayed(b, movement: movement),
                                          edge: displayedConnection(edge)).labelPosition
            }
            return nil
        }
        return ForEach(ids, id: \.self) { id in
            if let point = anchor(id) {
                let people = others.filter { $0.objectIDs.contains(id) }
                HStack(spacing: -4) {
                    ForEach(people) { person in
                        ProfileFace(id: person.avatar, size: 24)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    }
                }
                .shadow(radius: 1).position(point).allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Editing: " + people.map(\.email).joined(separator: ", "))
            }
        }
    }

    func boardCanvas(_ board: Board) -> some View {
        let hidden = board.hiddenNoteIDs()
        let indexes = BoardIndexes(board: board)
        let movement = canvasDragMovement(board)
        let noteRects = board.notes.filter { !hidden.contains($0.id) }.map { note in
            let note = displayed(note, movement: movement)
            return BoardRect(x: note.x, y: note.y, width: note.width, height: note.height)
        }
        let routeRects = board.connections.flatMap { edge -> [BoardRect] in
            guard !hidden.contains(edge.from), !hidden.contains(edge.to),
                  let from = indexes.note(edge.from), let to = indexes.note(edge.to) else { return [] }
            return displayedConnection(edge).controlPoints(from: displayed(from, movement: movement), to: displayed(to, movement: movement)).map { BoardRect(x: $0.x, y: $0.y, width: 0, height: 0) }
        }
        let baseExtent = BoardRect.canvasExtent(containing: noteRects + board.groups.map { displayedGroupRect($0, movement: movement) } + routeRects)
        let extent = (width: max(baseExtent.width, followExtent.width), height: max(baseExtent.height, followExtent.height))
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                WallpaperBackgroundView(board: board,
                                        folder: board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model.defaultProjectFilesDirectory(for: board.id),
                                        width: extent.width, height: extent.height, colorScheme: colorScheme)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2, coordinateSpace: .local)
                        .exclusively(before: SpatialTapGesture(count: 1, coordinateSpace: .local))
                        .onEnded { result in
                            switch result {
                            case .first(let tap):
                                finishInlineEditing()
                                switch tool {
                                case .select:
                                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                                    guard !model.draftBlocked else { return }
                                    model.clearSelection()
                                case .shape(let kind):
                                    model.addShape(kind, frame: BoardRect(x: tap.location.x, y: tap.location.y, width: 160, height: kind == .line ? 80 : kind == .text ? 40 : 120), flipped: false)
                                case .note:
                                    model.addNote(x: max(0, tap.location.x - 95), y: max(0, tap.location.y - 50))
                                }
                                canvasFocused = true
                            case .second:
                                finishInlineEditing()
                                NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                                guard !model.draftBlocked else { return }
                                model.clearSelection()
                                canvasFocused = true
                            }
                        })
                    .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("boardCanvas"))
                        .onChanged { value in
                            // While a shape tool is armed, ⌘-drag still marquees.
                            if case .shape = tool, selectionStart == nil, shapeDraft != nil || !NSEvent.modifierFlags.contains(.command) {
                                if shapeDraft == nil {
                                    finishInlineEditing()
                                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                                    guard !model.draftBlocked else { return }
                                }
                                let start = value.startLocation
                                let dx = value.location.x - start.x, dy = value.location.y - start.y
                                shapeDraft = CGRect(x: min(start.x, value.location.x), y: min(start.y, value.location.y),
                                                    width: abs(dx), height: abs(dy))
                                shapeDraftFlipped = (dx > 0) != (dy > 0)
                                return
                            }
                            if selectionStart == nil {
                                finishInlineEditing()
                                NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                                guard !model.draftBlocked else { return }
                                selectionStart = value.startLocation
                            }
                            selectionEnd = value.location
                        }.onEnded { value in
                            if case .shape(let kind) = tool, shapeDraft != nil {
                                defer { shapeDraft = nil }
                                guard !model.draftBlocked else { return }
                                let dx = value.location.x - value.startLocation.x
                                let dy = value.location.y - value.startLocation.y
                                let frame: BoardRect
                                let flipped: Bool
                                if abs(dx) < 8, abs(dy) < 8 {
                                    frame = BoardRect(x: value.startLocation.x, y: value.startLocation.y, width: 160, height: kind == .line ? 80 : kind == .text ? 40 : 120)
                                    flipped = false
                                } else {
                                    frame = BoardRect(x: min(value.startLocation.x, value.location.x),
                                                      y: min(value.startLocation.y, value.location.y),
                                                      width: kind == .line ? abs(dx) : max(1, abs(dx)),
                                                      height: kind == .line ? abs(dy) : max(1, abs(dy)))
                                    flipped = kind == .line && (dx > 0) != (dy > 0)
                                }
                                model.addShape(kind, frame: frame, flipped: flipped)
                                return
                            }
                            defer { selectionStart = nil; selectionEnd = nil }
                            guard let start = selectionStart, !model.draftBlocked else { return }
                            let rect = BoardRect.selection(fromX: start.x, fromY: start.y, toX: value.location.x, toY: value.location.y)
                            guard rect.width >= 20, rect.height >= 20 else { return }
                            if drawingGroup {
                                model.createGroup(in: rect)
                                drawingGroup = false
                            } else { model.selectNotes(in: rect, additive: NSEvent.modifierFlags.contains(.shift)) }
                            canvasFocused = true
                        })
                    .contextMenu {
                        Button("Paste as New Note") { model.pasteSelection() }.disabled(!model.canPaste)
                        Divider()
                        Button("New Note") { addNoteInViewport() }
                        Button("Attach Files…", action: chooseAttachments)
                        Button("Reminders…") { openReminders() }
                    }
                ForEach(board.groups) { group in groupView(group, movement: movement) }
                ForEach(board.notes.filter { note in
                    guard let parentID = note.parentID else { return false }
                    return !hidden.contains(note.id) && !hidden.contains(parentID)
                }) { note in
                    if let parent = indexes.note(note.parentID) {
                        TreeEdgeView(from: displayed(parent, movement: movement), to: displayed(note, movement: movement), canvasWidth: extent.width, canvasHeight: extent.height)
                    }
                }
                ForEach(board.connections) { edge in
                    if !hidden.contains(edge.from) && !hidden.contains(edge.to),
                       let from = indexes.note(edge.from), let to = indexes.note(edge.to) {
                        ConnectionView(from: displayed(from, movement: movement), to: displayed(to, movement: movement), edge: displayedConnection(edge), selected: model.selectedConnectionID == edge.id, canvasWidth: extent.width, canvasHeight: extent.height)
                            .onTapGesture {
                                selectConnection(edge.id)
                            }
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                selectConnection(edge.id)
                                if model.selectedConnectionID == edge.id && !showInspector {
                                    setInspectorVisibility(.shown)
                                }
                            })
                    }
                }
                ForEach(board.notes.filter { !hidden.contains($0.id) }) { note in noteView(note, board: board, indexes: indexes, movement: movement) }
                presenceBadges(board, indexes: indexes, hidden: hidden, movement: movement)
                if let start = selectionStart, let end = selectionEnd {
                    let rect = BoardRect.selection(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y)
                    Rectangle().fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
                        .allowsHitTesting(false)
                }
                if case .shape(let tool) = tool, let draft = shapeDraft {
                    let preview: AnyShape = switch tool {
                    case .rectangle, .text: AnyShape(RoundedRectangle(cornerRadius: 6))
                    case .ellipse: AnyShape(Ellipse())
                    case .diamond: AnyShape(Diamond())
                    case .line: AnyShape(DiagonalLine(flipped: shapeDraftFlipped))
                    }
                    preview
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: draft.width, height: draft.height)
                        .position(x: draft.midX, y: draft.midY)
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
                    resizeHandles(id: note.id, rect: BoardRect(x: note.x, y: note.y, width: note.width, height: note.height), isNote: true,
                                  minWidth: note.extentMinWidth, minHeight: note.extentMinHeight)
                    connectionHandle(note, board: board, movement: movement)
                } else if let group = board.groups.first(where: { $0.id == model.selectedGroupID }), group.positionLocked != true {
                    resizeHandles(id: group.id, rect: BoardRect(x: group.x, y: group.y, width: group.width, height: group.height), isNote: false)
                } else if let edge = board.connections.first(where: { $0.id == model.selectedConnectionID }),
                          let from = indexes.note(edge.from), let to = indexes.note(edge.to) {
                    routeHandles(edge, from: displayed(from, movement: movement), to: displayed(to, movement: movement))
                }
            }
            .frame(width: extent.width, height: extent.height)
            .dropDestination(for: URL.self) { urls, point in
                model.importFiles(urls, boardID: board.id, at: point)
            }
            .overlay(alignment: .topLeading) {
                BoardCursorLayer(feed: presence.cursors, zoom: zoom)
                    .allowsHitTesting(false)
            }
            .background(ScrollViewportObserver(viewport: $viewport, request: $scrollRequest, following: presence.followedCamera, zoom: zoom, manualScroll: presence.stopFollowing))
            .coordinateSpace(name: "boardCanvas")
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: extent.width * zoom, height: extent.height * zoom, alignment: .topLeading)
        }
        .onChange(of: presence.followedCamera) { _, _ in fitFollowedCamera() }
        .onChange(of: viewport) { before, after in
            if before.size != after.size { fitFollowedCamera() }
            publishBoardCamera()
        }
        .onChange(of: zoom) { _, _ in publishBoardCamera() }
        .overlay(alignment: .top) {
            if let id = presence.following {
                HStack {
                    if let person = presence.people.first(where: { $0.id == id }) {
                        ProfileFace(id: person.avatar, size: 21)
                        Text("Following " + person.email).lineLimit(1)
                    }
                    Button("Stop following", action: presence.stopFollowing)
                }.font(.callout).padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 8)
            }
        }
        .overlay(alignment: .bottom) { BoardInvitationBanner(presence: presence) }
        .modifier(BoardPointerTracking(presence: presence, boardID: board.id, viewport: viewport, zoom: zoom, active: presencePhase == .active))
        .overlay(alignment: .bottomTrailing) {
            BoardMinimap(board: board, extent: CGSize(width: extent.width, height: extent.height), zoom: zoom, viewport: viewport) { presence.stopFollowing(); scrollRequest = $0 }
                .padding(14)
        }
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .background(CanvasShortcutMonitor { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // While the inline note editor is open, Tab/⇧Tab commit the edit and create the
            // next note with the same routing as the selection shortcut. This branch must run
            // before canvasAcceptsShortcuts, which excludes the editing state on purpose.
            if event.keyCode == 48, modifiers == .shift || modifiers.isEmpty,
               let editingID = editingObjectID, !editingGroupTitle {
                finishInlineEditing()
                model.addViaTab(from: editingID, shift: modifiers == .shift)
                return true
            }
            // ⇧Enter while editing a CHILD note creates its sibling (the Return shortcut's
            // tree action). Child-only on purpose: plain Enter stays a newline everywhere,
            // and root notes keep ⇧Enter as a newline too.
            if event.keyCode == 36 || event.keyCode == 76, modifiers == .shift,
               let editingID = editingObjectID, !editingGroupTitle,
               model.board?.notes.first(where: { $0.id == editingID })?.parentID != nil {
                finishInlineEditing()
                model.addSiblingNote(to: editingID)
                return true
            }
            guard canvasAcceptsShortcuts else { return false }
            if modifiers.isEmpty, (event.keyCode == 51 || event.keyCode == 117), model.hasSelection {
                requestDeleteSelection()
                return true
            }
            if modifiers == .shift, event.keyCode == 48, let selected = model.selectedNoteID {
                model.addViaTab(from: selected, shift: true)
                return true
            }
            if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "v" {
                tool = .select
                shapeDraft = nil
                return true
            }
            if modifiers.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "n" {
                tool = .note
                shapeDraft = nil
                return true
            }
            if modifiers.isEmpty, let selected = model.selectedNoteID {
                if event.keyCode == 48 {
                    model.addViaTab(from: selected, shift: false)
                    return true
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    if model.board?.isTreeLinked(noteID: selected) == true { model.addSiblingNote(to: selected) }
                    else { model.addAdjacentNote(toRight: false) }
                    return true
                }
            }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c", model.hasSelection { model.copySelection(); return true }
            if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v", model.canPaste { model.pasteSelection(); return true }
            return false
        })
        .onKeyPress(.delete) {
            guard model.hasSelection, editingObjectID == nil,
                  !(NSApp.keyWindow?.firstResponder is NSTextView),
                  !(NSApp.keyWindow?.firstResponder is NSTextField) else { return .ignored }
            requestDeleteSelection()
            return .handled
        }
        .onDeleteCommand {
            guard editingObjectID == nil, !(NSApp.keyWindow?.firstResponder is NSTextView), !(NSApp.keyWindow?.firstResponder is NSTextField) else { return }
            requestDeleteSelection()
        }
        .simultaneousGesture(MagnificationGesture()
            .onChanged { value in
                presence.stopFollowing()
                let factor = value / pinchMagnification
                pinchMagnification = value
                zoom = min(2.0, max(0.5, zoom * Double(factor)))
            }
            .onEnded { _ in pinchMagnification = 1 })
    }

    private var canvasAcceptsShortcuts: Bool {
        canvasFocused && editingObjectID == nil && !(NSApp.keyWindow?.firstResponder is NSTextView) && !(NSApp.keyWindow?.firstResponder is NSTextField)
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

    // One selectionMovement/groupMovement resolution per frame, matching the
    // drag mode. A single-note drag keeps groups static on purpose; a selection
    // drag carries the groups its expansion touches.
    func canvasDragMovement(_ board: Board) -> CanvasDragMovement? {
        if draggingSelection {
            let delta = board.selectionMovement(noteIDs: model.selectedNoteIDs, dx: dragTranslation.width, dy: dragTranslation.height)
            return CanvasDragMovement(noteIDs: delta.noteIDs, groupIDs: delta.groupIDs, dx: delta.dx, dy: delta.dy)
        }
        if let draggedID = draggingID, board.notes.contains(where: { $0.id == draggedID }) {
            let delta = board.selectionMovement(noteIDs: [draggedID], dx: dragTranslation.width, dy: dragTranslation.height)
            return CanvasDragMovement(noteIDs: delta.noteIDs, groupIDs: [], dx: delta.dx, dy: delta.dy)
        }
        if let groupID = draggingID, let group = board.groups.first(where: { $0.id == groupID }) {
            let delta = board.groupMovement(id: groupID, dx: dragTranslation.width, dy: dragTranslation.height) ?? (dx: 0, dy: 0)
            return CanvasDragMovement(noteIDs: Set(group.memberIDs ?? []), groupIDs: [groupID], dx: delta.dx, dy: delta.dy)
        }
        return nil
    }

    func displayed(_ note: Note, movement: CanvasDragMovement?) -> Note {
        var result = note
        if let state = resizeState, state.id == note.id {
            let rect = state.preview
            result.x = rect.x; result.y = rect.y; result.width = rect.width; result.height = rect.height
        } else if let movement, movement.noteIDs.contains(note.id) {
            result.x += movement.dx; result.y += movement.dy
        }
        return result
    }

    func connectionHandle(_ note: Note, board: Board, movement: CanvasDragMovement?) -> some View {
        let shown = displayed(note, movement: movement)
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

    func resizeHandles(id: String, rect: BoardRect, isNote: Bool, minWidth: Double = 80, minHeight: Double = 50) -> some View {
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
                        resizeState = ResizeState(id: id, origin: rect, corner: corner, translation: .zero, minWidth: minWidth, minHeight: minHeight)
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

    /// True while the rubber-band selection is being dragged and the note's center
    /// is inside the current rect — previews which notes the marquee will select.
    func marqueeHighlight(_ note: Note) -> Bool {
        guard let start = selectionStart, let end = selectionEnd else { return false }
        return BoardRect.selection(fromX: start.x, fromY: start.y, toX: end.x, toY: end.y).containsCenter(of: note)
    }

    func noteView(_ note: Note, board: Board, indexes: BoardIndexes, movement: CanvasDragMovement?) -> some View {
        NoteTile(
            note: displayed(note, movement: movement),
            boardID: board.id,
            selected: model.selectedNoteID == note.id || model.selectedNoteIDs.contains(note.id) || marqueeHighlight(note),
            isEditing: editingObjectID == note.id && !editingGroupTitle,
            childCount: indexes.childCount(note.id),
            folded: note.collapsed == true,
            imagePath: note.imagePath,
            assets: board.projectAssets,
            projectFilesDirectory: board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? model.defaultProjectFilesDirectory(for: board.id),
            text: Binding(get: { inlineText }, set: { inlineText = $0; scheduleInlineSave() }),
            onFinishEditing: finishInlineEditing,
            onAddReminder: { openReminders(in: note.id) },
            onEdit: {
                if note.shape == .line { model.chooseNote(note.id) }
                else if !note.isReminderBox { beginInlineEditing(note) }
            },
            onOpenFile: { url in
                if !NSWorkspace.shared.open(url) { model.error = "Could not open " + url.lastPathComponent }
            }
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
            .frame(width: displayed(note, movement: movement).width, height: displayed(note, movement: movement).height)
            .position(x: displayed(note, movement: movement).x + displayed(note, movement: movement).width / 2, y: displayed(note, movement: movement).y + displayed(note, movement: movement).height / 2)
            .onTapGesture {
                let inSelection = model.selectedNoteIDs.contains(note.id) || model.selectedNoteID == note.id
                if editingObjectID != note.id { finishInlineEditing() }
                if NSEvent.modifierFlags.contains(.option), model.connectingFrom == nil {
                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                    guard !model.draftBlocked else { return }
                    model.toggleFold(note.id)
                } else if NSEvent.modifierFlags.contains(.shift), model.connectingFrom == nil {
                    NotificationCenter.default.post(name: .flushBoardDraft, object: nil)
                    guard !model.draftBlocked else { return }
                    var ids = model.selectedNoteIDs
                    if let selected = model.selectedNoteID { ids.insert(selected) }
                    // Shift-click toggles the note together with its mindmap subtree;
                    // a childless note toggles exactly itself, so plain notes are unchanged.
                    let branch = (model.board?.descendantIDs(of: note.id) ?? []).union([note.id])
                    if branch.isSubset(of: ids) { ids.subtract(branch) } else { ids.formUnion(branch) }
                    model.selectedNoteID = nil; model.selectedNoteIDs = ids
                    model.selectedGroupID = nil; model.selectedConnectionID = nil
                } else if !inSelection {
                    model.chooseNote(note.id)
                }
                // Clicking a member of the current selection keeps the selection,
                // so pressing on any member and dragging moves the whole selection.
                canvasFocused = true
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("boardCanvas")).onChanged { value in
                if draggingID == nil { finishInlineEditing(); NotificationCenter.default.post(name: .flushBoardDraft, object: nil) }
                guard !model.draftBlocked else { return }
                if draggingID == nil {
                    draggingSelection = model.selectedNoteIDs.contains(note.id)
                    draggingID = draggingSelection ? note.id : (model.board?.groupContaining(noteID: note.id)?.id ?? note.id)
                }
                dragTranslation = value.translation
            }.onEnded { value in
                guard draggingID != nil else { return }
                let wasSelection = draggingSelection
                draggingID = nil; draggingSelection = false; dragTranslation = .zero
                model.mutate { board in
                    let dx = value.translation.width, dy = value.translation.height
                    if wasSelection { board.moveSelection(noteIDs: model.selectedNoteIDs, dx: dx, dy: dy); return }
                    board.moveSelection(noteIDs: [note.id], dx: dx, dy: dy)
                }
            })
            .contextMenu {
                Button("Add Child Note") { focusNoteForContextMenu(note); model.addChild(of: note.id) }
                Button("Add Sibling Note") { focusNoteForContextMenu(note); model.addSiblingNote(to: note.id) }
                Button("Select Subtree") { focusNoteForContextMenu(note); model.selectSubtree(of: note.id) }
                if note.parentID != nil {
                    Button("Remove from Tree") { focusNoteForContextMenu(note); model.detachNote(note.id) }
                }
                Button("Copy") { focusNoteForContextMenu(note); model.copySelection() }
                Button("Duplicate") { focusNoteForContextMenu(note); model.copySelection(); model.pasteSelection() }
                Button("Paste as New Note") { model.pasteSelection() }.disabled(!model.canPaste)
                Divider()
                Button("Delete", role: .destructive) { focusNoteForContextMenu(note); requestDeleteSelection() }
            }
    }

    func displayedGroupRect(_ group: BoardGroup, movement: CanvasDragMovement?) -> BoardRect {
        let dx = movement?.groupIDs.contains(group.id) == true ? movement?.dx ?? 0 : 0
        let dy = movement?.groupIDs.contains(group.id) == true ? movement?.dy ?? 0 : 0
        return resizeState?.id == group.id ? resizeState!.preview : BoardRect(x: group.x + dx, y: group.y + dy, width: group.width, height: group.height)
    }

    func groupView(_ group: BoardGroup, movement: CanvasDragMovement?) -> some View {
        let rect = displayedGroupRect(group, movement: movement)
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
            if editingObjectID != group.id { finishInlineEditing() }
            model.chooseGroup(group.id); canvasFocused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            beginInlineEditing(group)
        })
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("boardCanvas")).onChanged { value in
            if draggingID == nil { finishInlineEditing(); NotificationCenter.default.post(name: .flushBoardDraft, object: nil) }
            guard !model.draftBlocked, group.positionLocked != true else { return }
            draggingID = group.id; dragTranslation = value.translation
        }.onEnded { value in
            guard draggingID == group.id else { return }
            draggingID = nil; dragTranslation = .zero
            model.mutate { board in
                _ = board.moveGroup(id: group.id, dx: value.translation.width, dy: value.translation.height)
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
            let fittedHeight = note.autofitsHeight ? NoteContentSizing.height(for: value, fontSize: note.fontSize ?? 15, width: note.width) : note.height
            model.mutate { current in
                guard let index = current.notes.firstIndex(where: { $0.id == id }) else { return }
                current.notes[index].text = value
                current.notes[index].height = fittedHeight
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

struct AppVersionLabel: View {
    var body: some View {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            Text("v\(version)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .accessibilityLabel("Version \(version)")
        }
    }
}

struct MascotLogo: View {
    var body: some View {
        if let path = Bundle.main.path(forResource: "Mascot", ofType: "png"), let mascot = ImageCache.image(atPath: path) {
            Image(nsImage: mascot).resizable().scaledToFit().accessibilityLabel("CoThink mascot")
        } else {
            Image(systemName: "note.text").resizable().scaledToFit().padding(8).foregroundStyle(.secondary)
        }
    }
}

/// A quiet tool strip that makes the current canvas mode visible without
/// applying the accent color to every action.
struct WorkspaceToolStyle: ViewModifier {
    var isActive = false

    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .frame(minWidth: 30, minHeight: 30)
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
    }
}

struct GlassControl: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.padding(.horizontal, 6).padding(.vertical, 4).glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            content.padding(.horizontal, 6).padding(.vertical, 4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
    }
}

struct GlassFloatingSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1)))
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
    var minWidth: Double = 80
    var minHeight: Double = 50
    var preview: BoardRect { origin.resized(from: corner, dx: translation.width, dy: translation.height, minWidth: minWidth, minHeight: minHeight) }
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
                HStack(spacing: 6) {
                    if group.positionLocked == true { Image(systemName: "lock.fill").accessibilityLabel("Position locked") }
                    Text(group.title.uppercased()).tracking(1)
                }.font(.system(size: group.fontSize ?? 11, weight: .bold)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(width: group.width, height: group.height, alignment: .topLeading)
        .background(Color(hex: group.color).opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color(hex: group.strokeColor ?? "#6F7785"), style: StrokeStyle(lineWidth: group.strokeWidth ?? 1, lineCap: .round, dash: (group.strokeStyle ?? .dashed).dashPattern)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct DiagonalLine: Shape {
    var flipped: Bool = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if flipped {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        return path
    }
}

struct NoteTile: View {
    let note: Note
    let boardID: String
    let selected: Bool
    let isEditing: Bool
    let childCount: Int
    let folded: Bool
    let imagePath: String?
    let assets: [ProjectAsset]
    let projectFilesDirectory: URL
    @Binding var text: String
    let onFinishEditing: () -> Void
    let onAddReminder: () -> Void
    let onEdit: () -> Void
    let onOpenFile: (URL) -> Void

    private var attachedAssets: [ProjectAsset] { assets.filter { note.assetIDs?.contains($0.id) == true } }
    private var isFileCard: Bool { note.text.isEmpty && attachedAssets.count == 1 && note.shape == nil && note.reminderID == nil }
    private var projectImages: [String: NSImage] {
        Dictionary(uniqueKeysWithValues: attachedAssets.compactMap { asset in
            let url = projectFilesDirectory.appendingPathComponent(asset.relativePath)
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
                  let image = ImageCache.image(at: url) else { return nil }
            return (asset.id, image)
        })
    }

    private func imagePreview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @FocusState private var textFocused: Bool

    var body: some View {
        let legacyImage = imagePath.flatMap { ImageCache.image(atPath: $0) }
        let images = projectImages
        let hasPreview = legacyImage != nil || !images.isEmpty
        return Group {
            if note.shape == .line {
                DiagonalLine(flipped: note.lineFlipped == true)
                    .stroke(Color(hex: note.strokeColor ?? "#6F7785"), style: tileBorderStyle)
                    .contentShape(DiagonalLine(flipped: note.lineFlipped == true).stroke(lineWidth: 14))
                    .overlay(selectionRing)
            } else {
            VStack(alignment: note.shape == nil || note.shape == .text ? .leading : .center, spacing: 6) {
                if note.isReminderBox {
                    ReminderBoxContent(note: note, add: note.reminderID == nil ? nil : onAddReminder)
                        .foregroundStyle(Color.readableText(on: note.color))
                } else if isEditing {
                    TextEditor(text: $text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(Color.readableText(on: note.color))
                        .scrollContentBackground(.hidden)
                        .focused($textFocused)
                        .frame(minHeight: imagePath == nil ? 40 : 28)
                        .onChange(of: textFocused) { _, focused in if !focused { onFinishEditing() } }
                        .onAppear { DispatchQueue.main.async { textFocused = true } }
                        .onExitCommand(perform: onFinishEditing)
                } else if note.shape == nil && (!note.text.isEmpty || !hasPreview) {
                    Text(note.text.isEmpty ? ((note.assetIDs ?? []).isEmpty ? "Empty note" : "Attachment") : note.text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(Color.readableText(on: note.color).opacity(note.text.isEmpty ? 0.66 : 1))
                        .layoutPriority(1)
                } else if note.shape == .text {
                    Text(note.text.isEmpty ? "Empty text" : note.text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(.primary.opacity(note.text.isEmpty ? 0.35 : 1))
                } else if !note.text.isEmpty {
                    Text(note.text)
                        .font(.system(size: note.fontSize ?? 15, weight: .medium))
                        .foregroundStyle(Color.readableText(on: note.color))
                        .multilineTextAlignment(.center)
                }
                if let legacyImage {
                    imagePreview(legacyImage).allowsHitTesting(false)
                }
                ForEach(attachedAssets) { asset in
                    let url = projectFilesDirectory.appendingPathComponent(asset.relativePath)
                    Group {
                        if let image = images[asset.id] {
                            imagePreview(image)
                        } else {
                            Label(asset.name, systemImage: assetSymbol(asset.name))
                                .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpenFile(url) }
                    .accessibilityLabel(asset.name)
                    .accessibilityAction(named: "Open file") { onOpenFile(url) }
                    .help("Double-click to open " + asset.name)
                }
                if !hasPreview && (note.shape == nil || note.shape == .text) { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: note.shape == nil || note.shape == .text ? .topLeading : .center)
            .padding(isEditing ? 8 : 16)
            .contentShape(note.shape == .text ? AnyShape(Rectangle()) : tileShape)
            .background {
                if note.shape != .text {
                    tileShape.fill(Color(hex: note.color))
                }
            }
            .overlay {
                if note.shape != .text {
                    tileShape.stroke(Color(hex: note.strokeColor ?? "#6F7785"), style: tileBorderStyle)
                }
            }
            .overlay(selectionRing)
            }
        }
            .onTapGesture(count: 2) {
                if isFileCard, let asset = attachedAssets.first {
                    onOpenFile(projectFilesDirectory.appendingPathComponent(asset.relativePath))
                } else if !isEditing { onEdit() }
            }
            .overlay(alignment: .topLeading) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                        .background(Circle().fill(.regularMaterial))
                        .offset(x: -10, y: -10)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if childCount > 0, !isEditing {
                    Text(folded ? "+\(childCount)" : "\(childCount)")
                        .font(.caption2)
                        .foregroundStyle(folded ? Color.white : Color.primary.opacity(0.55))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(folded ? Color(hex: "#7A8BA8") : Color.primary.opacity(0.10)))
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: selected ? Color.accentColor.opacity(0.55) : .black.opacity(0.07), radius: selected ? 7 : 5, y: selected ? 0 : 2)
    }

    private var tileShape: AnyShape {
        switch note.shape {
        case .rectangle: AnyShape(RoundedRectangle(cornerRadius: 6))
        case .ellipse: AnyShape(Ellipse())
        case .diamond: AnyShape(Diamond())
        default: AnyShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var tileBorderStyle: StrokeStyle {
        StrokeStyle(lineWidth: note.strokeWidth ?? 1, lineCap: .round, dash: (note.strokeStyle ?? .solid).dashPattern)
    }

    @ViewBuilder private var selectionRing: some View {
        switch note.shape {
        case .line, .text:
            RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        case .rectangle, .ellipse, .diamond:
            tileShape.stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
        case nil:
            RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
        }
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

/// Draws the mindmap elbow between a note and its parent. Purely derived from the
/// two notes' positions; never hittable or selectable.
struct TreeEdgeView: View {
    let from: Note
    let to: Note
    let canvasWidth: Double
    let canvasHeight: Double

    var body: some View {
        let start = CGPoint(x: from.x + from.width, y: from.y + from.height / 2)
        let end = CGPoint(x: to.x, y: to.y + to.height / 2)
        let midX = (start.x + end.x) / 2
        let direction = CGPoint(x: end.x - midX >= 0 ? 1 : -1, y: 0)
        return Canvas { context, _ in
            var path = Path()
            path.move(to: start)
            path.addLine(to: CGPoint(x: midX, y: start.y))
            path.addLine(to: CGPoint(x: midX, y: end.y))
            path.addLine(to: end)
            context.stroke(path, with: .color(Color(hex: "#7A8BA8")), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - direction.x * 12 - direction.y * 6, y: end.y - direction.y * 12 + direction.x * 6))
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(x: end.x - direction.x * 12 + direction.y * 6, y: end.y - direction.y * 12 - direction.x * 6))
            context.stroke(arrow, with: .color(Color(hex: "#7A8BA8")), lineWidth: 1.5)
        }
        .frame(width: canvasWidth, height: canvasHeight)
        .allowsHitTesting(false)
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
    static let newNoteCommand = Notification.Name("CoThinkNewNoteCommand")
    static let zoomInCommand = Notification.Name("CoThinkZoomInCommand")
    static let zoomOutCommand = Notification.Name("CoThinkZoomOutCommand")
    static let zoomResetCommand = Notification.Name("CoThinkZoomResetCommand")
    static let requestDeleteSelectionCommand = Notification.Name("CoThinkRequestDeleteSelection")
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
