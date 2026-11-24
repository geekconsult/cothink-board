import Foundation

public struct CloudReminderItem: Codable, Equatable, Sendable {
    public var title: String
    public var completed: Bool?
    public var due: String?
    public var priority: Int?
    public var flagged: Bool?

    public init(title: String, completed: Bool? = nil, due: String? = nil, priority: Int? = nil, flagged: Bool? = nil) {
        self.title = title
        self.completed = completed
        self.due = due
        self.priority = priority
        self.flagged = flagged
    }
}

public enum CloudConflictChoice { case mac, web }
public enum CloudSyncError: LocalizedError {
    case accountChanged, invalidWorkspace, busy
    case conflict(String), readOnly(String), http(Int)

    public var errorDescription: String? {
        switch self {
        case .accountChanged: return "This local workspace belongs to another CoThink account."
        case .invalidWorkspace: return "The web workspace contains an item this version of CoThink cannot read."
        case .busy: return "Another sync is already running."
        case .conflict(let field): return "The Mac and web both changed \(field). Choose which change to keep."
        case .readOnly(let title): return "Your local edits to “\(title)” cannot be published with your current access."
        case .http(401): return "Your web session expired. Sign in again."
        case .http(409): return "The workspace changed during sync. It will be checked again."
        case .http(let status): return "The CoThink server returned HTTP \(status)."
        }
    }
}

struct CloudLocalWorkspace: Equatable {
    var boards: [Board]
    var lists: [BoardList]
    var pinnedListID: String?
    var deskIDs: Set<String> = []
}

struct CloudAccount: Codable, Equatable {
    var server: String
    var userID: String
}

struct CloudCheckpoint: Codable, Equatable {
    var account: CloudAccount
    var baseline: CloudJSON?
    var sharedBoards: Set<String> = []
    var files: Set<String> = []
}

// A typed JSON tree lets us edit supported fields without discarding browser-only
// properties on a board, list or individual canvas object.
indirect enum CloudJSON: Equatable, Codable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let b = try? value.decode(Bool.self) { self = .bool(b) }
        else if let n = try? value.decode(Double.self) { self = .number(n) }
        else if let s = try? value.decode(String.self) { self = .string(s) }
        else if let a = try? value.decode([Self].self) { self = .array(a) }
        else { self = .object(try value.decode([String: Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
    init<T: Encodable>(encoding item: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(item))
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
    var dictionary: [String: Self] {
        get throws {
            guard case .object(let value) = self else { throw CloudSyncError.invalidWorkspace }
            return value
        }
    }
    var items: [Self] {
        get throws {
            guard case .array(let value) = self else { throw CloudSyncError.invalidWorkspace }
            return value
        }
    }
    subscript(_ key: String) -> Self? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }
    var text: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }
    static func index(_ values: [Self]) throws -> [String: Self] {
        var result: [String: Self] = [:]
        for value in values {
            guard let id = value["id"]?.text, !id.isEmpty, result.updateValue(value, forKey: id) == nil else { throw CloudSyncError.invalidWorkspace }
        }
        return result
    }
}

enum CloudWorkspaceDocument {
    static let empty: CloudJSON = .object(["boards": .array([]), "lists": .array([])])

    static func project(_ local: CloudLocalWorkspace) throws -> CloudJSON {
        let boards = try local.boards.map { board -> CloudJSON in
            var wire = try CloudJSON(encoding: board).dictionary
            for key in ["version", "revision", "projectFilesPath"] { wire.removeValue(forKey: key) }
            wire["notes"] = .array(try board.notes.map { note in
                var item = try CloudJSON(encoding: note).dictionary
                for key in ["imagePath", "reminderID", "additionalReminders"] { item.removeValue(forKey: key) }
                if note.reminderID != nil { item["appleReminderLinked"] = .bool(true) }
                if note.reminderSnapshots == nil, !note.reminderItems.isEmpty {
                    item["reminderSnapshots"] = try CloudJSON(encoding: note.reminderItems.map { CloudReminderItem(title: $0.title) })
                }
                return .object(item)
            })
            wire["assets"] = .array(board.projectAssets.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
            return .object(wire)
        }
        let lists = try local.lists.map { list -> CloudJSON in
            var wire = try CloudJSON(encoding: list).dictionary
            wire.removeValue(forKey: "revision")
            return .object(wire)
        }
        var document: [String: CloudJSON] = ["boards": .array(boards), "lists": .array(lists)]
        document["desk"] = .object(Dictionary(uniqueKeysWithValues: local.deskIDs.map { ($0, CloudJSON.bool(true)) }))
        document["pinnedListID"] = local.pinnedListID.map(CloudJSON.string)
        return .object(document)
    }

    static func localize(_ document: CloudJSON, preserving local: CloudLocalWorkspace) throws -> CloudLocalWorkspace {
        guard let boards = try document["boards"]?.items, let lists = try document["lists"]?.items else { throw CloudSyncError.invalidWorkspace }
        _ = try CloudJSON.index(boards)
        _ = try CloudJSON.index(lists)
        let existing = Dictionary(uniqueKeysWithValues: local.boards.map { ($0.id, $0) })
        let decodedBoards: [Board] = try boards.map { value in
            var board = try value.dictionary
            // These IDs become project directory names. Never accept a path from a server.
            guard let boardID = board["id"]?.text, boardID.count <= 256,
                  ![".", ".."].contains(boardID), !boardID.contains("/"), !boardID.contains("\\"), !boardID.contains(":"),
                  !boardID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { throw CloudSyncError.invalidWorkspace }
            let old = existing[boardID]
            board["version"] = .number(1)
            board["revision"] = .number(Double(old?.revision ?? 0))
            board["projectFilesPath"] = old?.projectFilesPath.map(CloudJSON.string)
            if board["title"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { board["title"] = .string("Untitled board") }
            let assets = try value["assets"]?.items ?? []
            let oldAssets = Dictionary(uniqueKeysWithValues: (old?.projectAssets ?? []).map { ($0.id, $0) })
            board["assets"] = .array(try assets.map { asset in
                guard let id = asset["id"]?.text, let name = asset["name"]?.text else { throw CloudSyncError.invalidWorkspace }
                let path = oldAssets[id]?.relativePath ?? CloudWorkspaceFiles.relativePath(boardID: boardID, assetID: id, name: name)
                return .object(["id": .string(id), "name": .string(name), "relativePath": .string(path)])
            })
            let oldNotes = Dictionary(uniqueKeysWithValues: (old?.notes ?? []).map { ($0.id, $0) })
            board["notes"] = .array(try (value["notes"]?.items ?? []).map { note in
                var item = try note.dictionary
                let native = item["id"]?.text.flatMap { oldNotes[$0] }
                item["imagePath"] = native?.imagePath.map(CloudJSON.string)
                item["reminderID"] = native?.reminderID.map(CloudJSON.string)
                item["additionalReminders"] = try native?.additionalReminders.map { try CloudJSON(encoding: $0) }
                return .object(item)
            })
            board["connections"] = .array(try (value["connections"]?.items ?? []).map { connection in
                var item = try connection.dictionary
                if item["arrow"] == nil || item["arrow"] == .null { item["arrow"] = .bool(item["direction"]?.text != "none") }
                return .object(item)
            })
            board["groups"] = .array(try (value["groups"]?.items ?? []).map { group in
                var item = try group.dictionary
                if item["color"] == nil || item["color"] == .null { item["color"] = .string("#E6E9F5") }
                return .object(item)
            })
            return try CloudJSON.object(board).decode(Board.self)
        }
        let decodedLists = try lists.map { value -> BoardList in
            var list = try value.dictionary
            list["revision"] = .number(0)
            if list["title"]?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { list["title"] = .string("Untitled list") }
            let defaults: [String: CloudJSON] = ["description": .string(""), "boardIDs": .array([]), "tags": .array([]), "flagged": .bool(false), "color": .string("#7A8BA8")]
            for (key, fallback) in defaults where list[key] == nil || list[key] == .null { list[key] = fallback }
            return try CloudJSON.object(list).decode(BoardList.self)
        }
        let pinned = decodedLists.first { $0.id == document["pinnedListID"]?.text }
        let desk = try document["desk"]?.dictionary ?? [:]
        let deskIDs = Set(decodedBoards.lazy.map(\.id).filter { desk[$0] == .bool(true) })
        return CloudLocalWorkspace(boards: decodedBoards, lists: decodedLists, pinnedListID: pinned?.id, deskIDs: deskIDs)
    }
}
