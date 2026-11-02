import Foundation
import CoreFoundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

import BoardCore

struct ToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()
let readOnly = ProcessInfo.processInfo.environment["COTHINK_MCP_READ_ONLY"] == "1"
let actor = ProcessInfo.processInfo.environment["COTHINK_MCP_ACTOR"] ?? "agent"

func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
}
func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
    try decoder.decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
}
func string(_ input: [String: Any], _ key: String) throws -> String {
    guard let value = input[key] as? String, !value.isEmpty else { throw ToolFailure(message: "Missing or invalid \(key)") }
    return value
}
func integer(_ input: [String: Any], _ key: String) throws -> Int {
    guard let n = input[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= Double(Int.min), n.doubleValue < Double(Int.max) else { throw ToolFailure(message: "Missing or invalid \(key)") }
    return n.intValue
}

let stringSchema: [String: Any] = ["type": "string"]
let integerSchema: [String: Any] = ["type": "integer", "minimum": 0]
let objectSchema: [String: Any] = ["type": "object"]
func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String] = []) -> [String: Any] {
    ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
}
let tools: [[String: Any]] = [
    tool("list_boards", "List available boards with their current contents and revisions.", [:]),
    tool("get_board", "Read a complete board, including its project folder, assets attached to notes, labeled directional connections, groups, and revision.", ["board_id": stringSchema], ["board_id"]),
    tool("get_board_context", "Read a graph-oriented overview of every note, group, connection, label, direction, attachment, and spatial position on a board.", ["board_id": stringSchema], ["board_id"]),
    tool("read_project_file", "Read an attached project file by asset ID. Returns extracted text for PDFs and text files, image content for pictures, or the original resource for other file types. The asset must belong to the board's project library.", ["board_id": stringSchema, "asset_id": stringSchema], ["board_id", "asset_id"]),
    tool("read_note_image", "Read the image attached directly to a note using the legacy image attachment field. Returns the image to the agent.", ["board_id": stringSchema, "note_id": stringSchema], ["board_id", "note_id"]),
    tool("board_history", "Read the actor, revision, and date of each board change.", ["board_id": stringSchema], ["board_id"]),
    tool("create_board", "Create an empty board.", ["title": stringSchema], ["title"]),
    tool("delete_board", "Delete a board and its history if its revision has not changed.", ["board_id": stringSchema, "expected_revision": integerSchema], ["board_id", "expected_revision"]),
    tool("replace_board", "Atomically replace an existing complete board. Provide its last observed revision to prevent overwriting concurrent edits.", ["board": objectSchema, "expected_revision": integerSchema], ["board", "expected_revision"]),
    tool("import_board", "Import a complete exported board JSON object. The store assigns an identity as needed.", ["board": objectSchema], ["board"]),
    tool("edit_board", "Apply ordered edits as one undoable change. Each operation has an action, collection when applicable, and item or id. Actions: rename (title); add (collection, item); update (collection, id, fields); delete (collection, id). Collections: notes, connections, groups, assets. For add, item must contain all required fields: note {id, text, x, y, width, height, color}; connection {id, from, to, arrow}; group {id, title, x, y, width, height, color}; asset {id, name, relativePath}. Notes may include assetIDs referencing board assets and imagePath for legacy direct image links. Boards may include projectFilesPath, the absolute folder holding their assets. Connection fields label and direction describe the relationship; direction is oneWay, twoWay, or none. For old connections without direction, arrow=true means oneWay and arrow=false means none. Asset relativePath must stay within projectFilesPath. IDs are unique nonempty strings, geometry is numeric and width/height are positive, color is a hex string, arrow is boolean, and connection endpoints and assetIDs must reference existing items. Groups may have memberIDs containing note IDs; moving a grouped note moves the group and its members. Notes, groups and connections may have strokeColor (#RRGGBB), strokeWidth (0 to 20), and strokeStyle (solid, dashed, dotted). Use get_board to obtain revision. Deleting a note removes its group memberships and connections.", ["board_id": stringSchema, "expected_revision": integerSchema, "operations": ["type": "array", "items": ["type": "object"]]], ["board_id", "expected_revision", "operations"]),
    tool("add_project_file", "Copy a local file into the board's project files folder and add it to the project library. Optionally attach it to a note. If the board has no custom projectFilesPath, the app's default per-board folder is used. The agent process must be able to read source_path.", ["board_id": stringSchema, "expected_revision": integerSchema, "source_path": stringSchema, "note_id": stringSchema], ["board_id", "expected_revision", "source_path"]),
    tool("unlock_note", "Remove a note from all groups so it can move independently. This is an undoable board edit.", ["board_id": stringSchema, "note_id": stringSchema, "expected_revision": integerSchema], ["board_id", "note_id", "expected_revision"]),
    tool("undo", "Undo the latest board change if its revision has not changed.", ["board_id": stringSchema, "expected_revision": integerSchema], ["board_id", "expected_revision"]),
    tool("redo", "Redo the latest undone board change if its revision has not changed.", ["board_id": stringSchema, "expected_revision": integerSchema], ["board_id", "expected_revision"])
]

func editBoard(_ args: [String: Any], store: BoardStore) throws -> Board {
    let id = try string(args, "board_id")
    let revision = try integer(args, "expected_revision")
    let original = try store.get(id)
    guard original.revision == revision else { throw ToolFailure(message: "Revision conflict. Read the board again before editing.") }
    guard var board = try object(original) as? [String: Any], let operations = args["operations"] as? [[String: Any]], !operations.isEmpty else { throw ToolFailure(message: "operations must be a nonempty array of objects") }
    for operation in operations {
        let action = try string(operation, "action")
        if action == "rename" {
            board["title"] = try string(operation, "title")
            continue
        }
        let collection = try string(operation, "collection")
        guard ["notes", "connections", "groups", "assets"].contains(collection) else { throw ToolFailure(message: "Invalid collection: \(collection)") }
        var items = board[collection] as? [[String: Any]] ?? []
        switch action {
        case "add":
            guard let item = operation["item"] as? [String: Any], let itemID = item["id"] as? String, !itemID.isEmpty else { throw ToolFailure(message: "add requires an item with a nonempty id") }
            guard !items.contains(where: { ($0["id"] as? String) == itemID }) else { throw ToolFailure(message: "Item already exists: \(itemID)") }
            items.append(item)
        case "update":
            let itemID = try string(operation, "id")
            guard let index = items.firstIndex(where: { ($0["id"] as? String) == itemID }), var fields = operation["fields"] as? [String: Any], fields["id"] == nil else { throw ToolFailure(message: "update requires an existing id and fields without id") }
            if (collection == "groups" || collection == "notes"), fields["x"] != nil || fields["y"] != nil {
                for key in ["x", "y"] {
                    if let value = fields[key] {
                        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw ToolFailure(message: "Invalid \(key)") }
                    }
                }
                var typed = try decode(board, as: Board.self)
                let groupID = collection == "groups" ? itemID : typed.groupContaining(noteID: itemID)?.id
                if let groupID, let oldX = (items[index]["x"] as? NSNumber)?.doubleValue,
                   let oldY = (items[index]["y"] as? NSNumber)?.doubleValue {
                    let newX = (fields["x"] as? NSNumber)?.doubleValue ?? oldX
                    let newY = (fields["y"] as? NSNumber)?.doubleValue ?? oldY
                    _ = typed.moveGroup(id: groupID, dx: newX - oldX, dy: newY - oldY)
                    guard let moved = try object(typed) as? [String: Any], let updatedItems = moved[collection] as? [[String: Any]] else { throw ToolFailure(message: "Could not move group") }
                    board = moved; items = updatedItems
                    fields.removeValue(forKey: "x"); fields.removeValue(forKey: "y")
                }
            }
            for (key, value) in fields { items[index][key] = value }
        case "delete":
            let itemID = try string(operation, "id")
            guard let index = items.firstIndex(where: { ($0["id"] as? String) == itemID }) else { throw ToolFailure(message: "Item does not exist: \(itemID)") }
            items.remove(at: index)
            if collection == "notes", let connections = board["connections"] as? [[String: Any]] {
                board["connections"] = connections.filter { ($0["from"] as? String) != itemID && ($0["to"] as? String) != itemID }
                if var groups = board["groups"] as? [[String: Any]] {
                    for i in groups.indices {
                        if let members = groups[i]["memberIDs"] as? [String] { groups[i]["memberIDs"] = members.filter { $0 != itemID } }
                    }
                    board["groups"] = groups
                }
            }
            if collection == "assets", var notes = board["notes"] as? [[String: Any]] {
                for i in notes.indices {
                    if let assetIDs = notes[i]["assetIDs"] as? [String] { notes[i]["assetIDs"] = assetIDs.filter { $0 != itemID } }
                }
                board["notes"] = notes
            }
        default:
            throw ToolFailure(message: "Unknown action: \(action)")
        }
        board[collection] = items
    }
    return try store.replace(decode(board, as: Board.self), expectedRevision: revision, actor: actor)
}

func addProjectFile(_ args: [String: Any], store: BoardStore) throws -> Board {
    let boardID = try string(args, "board_id")
    let expectedRevision = try integer(args, "expected_revision")
    let sourcePath = try string(args, "source_path")
    let board = try store.get(boardID)
    guard board.revision == expectedRevision else { throw BoardError.conflict }
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw ToolFailure(message: "source_path must point to an existing file")
    }
    let noteID = args["note_id"] as? String
    if let noteID, !board.notes.contains(where: { $0.id == noteID }) { throw ToolFailure(message: "Note not found: \(noteID)") }

    let destinationDirectory = board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? store.defaultProjectFilesDirectory(for: board.id)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

    let usedPaths = Set(board.projectAssets.map(\.relativePath))
    let sourceAlreadyInProject = source.deletingLastPathComponent().standardizedFileURL == destinationDirectory.standardizedFileURL
    let fileName = source.lastPathComponent
    let relativePath: String
    var copiedURL: URL?
    if sourceAlreadyInProject && !usedPaths.contains(fileName) {
        relativePath = fileName
    } else {
        relativePath = uniqueProjectFileName(fileName, in: destinationDirectory, reserved: usedPaths)
        let destination = destinationDirectory.appendingPathComponent(relativePath)
        try FileManager.default.copyItem(at: source, to: destination)
        copiedURL = destination
    }

    var updated = board
    let asset = ProjectAsset(name: fileName, relativePath: relativePath)
    updated.projectFilesPath = destinationDirectory.path
    updated.assets = board.projectAssets + [asset]
    if let noteID, let noteIndex = updated.notes.firstIndex(where: { $0.id == noteID }) {
        updated.notes[noteIndex].assetIDs = (updated.notes[noteIndex].assetIDs ?? []) + [asset.id]
    }
    do {
        return try store.replace(updated, expectedRevision: expectedRevision, actor: actor)
    } catch {
        if let copiedURL { try? FileManager.default.removeItem(at: copiedURL) }
        throw error
    }
}

func uniqueProjectFileName(_ fileName: String, in directory: URL, reserved: Set<String>) -> String {
    let source = URL(fileURLWithPath: fileName)
    let base = source.deletingPathExtension().lastPathComponent
    let ext = source.pathExtension
    var candidate = fileName
    var suffix = 2
    while reserved.contains(candidate) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
        candidate = ext.isEmpty ? "\(base) (\(suffix))" : "\(base) (\(suffix)).\(ext)"
        suffix += 1
    }
    return candidate
}

struct MCPToolContent {
    let blocks: [[String: Any]]
}

func boardContext(_ board: Board) -> [String: Any] {
    let notesByID = Dictionary(uniqueKeysWithValues: board.notes.map { ($0.id, $0) })
    let groupsByNote = Dictionary(grouping: board.groups.flatMap { group in
        (group.memberIDs ?? []).map { (noteID: $0, group: group) }
    }, by: \.noteID)
    let assetsByID = Dictionary(uniqueKeysWithValues: board.projectAssets.map { ($0.id, $0) })

    let notes: [[String: Any]] = board.notes.map { note in
        let groups = (groupsByNote[note.id] ?? []).map { $0.group }
        let attachments = (note.assetIDs ?? []).compactMap { assetsByID[$0] }.map { ["asset_id": $0.id, "name": $0.name] }
        let connected = board.connections.filter { $0.from == note.id || $0.to == note.id }.map { $0.id }
        return [
            "id": note.id,
            "text": note.text,
            "position": ["x": note.x, "y": note.y, "width": note.width, "height": note.height],
            "group_ids": groups.map(\.id),
            "group_titles": groups.map(\.title),
            "connection_ids": connected,
            "attachments": attachments,
            "has_legacy_image": note.imagePath != nil
        ]
    }
    let groups: [[String: Any]] = board.groups.map { group in
        let members = (group.memberIDs ?? []).compactMap { notesByID[$0] }
        return [
            "id": group.id,
            "title": group.title,
            "position": ["x": group.x, "y": group.y, "width": group.width, "height": group.height],
            "member_note_ids": members.map(\.id),
            "member_note_texts": members.map(\.text)
        ]
    }
    let connections: [[String: Any]] = board.connections.map { connection in
        [
            "id": connection.id,
            "from": ["id": connection.from, "text": notesByID[connection.from]?.text ?? "(missing note)"],
            "to": ["id": connection.to, "text": notesByID[connection.to]?.text ?? "(missing note)"],
            "label": connection.label ?? "",
            "direction": connection.effectiveDirection.rawValue
        ]
    }
    return [
        "board": ["id": board.id, "title": board.title, "revision": board.revision],
        "summary": ["note_count": notes.count, "group_count": groups.count, "connection_count": connections.count, "asset_count": board.projectAssets.count],
        "notes": notes,
        "groups": groups,
        "connections": connections,
        "unconnected_note_ids": board.notes.filter { note in !board.connections.contains { $0.from == note.id || $0.to == note.id } }.map(\.id),
        "project_files": board.projectAssets.map { ["asset_id": $0.id, "name": $0.name] }
    ]
}

func readProjectFile(_ args: [String: Any], store: BoardStore) throws -> MCPToolContent {
    let board = try store.get(string(args, "board_id"))
    let assetID = try string(args, "asset_id")
    guard let asset = board.projectAssets.first(where: { $0.id == assetID }) else { throw ToolFailure(message: "Project file not found on this board: \(assetID)") }
    guard !asset.relativePath.isEmpty, !asset.relativePath.hasPrefix("/"), !asset.relativePath.split(separator: "/").contains("..") else {
        throw ToolFailure(message: "Project file path is invalid")
    }
    let root = (board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? store.defaultProjectFilesDirectory(for: board.id))
        .standardizedFileURL.resolvingSymlinksInPath()
    let fileURL = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
    guard fileURL.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
        throw ToolFailure(message: "Project file resolves outside the board's project folder")
    }
    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 50 * 1024 * 1024 else {
        throw ToolFailure(message: "Project file is missing or exceeds the 50 MB MCP read limit")
    }
    let data = try Data(contentsOf: fileURL)
    let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    let metadata = "Attached file: \(asset.name) (\(asset.id), \(mime), \(size) bytes)"

    if mime.hasPrefix("image/") {
        return MCPToolContent(blocks: [["type": "text", "text": metadata], ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]])
    }
    if mime == "application/pdf", let pdf = PDFDocument(data: data) {
        let extracted = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let limit = 100_000
            let body = extracted.count > limit ? String(extracted.prefix(limit)) + "\n[Text truncated at 100,000 characters.]" : extracted
            return MCPToolContent(blocks: [["type": "text", "text": metadata + "\n\nExtracted PDF text:\n" + body]])
        }
        let pages = (0..<min(pdf.pageCount, 8)).compactMap { index -> [String: Any]? in
            guard let page = pdf.page(at: index), let image = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            return ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]
        }
        guard !pages.isEmpty else { throw ToolFailure(message: "Could not extract text or render pages from this PDF") }
        return MCPToolContent(blocks: [["type": "text", "text": metadata + "\nThis PDF has no selectable text. Showing up to the first 8 pages as images."]] + pages)
    }
    if let text = String(data: data, encoding: .utf8), !text.unicodeScalars.contains(where: { $0.value == 0 }) {
        let limit = 100_000
        let body = text.count > limit ? String(text.prefix(limit)) + "\n[Text truncated at 100,000 characters.]" : text
        return MCPToolContent(blocks: [["type": "text", "text": metadata + "\n\n" + body]])
    }

    return MCPToolContent(blocks: [
        ["type": "text", "text": metadata + "\nThe file is available as an embedded MCP resource."],
        ["type": "resource", "resource": ["uri": "cothink://boards/\(board.id)/assets/\(asset.id)", "mimeType": mime, "blob": data.base64EncodedString()]]
    ])
}

func readNoteImage(_ args: [String: Any], store: BoardStore) throws -> MCPToolContent {
    let board = try store.get(string(args, "board_id"))
    let noteID = try string(args, "note_id")
    guard let note = board.notes.first(where: { $0.id == noteID }) else { throw ToolFailure(message: "Note not found: \(noteID)") }
    guard let path = note.imagePath, !path.isEmpty else { throw ToolFailure(message: "This note has no directly attached image") }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true, let size = values.fileSize, size <= 50 * 1024 * 1024,
          let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType, mime.hasPrefix("image/") else {
        throw ToolFailure(message: "The attached image is missing, unsupported, or exceeds the 50 MB MCP read limit")
    }
    let data = try Data(contentsOf: url)
    return MCPToolContent(blocks: [
        ["type": "text", "text": "Image attached to note \(noteID) on board \(board.title) (\(mime), \(size) bytes)"],
        ["type": "image", "data": data.base64EncodedString(), "mimeType": mime]
    ])
}

func call(_ name: String, _ args: [String: Any], store: BoardStore) throws -> Any {
    if readOnly && !["list_boards", "get_board", "get_board_context", "read_project_file", "read_note_image", "board_history"].contains(name) { throw ToolFailure(message: "This MCP server is configured read-only") }
    switch name {
    case "list_boards": return try object(store.list())
    case "get_board": return try object(store.get(string(args, "board_id")))
    case "get_board_context": return boardContext(try store.get(string(args, "board_id")))
    case "read_project_file": return try readProjectFile(args, store: store)
    case "read_note_image": return try readNoteImage(args, store: store)
    case "board_history": return try object(store.history(string(args, "board_id")))
    case "create_board": return try object(store.create(title: string(args, "title"), actor: actor))
    case "delete_board": try store.delete(string(args, "board_id"), expectedRevision: integer(args, "expected_revision")); return ["deleted": true]
    case "replace_board":
        guard let board = args["board"] else { throw ToolFailure(message: "Missing board") }
        return try object(store.replace(decode(board, as: Board.self), expectedRevision: integer(args, "expected_revision"), actor: actor))
    case "import_board":
        guard let board = args["board"] else { throw ToolFailure(message: "Missing board") }
        return try object(store.importBoard(decode(board, as: Board.self), actor: actor))
    case "edit_board": return try object(editBoard(args, store: store))
    case "add_project_file": return try object(addProjectFile(args, store: store))
    case "unlock_note":
        let id = try string(args, "board_id"), noteID = try string(args, "note_id"), revision = try integer(args, "expected_revision")
        var board = try store.get(id)
        guard board.revision == revision else { throw BoardError.conflict }
        guard board.notes.contains(where: { $0.id == noteID }) else { throw ToolFailure(message: "Note not found") }
        guard board.unlockNote(id: noteID) else { return try object(board) }
        return try object(store.replace(board, expectedRevision: revision, actor: actor))
    case "undo": return try object(store.undo(string(args, "board_id"), actor: actor, expectedRevision: integer(args, "expected_revision")))
    case "redo": return try object(store.redo(string(args, "board_id"), actor: actor, expectedRevision: integer(args, "expected_revision")))
    default: throw ToolFailure(message: "Unknown tool: \(name)")
    }
}

func reply(_ message: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(message), let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]), var line = String(data: data, encoding: .utf8) else { return }
    line.append("\n")
    FileHandle.standardOutput.write(Data(line.utf8))
}
func result(_ id: Any, _ value: Any) { reply(["jsonrpc": "2.0", "id": id, "result": value]) }
func rpcError(_ id: Any, _ code: Int, _ message: String) { reply(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }

do {
    let store = try BoardStore()
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data), let request = raw as? [String: Any] else { rpcError(NSNull(), -32700, "Parse error"); continue }
        guard let id = request["id"] else { continue }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { rpcError(id, -32600, "Invalid request"); continue }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? "2025-03-26"
            let version = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"].contains(requested) ? requested : "2025-03-26"
            result(id, ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "CoThink Board", "version": "0.1.0"]])
        case "ping": result(id, [:])
        case "tools/list": result(id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { rpcError(id, -32602, "Missing tool name"); continue }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let value = try call(name, arguments, store: store)
                if let content = value as? MCPToolContent {
                    result(id, ["content": content.blocks, "isError": false])
                    continue
                }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                result(id, ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false])
            } catch {
                result(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default: rpcError(id, -32601, "Method not found")
        }
    }
} catch {
    FileHandle.standardError.write(Data("CoThink MCP failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
