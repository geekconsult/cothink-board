import Foundation
import Darwin

public enum LineStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted
}

public enum NoteShape: String, Codable, CaseIterable {
    case rectangle, ellipse, diamond, line
}

public enum ConnectionDirection: String, Codable, CaseIterable {
    case oneWay, twoWay, none
}
public enum ConnectionRoute: String, Codable, CaseIterable {
    case straight, curved, custom
}
public struct ConnectionPoint: Codable, Equatable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum ResizeCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public struct BoardRect: Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static func canvasExtent(containing rects: [BoardRect]) -> (width: Double, height: Double) {
        let right = rects.map { $0.x + $0.width }.max() ?? 0
        let bottom = rects.map { $0.y + $0.height }.max() ?? 0
        func extent(_ edge: Double, minimum: Double) -> Double {
            max(minimum, ceil((edge + 500) / 500) * 500)
        }
        return (extent(right, minimum: 3000), extent(bottom, minimum: 2000))
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
    public var fontSize: Double?
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeStyle: LineStyle?
    public var shape: NoteShape?
    public var imagePath: String?
    public var assetIDs: [String]?
    public var parentID: String?
    public var collapsed: Bool?
    public init(id: String = UUID().uuidString, text: String = "", x: Double = 100, y: Double = 100, width: Double = 200, height: Double = 100, color: String = "#FFF1B8", imagePath: String? = nil, parentID: String? = nil, collapsed: Bool? = nil, shape: NoteShape? = nil) {
        self.id = id; self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.color = color
        self.imagePath = imagePath
        self.assetIDs = []
        self.parentID = parentID
        self.collapsed = collapsed
        self.shape = shape
    }

    public static func makeShape(_ shape: NoteShape, x: Double, y: Double) -> Note {
        Note(text: "", x: x, y: y, width: 160, height: shape == .line ? 80 : 120, color: "#F3F1EC", shape: shape)
    }

    public var autofitsHeight: Bool { shape == nil }

    // A line is the diagonal of its bounding box, so a zero extent is legitimate for line notes only.
    public var hasValidExtent: Bool {
        shape == .line ? width > 0 || height > 0 : width > 0 && height > 0
    }

    // Interactive edits clamp to 1 (not 0) for lines so the result always passes hasValidExtent.
    public var extentMinWidth: Double { shape == .line ? 1 : 80 }
    public var extentMinHeight: Double { shape == .line ? 1 : 50 }
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
    public var fontSize: Double?
    public var strokeColor: String?
    public var strokeWidth: Double?
    public var strokeStyle: LineStyle?
    public var route: ConnectionRoute?
    public var routePoints: [ConnectionPoint]?
    public var effectiveDirection: ConnectionDirection { direction ?? (arrow ? .oneWay : .none) }
    public var effectiveRoute: ConnectionRoute { route ?? .straight }
    public func controlPoints(from source: Note, to target: Note) -> [ConnectionPoint] {
        guard effectiveRoute != .straight else { return [] }
        let saved = routePoints ?? []
        if !saved.isEmpty { return effectiveRoute == .curved ? Array(saved.prefix(1)) : saved }
        return [ConnectionPoint(x: max(0, (source.x + source.width / 2 + target.x + target.width / 2) / 2),
                                y: max(0, (source.y + source.height / 2 + target.y + target.height / 2) / 2 + 120))]
    }
    public init(id: String = UUID().uuidString, from: String, to: String, arrow: Bool = true, direction: ConnectionDirection? = nil, label: String? = nil) {
        self.id = id; self.from = from; self.to = to; self.arrow = arrow
        self.direction = direction; self.label = label
    }
}
public struct BoardGroup: Codable, Identifiable, Equatable {
    public var id: String, title: String
    public var x: Double, y: Double, width: Double, height: Double
    public var color: String
    public var fontSize: Double?
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
    public var icon: String? = nil
    public var color: String? = nil
    public var wallpaperColor: String? = nil
    public var wallpaperAssetID: String? = nil
    public var wallpaperOpacity: Double? = nil
    public init(version: Int = 1, id: String = UUID().uuidString, title: String = "Untitled Board", revision: Int = 0, notes: [Note] = [], connections: [Connection] = [], groups: [BoardGroup] = [], projectFilesPath: String? = nil, assets: [ProjectAsset]? = []) {
        self.version = version; self.id = id; self.title = title; self.revision = revision; self.notes = notes; self.connections = connections; self.groups = groups
        self.projectFilesPath = projectFilesPath; self.assets = assets
    }
}

public struct BoardFragment: Codable {
    public var sourceBoardID: String
    public var notes: [Note]
    public var groups: [BoardGroup]
    public var connections: [Connection]
    public var assets: [ProjectAsset]

    public static func capture(from board: Board, noteIDs: Set<String>, groupID: String?, connectionID: String?, extraGroupIDs: Set<String> = []) -> BoardFragment {
        let groups = board.groups.filter { $0.id == groupID || extraGroupIDs.contains($0.id) }
        var ids = noteIDs.union(groups.flatMap { $0.memberIDs ?? [] })
        if let edge = board.connections.first(where: { $0.id == connectionID }) { ids.formUnion([edge.from, edge.to]) }
        let notes = board.notes.filter { ids.contains($0.id) }
        let links = board.connections.filter { ids.contains($0.from) && ids.contains($0.to) }
        let assets = Set(notes.flatMap { $0.assetIDs ?? [] })
        return BoardFragment(sourceBoardID: board.id, notes: notes, groups: groups, connections: links,
                             assets: board.projectAssets.filter { assets.contains($0.id) })
    }

    @discardableResult
    public func insert(into board: inout Board, offset: Double, assetIDs: [String: String] = [:]) -> (notes: [String], groups: [String]) {
        var mapping: [String: String] = [:]
        for note in notes { mapping[note.id] = UUID().uuidString }
        var newNotes: [Note] = []
        for var note in notes {
            note.id = mapping[note.id]!
            note.x += offset; note.y += offset
            note.assetIDs = note.assetIDs?.map { assetIDs[$0] ?? $0 }
            note.parentID = note.parentID.flatMap { mapping[$0] }
            newNotes.append(note)
        }
        var newGroups: [BoardGroup] = []
        for var group in groups {
            group.id = UUID().uuidString
            group.x += offset; group.y += offset
            group.memberIDs = group.memberIDs?.compactMap { mapping[$0] }
            newGroups.append(group)
        }
        let newConnections: [Connection] = connections.compactMap { edge in
            guard let from = mapping[edge.from], let to = mapping[edge.to] else { return nil }
            var copy = edge; copy.id = UUID().uuidString; copy.from = from; copy.to = to
            copy.routePoints = copy.routePoints?.map { ConnectionPoint(x: $0.x + offset, y: $0.y + offset) }
            return copy
        }
        board.notes += newNotes; board.groups += newGroups; board.connections += newConnections
        return (newNotes.map(\.id), newGroups.map(\.id))
    }
}
public extension Board {
    var projectAssets: [ProjectAsset] { assets ?? [] }

    @discardableResult
    mutating func lockNote(id: String, toGroup groupID: String) -> Bool {
        guard notes.contains(where: { $0.id == id }), let target = groups.firstIndex(where: { $0.id == groupID }) else { return false }
        let memberships = groups.filter { $0.memberIDs?.contains(id) == true }
        if memberships.count == 1 && memberships[0].id == groupID { return false }
        for i in groups.indices { groups[i].memberIDs?.removeAll { $0 == id } }
        groups[target].memberIDs = (groups[target].memberIDs ?? []) + [id]
        return true
    }

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

    // A selection that includes a locked note moves its whole group once, and every
    // selected note drags its subtree; group and descendant expansion compose to a
    // fixed point, and the clamp is computed over the final expanded set.
    func selectionMovement(noteIDs: Set<String>, dx: Double, dy: Double) -> (noteIDs: Set<String>, groupIDs: Set<String>, dx: Double, dy: Double) {
        var childOf: [String: [String]] = [:]
        for note in notes {
            guard let parentID = note.parentID else { continue }
            childOf[parentID, default: []].append(note.id)
        }
        func descendants(of ids: Set<String>) -> Set<String> {
            var found: Set<String> = []
            var stack = ids.flatMap { childOf[$0] ?? [] }
            while let id = stack.popLast() {
                if found.insert(id).inserted { stack.append(contentsOf: childOf[id] ?? []) }
            }
            return found
        }
        var selected = noteIDs
        var groupIDs: Set<String> = []
        while true {
            let touching = groups.filter { !Set($0.memberIDs ?? []).isDisjoint(with: selected) }
            groupIDs = Set(touching.map(\.id))
            let expanded = selected.union(touching.flatMap { $0.memberIDs ?? [] }).union(descendants(of: selected))
            if expanded == selected { break }
            selected = expanded
        }
        let movingNotes = notes.filter { selected.contains($0.id) }
        let movingGroups = groups.filter { groupIDs.contains($0.id) }
        let minX = (movingNotes.map(\.x) + movingGroups.map(\.x)).min() ?? 0
        let minY = (movingNotes.map(\.y) + movingGroups.map(\.y)).min() ?? 0
        return (selected, groupIDs, max(-minX, dx), max(-minY, dy))
    }

    mutating func moveSelection(noteIDs: Set<String>, dx: Double, dy: Double) {
        let movement = selectionMovement(noteIDs: noteIDs, dx: dx, dy: dy)
        for i in notes.indices where movement.noteIDs.contains(notes[i].id) { notes[i].x += movement.dx; notes[i].y += movement.dy }
        for i in groups.indices where movement.groupIDs.contains(groups[i].id) { groups[i].x += movement.dx; groups[i].y += movement.dy }
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

    func parent(of noteID: String) -> Note? {
        guard let note = notes.first(where: { $0.id == noteID }), let parentID = note.parentID else { return nil }
        return notes.first { $0.id == parentID }
    }

    // Display order: y ascending, then notes-array order.
    func children(of noteID: String) -> [Note] {
        notes.enumerated().filter { $0.element.parentID == noteID }
            .sorted { lhs, rhs in lhs.element.y != rhs.element.y ? lhs.element.y < rhs.element.y : lhs.offset < rhs.offset }
            .map(\.element)
    }

    // Reachable downward through parentID links, excluding the note itself.
    func descendantIDs(of noteID: String) -> Set<String> {
        var childrenOf: [String: [String]] = [:]
        for note in notes {
            guard let parentID = note.parentID else { continue }
            childrenOf[parentID, default: []].append(note.id)
        }
        var found: Set<String> = []
        var stack = childrenOf[noteID] ?? []
        while let id = stack.popLast() {
            if found.insert(id).inserted { stack.append(contentsOf: childrenOf[id] ?? []) }
        }
        return found
    }

    func isTreeLinked(noteID: String) -> Bool {
        guard let note = notes.first(where: { $0.id == noteID }) else { return false }
        return note.parentID != nil || notes.contains { $0.parentID == noteID }
    }

    // Re-links a note under another note; refuses self and ancestor targets so the
    // parent graph stays a forest. Mutates nothing when it throws.
    mutating func setNoteParent(_ childID: String, to parentID: String?) throws {
        guard let index = notes.firstIndex(where: { $0.id == childID }) else { throw BoardError.notFound }
        if let parentID {
            guard notes.contains(where: { $0.id == parentID }) else { throw BoardError.notFound }
            guard parentID != childID else { throw BoardError.invalid("self parent") }
            guard !descendantIDs(of: childID).contains(parentID) else { throw BoardError.invalid("cycle") }
        }
        notes[index].parentID = parentID
    }

    // Removes notes plus their connections and group memberships; children of deleted
    // notes are promoted to the nearest surviving pre-delete ancestor.
    mutating func deleteNotes(_ ids: Set<String>) {
        let parentByID = Dictionary(notes.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        var promoted: [String: String?] = [:]
        for note in notes where !ids.contains(note.id) {
            guard let parentID = note.parentID, ids.contains(parentID) else { continue }
            var cursor = parentByID[parentID] ?? nil
            while let ancestor = cursor, ids.contains(ancestor) { cursor = parentByID[ancestor] ?? nil }
            promoted[note.id] = cursor
        }
        notes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for index in groups.indices { groups[index].memberIDs?.removeAll { ids.contains($0) } }
        for index in notes.indices {
            guard let newParent = promoted[notes[index].id] else { continue }
            notes[index].parentID = newParent
        }
    }

    // Tidy tree layout for one subtree: children stack to the right of their parent,
    // each centered over its own subtree slot, siblings ordered by current y then
    // array index. Pure; the root keeps its position and is excluded from the result.
    func mindmapLayout(rootID: String, gapX: Double = 60, gapY: Double = 24) -> [String: (x: Double, y: Double)] {
        guard let root = notes.first(where: { $0.id == rootID }) else { return [:] }
        var byID: [String: Note] = [:]
        var childEntries: [String: [(y: Double, index: Int, id: String)]] = [:]
        for (index, note) in notes.enumerated() {
            byID[note.id] = note
            guard let parentID = note.parentID else { continue }
            childEntries[parentID, default: []].append((note.y, index, note.id))
        }
        var childrenOf: [String: [String]] = [:]
        for (parentID, entries) in childEntries {
            childrenOf[parentID] = entries.sorted { $0.y != $1.y ? $0.y < $1.y : $0.index < $1.index }.map(\.id)
        }
        var seen: Set<String> = [rootID]
        var order: [String] = []
        var stack: [String] = [rootID]
        while let id = stack.popLast() {
            order.append(id)
            for child in childrenOf[id] ?? [] where !seen.contains(child) {
                seen.insert(child)
                stack.append(child)
            }
        }
        var subtreeHeight: [String: Double] = [:]
        for id in order.reversed() {
            guard let note = byID[id] else { continue }
            let kids = (childrenOf[id] ?? []).filter { seen.contains($0) }
            var block: Double = 0
            for (offset, child) in kids.enumerated() {
                if offset > 0 { block += gapY }
                block += subtreeHeight[child] ?? byID[child]?.height ?? 0
            }
            subtreeHeight[id] = max(note.height, block)
        }
        var spot: [String: (x: Double, y: Double)] = [rootID: (root.x, root.y)]
        for id in order {
            guard let note = byID[id], let (x, y) = spot[id] else { continue }
            let kids = (childrenOf[id] ?? []).filter { seen.contains($0) }
            guard !kids.isEmpty else { continue }
            let blockHeight = kids.reduce(0.0) { $0 + (subtreeHeight[$1] ?? 0) } + gapY * Double(kids.count - 1)
            var top = y + note.height / 2 - blockHeight / 2
            for child in kids {
                guard let childNote = byID[child] else { continue }
                let childHeight = subtreeHeight[child] ?? childNote.height
                spot[child] = (x + note.width + gapX, top + childHeight / 2 - childNote.height / 2)
                top += childHeight + gapY
            }
        }
        spot.removeValue(forKey: rootID)
        return spot
    }

    // Applies mindmapLayout to one subtree, or with nil to every tree root in one
    // compute-then-apply pass. Childless roots and free-form notes never move, so the
    // pass is idempotent: sibling order is read before anything moves.
    mutating func tidySubtree(rootID: String?) {
        var layouts: [String: (x: Double, y: Double)] = [:]
        if let rootID {
            guard notes.contains(where: { $0.id == rootID }) else { return }
            layouts = mindmapLayout(rootID: rootID)
        } else {
            let parented = Set(notes.compactMap(\.parentID))
            for root in notes.filter({ $0.parentID == nil && parented.contains($0.id) }).map(\.id) {
                layouts.merge(mindmapLayout(rootID: root), uniquingKeysWith: { _, second in second })
            }
        }
        guard !layouts.isEmpty else { return }
        for index in notes.indices {
            guard let spot = layouts[notes[index].id] else { continue }
            notes[index].x = spot.x; notes[index].y = spot.y
        }
    }

    // Canvas visibility: a note is hidden iff any strict ancestor is folded. The
    // single definition used by the app, the SVG overview, and tests.
    func hiddenNoteIDs() -> Set<String> {
        var hidden: Set<String> = []
        for note in notes where note.collapsed == true {
            hidden.formUnion(descendantIDs(of: note.id))
        }
        return hidden
    }

    // Folded state only exists on notes with direct children; a leaf fold is dead
    // state and is refused. Unfolded notes store nil, keeping JSON clean.
    @discardableResult
    mutating func toggleFold(noteID: String) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID }),
              notes.contains(where: { $0.parentID == noteID }) else { return false }
        notes[index].collapsed = notes[index].collapsed == true ? nil : true
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
public enum BoardAnchor { case before(String), after(String), top, bottom }
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
    public func move(boardID: String, to anchor: BoardAnchor) throws {
        try transact(write: true) { db in
            guard let from = db.entries.firstIndex(where: { $0.board.id == boardID }) else { throw BoardError.notFound }
            let entry = db.entries.remove(at: from)
            let to: Int
            switch anchor {
            case .top: to = 0
            case .bottom: to = db.entries.count
            case .before(let sibling):
                if sibling == boardID { to = from }
                else { to = db.entries.firstIndex(where: { $0.board.id == sibling }) ?? db.entries.count }
            case .after(let sibling):
                if sibling == boardID { to = from }
                else { to = db.entries.firstIndex(where: { $0.board.id == sibling }).map { $0 + 1 } ?? db.entries.count }
            }
            db.entries.insert(entry, at: to)
        }
    }
    public func deleteBoards(_ ids: [String]) throws {
        try transact(write: true) { db in
            let doomed = Set(ids)
            db.entries.removeAll { doomed.contains($0.board.id) }
            if var lists = db.lists {
                for index in lists.indices where lists[index].boardIDs.contains(where: { doomed.contains($0) }) {
                    lists[index].boardIDs.removeAll { doomed.contains($0) }
                    lists[index].revision += 1
                }
                db.lists = lists
            }
        }
    }
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
        let fontSizes = b.notes.map(\.fontSize) + b.groups.map(\.fontSize) + b.connections.map(\.fontSize)
        guard fontSizes.allSatisfy({ $0 == nil || ($0!.isFinite && (6...96).contains($0!)) }) else { throw BoardError.invalid("font size") }
        guard b.connections.allSatisfy({ ($0.routePoints ?? []).count <= 100 && ($0.routePoints ?? []).allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 } }) else { throw BoardError.invalid("connection route points") }
        let noteIDs = Set(ids)
        let assets = b.assets ?? []
        let assetIDs = assets.map(\.id)
        guard b.wallpaperColor == nil || b.wallpaperColor!.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              b.wallpaperOpacity == nil || (b.wallpaperOpacity!.isFinite && (0...1).contains(b.wallpaperOpacity!)),
              b.wallpaperAssetID == nil || assetIDs.contains(b.wallpaperAssetID!) else { throw BoardError.invalid("wallpaper") }
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
        guard b.notes.allSatisfy({ $0.parentID == nil || noteIDs.contains($0.parentID!) }) else { throw BoardError.invalid("note parent") }
        let parentByID = Dictionary(b.notes.map { ($0.id, $0.parentID) }, uniquingKeysWith: { first, _ in first })
        for note in b.notes {
            var visited: Set<String> = []
            var cursor: String? = note.id
            while let id = cursor {
                guard visited.insert(id).inserted else { throw BoardError.invalid("note parent cycle") }
                cursor = parentByID[id] ?? nil
            }
        }
        guard b.connections.allSatisfy({ noteIDs.contains($0.from) && noteIDs.contains($0.to) && $0.from != $0.to }) else { throw BoardError.invalid("connection endpoints") }
        guard b.notes.allSatisfy({ [$0.x,$0.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.hasValidExtent }), b.groups.allSatisfy({ [$0.x,$0.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }) else { throw BoardError.invalid("geometry") }
    }
}
