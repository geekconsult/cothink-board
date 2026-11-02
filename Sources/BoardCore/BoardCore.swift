import Foundation
import Darwin

public enum LineStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted
}

public enum ConnectionDirection: String, Codable, CaseIterable {
    case oneWay, twoWay, none
}

public enum ResizeCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct BoardRect: Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static func selection(fromX: Double, fromY: Double, toX: Double, toY: Double) -> BoardRect {
        BoardRect(x: min(fromX, toX), y: min(fromY, toY), width: abs(toX - fromX), height: abs(toY - fromY))
    }
    public func containsCenter(of note: Note) -> Bool {
        let centerX = note.x + note.width / 2, centerY = note.y + note.height / 2
        return centerX >= x && centerX <= x + width && centerY >= y && centerY <= y + height
    }
    public func resized(from corner: ResizeCorner, dx: Double, dy: Double, minWidth: Double = 80, minHeight: Double = 50) -> BoardRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let newX = left ? max(0, min(x + dx, x + width - minWidth)) : x
        let newY = top ? max(0, min(y + dy, y + height - minHeight)) : y
        let newWidth = left ? x + width - newX : max(minWidth, width + dx)
        let newHeight = top ? y + height - newY : max(minHeight, height + dy)
        return BoardRect(x: newX, y: newY, width: newWidth, height: newHeight)
    }
}

public struct Note: Codable, Identifiable, Equatable {
    public var id: String, text: String
    public var x: Double, y: Double, width: Double, height: Double
    public var color: String
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeStyle: LineStyle?
    public var imagePath: String?
    public var assetIDs: [String]?
    public init(id: String = UUID().uuidString, text: String = "", x: Double = 100, y: Double = 100, width: Double = 200, height: Double = 100, color: String = "#FFF1B8", imagePath: String? = nil) {
        self.id = id; self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
        self.imagePath = imagePath
        self.assetIDs = []
    }
}
public struct ProjectAsset: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var relativePath: String
    public init(id: String = UUID().uuidString, name: String, relativePath: String) {
        self.id = id; self.name = name; self.relativePath = relativePath
    }
}
public struct Connection: Codable, Identifiable, Equatable {
    public var id: String, from: String, to: String
    public var arrow: Bool
    public var direction: ConnectionDirection?
    public var label: String?
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeStyle: LineStyle?
    public var effectiveDirection: ConnectionDirection { direction ?? (arrow ? .oneWay : .none) }
    public init(id: String = UUID().uuidString, from: String, to: String, arrow: Bool = true, direction: ConnectionDirection? = nil, label: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.arrow = arrow
        self.direction = direction; self.label = label
    }
}
public struct BoardGroup: Codable, Identifiable, Equatable {
    public var id: String, title: String
    public var x: Double, y: Double, width: Double, height: Double
    public var color: String
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeStyle: LineStyle?
    public var memberIDs: [String]?
    public init(id: String = UUID().uuidString, title: String = "Group", x: Double = 80, y: Double = 80, width: Double = 400, height: Double = 300, color: String = "#E6E9F5") {
        self.id = id; self.title = title; self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
    }
}
public struct Board: Codable, Identifiable, Equatable {
    public var version: Int
    public var id: String, title: String
    public var revision: Int
    public var notes: [Note], connections: [Connection], groups: [BoardGroup]
    public var projectFilesPath: String?
    public var assets: [ProjectAsset]?
    public var tags: [String]? = nil
    public var flagged: Bool? = nil
    public var color: String? = nil
    public init(version: Int = 1, id: String = UUID().uuidString, title: String = "Untitled Board", revision: Int = 0, notes: [Note] = [], connections: [Connection] = [], groups: [BoardGroup] = [], projectFilesPath: String? = nil, assets: [ProjectAsset]? = []) {
        self.version = version; self.id = id; self.title = title; self.revision = revision; self.notes = notes; self.connections = connections; self.groups = groups
        self.projectFilesPath = projectFilesPath; self.assets = assets
    }
}
public extension Board {
    var projectAssets: [ProjectAsset] { assets ?? [] }

    @discardableResult
    mutating func unlockNote(id: String) -> Bool {
        var changed = false
        for i in groups.indices {
            if groups[i].memberIDs?.contains(id) == true {
                groups[i].memberIDs?.removeAll { $0 == id }
                changed = true
            }
        }
        return changed
    }

    func groupContaining(noteID: String) -> BoardGroup? {
        groups.last { $0.memberIDs?.contains(noteID) == true }
    }

    func groupMovement(id: String, dx: Double, dy: Double) -> (dx: Double, dy: Double)? {
        guard let group = groups.first(where: { $0.id == id }) else { return nil }
        let ids = Set(group.memberIDs ?? [])
        let members = notes.filter { ids.contains($0.id) }
        let minX = ([group.x] + members.map(\.x)).min() ?? group.x
        let minY = ([group.y] + members.map(\.y)).min() ?? group.y
        return (max(-minX, dx), max(-minY, dy))
    }

    @discardableResult
    mutating func moveGroup(id: String, dx: Double, dy: Double) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == id }), let delta = groupMovement(id: id, dx: dx, dy: dy) else { return false }
        let members = Set(groups[index].memberIDs ?? [])
        groups[index].x += delta.dx; groups[index].y += delta.dy
        for i in notes.indices where members.contains(notes[i].id) {
            notes[i].x += delta.dx; notes[i].y += delta.dy
        }
        return true
    }
}

public enum BoardTitleDraftDecision: Equatable { case unchanged, invalid, conflict, save }
public enum BoardTitleDraft {
    public static func decision(baseline: String, draft: String, current: String) -> BoardTitleDraftDecision {
        if baseline == draft || current == draft { return .unchanged }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .invalid }
        if current != baseline { return .conflict }
        return .save
    }
}

public enum BoardError: LocalizedError {
    case notFound, conflict, invalid(String), noUndo, noRedo
    public var errorDescription: String? {
        switch self {
        case .notFound: return "Board not found."
        case .conflict: return "The board changed. Reload it and try again."
        case .invalid(let reason): return "Invalid board: \(reason)"
        case .noUndo: return "Nothing to undo."
        case .noRedo: return "Nothing to redo."
        }
    }
}
private struct Entry: Codable {
    var board: Board
    var past: [Board] = []
    var future: [Board] = []
    var history: [Change] = []
}
public struct Change: Codable, Equatable {
    public var actor: String
    public var revision: Int
    public var date: Date
}
public struct BoardList: Codable, Identifiable, Equatable {
    public var id: String = UUID().uuidString
    public var revision: Int = 0
    public var title: String
    public var description: String = ""
    public var boardIDs: [String] = []
    public var tags: [String] = []
    public var flagged: Bool = false
    public var color: String = "#7A8BA8"
    public init(title: String) { self.title = title }
}
private struct Database: Codable { var entries: [Entry] = []; var lists: [BoardList]? = nil }

public final class BoardStore {
    private let directory: URL
    private var dataURL: URL { directory.appendingPathComponent("boards.json") }
    public init(directory: URL? = nil) throws {
        if let directory { self.directory = directory }
        else if let path = ProcessInfo.processInfo.environment["COTHINK_HOME"], !path.isEmpty { self.directory = URL(fileURLWithPath: path, isDirectory: true) }
        else { self.directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CoThinkBoard", isDirectory: true) }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }
    public func defaultProjectFilesDirectory(for boardID: String) -> URL {
        directory.appendingPathComponent("Projects", isDirectory: true).appendingPathComponent(boardID, isDirectory: true)
    }
    private func transact<T>(write: Bool = false, _ block: (inout Database) throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent("store.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        var db: Database
        if FileManager.default.fileExists(atPath: dataURL.path) { db = try JSONDecoder().decode(Database.self, from: Data(contentsOf: dataURL)) }
        else { db = Database() }
        let result = try block(&db)
        if write {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(db).write(to: dataURL, options: .atomic)
        }
        return result
    }
    public func list() throws -> [Board] { try transact { $0.entries.map(\.board) } }
    public func lists() throws -> [BoardList] { try transact { $0.lists ?? [] } }
    public func createList(title: String) throws -> BoardList {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BoardError.invalid("list title") }
        return try transact(write: true) { db in let item = BoardList(title: title); db.lists = (db.lists ?? []) + [item]; return item }
    }
    public func replaceList(_ list: BoardList, expectedRevision: Int) throws -> BoardList {
        guard !list.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Set(list.boardIDs).count == list.boardIDs.count else { throw BoardError.invalid("list title or board IDs") }
        return try transact(write: true) { db in
            var lists = db.lists ?? []
            guard let index = lists.firstIndex(where: { $0.id == list.id }) else { throw BoardError.notFound }
            guard lists[index].revision == expectedRevision else { throw BoardError.conflict }
            guard Set(list.boardIDs).isSubset(of: Set(db.entries.map { $0.board.id })) else { throw BoardError.invalid("list references missing boards") }
            var next = list; next.revision = expectedRevision + 1; lists[index] = next; db.lists = lists; return next
        }
    }
    public func deleteList(_ id: String, expectedRevision: Int) throws {
        try transact(write: true) { db in
            var lists = db.lists ?? []; guard let index = lists.firstIndex(where: { $0.id == id }) else { throw BoardError.notFound }
            guard lists[index].revision == expectedRevision else { throw BoardError.conflict }
            lists.remove(at: index); db.lists = lists
        }
    }
    public func get(_ id: String) throws -> Board { try transact { db in guard let e = db.entries.first(where: { $0.board.id == id }) else { throw BoardError.notFound }; return e.board } }
    public func history(_ id: String) throws -> [Change] { try transact { db in guard let e = db.entries.first(where: { $0.board.id == id }) else { throw BoardError.notFound }; return e.history } }
    public func create(title: String, actor: String) throws -> Board {
        let board = Board(title: title)
        try validate(board)
        return try transact(write: true) { db in db.entries.append(Entry(board: board, history: [Change(actor: actor, revision: 0, date: Date())])); return board }
    }
    public func importBoard(_ board: Board, actor: String) throws -> Board {
        try validate(board)
        var copy = board; copy.id = UUID().uuidString; copy.revision = 0
        return try transact(write: true) { db in db.entries.append(Entry(board: copy, history: [Change(actor: actor, revision: 0, date: Date())])); return copy }
    }
    public func replace(_ board: Board, expectedRevision: Int, actor: String) throws -> Board {
        try validate(board)
        return try transact(write: true) { db in
            guard let i = db.entries.firstIndex(where: { $0.board.id == board.id }) else { throw BoardError.notFound }
            guard db.entries[i].board.revision == expectedRevision else { throw BoardError.conflict }
            var next = board; next.revision = expectedRevision + 1
            db.entries[i].past.append(db.entries[i].board)
            if db.entries[i].past.count > 100 { db.entries[i].past.removeFirst() }
            db.entries[i].future = []; db.entries[i].board = next
            db.entries[i].history.append(Change(actor: actor, revision: next.revision, date: Date()))
            return next
        }
    }
    public func delete(_ id: String, expectedRevision: Int? = nil) throws { try transact(write: true) { db in guard let i = db.entries.firstIndex(where: { $0.board.id == id }) else { throw BoardError.notFound }; if let expectedRevision, db.entries[i].board.revision != expectedRevision { throw BoardError.conflict }; db.entries.remove(at: i); if var lists = db.lists { for index in lists.indices where lists[index].boardIDs.contains(id) { lists[index].boardIDs.removeAll { $0 == id }; lists[index].revision += 1 }; db.lists = lists } } }
    public func undo(_ id: String, actor: String, expectedRevision: Int? = nil) throws -> Board { try travel(id, actor: actor, backwards: true, expectedRevision: expectedRevision) }
    public func redo(_ id: String, actor: String, expectedRevision: Int? = nil) throws -> Board { try travel(id, actor: actor, backwards: false, expectedRevision: expectedRevision) }
    private func travel(_ id: String, actor: String, backwards: Bool, expectedRevision: Int?) throws -> Board {
        try transact(write: true) { db in
            guard let i = db.entries.firstIndex(where: { $0.board.id == id }) else { throw BoardError.notFound }
            let current = db.entries[i].board
            if let expectedRevision, current.revision != expectedRevision { throw BoardError.conflict }
            var target: Board
            if backwards {
                guard let b = db.entries[i].past.popLast() else { throw BoardError.noUndo }; target = b
                db.entries[i].future.append(current)
            } else {
                guard let b = db.entries[i].future.popLast() else { throw BoardError.noRedo }; target = b
                db.entries[i].past.append(current)
            }
            target.revision = current.revision + 1; db.entries[i].board = target
            db.entries[i].history.append(Change(actor: actor, revision: target.revision, date: Date()))
            return target
        }
    }
    private func validate(_ b: Board) throws {
        guard b.version == 1, !b.id.isEmpty, !b.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, b.revision >= 0 else { throw BoardError.invalid("version, ID, title or revision") }
        let ids = b.notes.map(\.id), groupIDs = b.groups.map(\.id), edgeIDs = b.connections.map(\.id)
        guard Set(ids).count == ids.count, Set(groupIDs).count == groupIDs.count, Set(edgeIDs).count == edgeIDs.count, !(ids + groupIDs + edgeIDs).contains("") else { throw BoardError.invalid("duplicate or empty IDs") }
        let widths = b.notes.map(\.strokeWidth) + b.groups.map(\.strokeWidth) + b.connections.map(\.strokeWidth)
        guard widths.allSatisfy({ $0 == nil || ($0!.isFinite && (0...20).contains($0!)) }) else { throw BoardError.invalid("stroke width") }
        let noteIDs = Set(ids)
        let assets = b.assets ?? []
        let assetIDs = assets.map(\.id)
        guard Set(assetIDs).count == assetIDs.count, !assetIDs.contains(""),
              assets.allSatisfy({ !$0.name.isEmpty && !$0.relativePath.isEmpty && !$0.relativePath.hasPrefix("/") && !$0.relativePath.split(separator: "/").contains("..") }),
              b.notes.allSatisfy({
                  let attached = $0.assetIDs ?? []
                  return Set(attached).count == attached.count && Set(attached).isSubset(of: Set(assetIDs))
              }) else { throw BoardError.invalid("project assets") }
        guard b.groups.allSatisfy({ group in
            guard let members = group.memberIDs else { return true }
            return Set(members).count == members.count && members.allSatisfy(noteIDs.contains)
        }) else { throw BoardError.invalid("group members") }
        guard b.connections.allSatisfy({ noteIDs.contains($0.from) && noteIDs.contains($0.to) && $0.from != $0.to }) else { throw BoardError.invalid("connection endpoints") }
        guard b.notes.allSatisfy({ [$0.x,$0.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }), b.groups.allSatisfy({ [$0.x,$0.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }) else { throw BoardError.invalid("geometry") }
    }
}
