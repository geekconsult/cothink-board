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
    tool("list_board_lists", "Read all board lists, descriptions, tags, flags, colors, board IDs and revisions.", [:]),
    tool("create_board_list", "Create a board list.", ["title": stringSchema], ["title"]),
    tool("update_board_list", "Replace a board list with the complete list object returned by list_board_lists, using its observed revision. Fields include title, description, boardIDs, tags, flagged and color.", ["list": objectSchema, "expected_revision": integerSchema], ["list", "expected_revision"]),
    tool("delete_board_list", "Delete a list without deleting its boards.", ["list_id": stringSchema, "expected_revision": integerSchema], ["list_id", "expected_revision"]),
    tool("set_board_metadata", "Set board tags, flagged and color. Supply the observed board revision; omit fields to leave them unchanged.", ["board_id": stringSchema, "expected_revision": integerSchema, "tags": ["type": "array", "items": stringSchema], "flagged": ["type": "boolean"], "color": stringSchema], ["board_id", "expected_revision"]),
    tool("set_board_wallpaper", "Set board wallpaper color (#RRGGBB), project image asset ID, or image opacity (0 to 1). Omit fields to keep them; use null to reset a field. Use add_project_file first to import an image. Changes are undoable.", ["board_id": stringSchema, "expected_revision": integerSchema, "color": ["type": ["string", "null"]], "asset_id": ["type": ["string", "null"]], "opacity": ["type": ["number", "null"], "minimum": 0, "maximum": 1]], ["board_id", "expected_revision"]),
    tool("list_boards", "List available boards with their current contents and revisions.", [:]),
    tool("get_board", "Read a complete board, including its project folder, assets attached to notes, labeled directional connections, groups, and revision.", ["board_id": stringSchema], ["board_id"]),
    tool("capture_board", "Return a PNG visual overview of the entire saved board and its revision, including off-screen notes, groups and connections. This is a reconstructed view, independent of the app window; use get_board_context for full text and coordinates.", ["board_id": stringSchema], ["board_id"]),
    tool("get_board_context", "Read a graph-oriented overview of every note, group, connection, label, direction, path, attachment, and spatial position on a board.", ["board_id": stringSchema], ["board_id"]),
    tool("read_project_file", "Read an attached project file by asset ID. Returns extracted text for PDFs and text files, image content for pictures, or the original resource for other file types. The asset must belong to the board's project library.", ["board_id": stringSchema, "asset_id": stringSchema], ["board_id", "asset_id"]),
    tool("read_note_image", "Read the image attached directly to a note using the legacy image attachment field. Returns the image to the agent.", ["board_id": stringSchema, "note_id": stringSchema], ["board_id", "note_id"]),
    tool("board_history", "Read the actor, revision, and date of each board change.", ["board_id": stringSchema], ["board_id"]),
    tool("create_board", "Create an empty board.", ["title": stringSchema], ["title"]),
    tool("delete_board", "Delete a board and its history if its revision has not changed.", ["board_id": stringSchema, "expected_revision": integerSchema], ["board_id", "expected_revision"]),
    tool("replace_board", "Atomically replace an existing complete board. Provide its last observed revision to prevent overwriting concurrent edits.", ["board": objectSchema, "expected_revision": integerSchema], ["board", "expected_revision"]),
    tool("import_board", "Import a complete exported board JSON object. The store assigns an identity as needed.", ["board": objectSchema], ["board"]),
    tool("edit_board", "Apply ordered edits as one undoable change. Actions: rename (title); add (collection, item); update (collection, id, fields); delete (collection, id). Collections: notes, connections, groups, assets. Required fields: note {id, text, x, y, width, height, color}; connection {id, from, to, arrow}; group {id, title, x, y, width, height, color}; asset {id, name, relativePath}. Notes reference assets with assetIDs. Connections support label, direction (oneWay, twoWay, none), route (straight, curved, custom) and routePoints, an array of up to 100 nonnegative board-coordinate objects {x, y}; curved uses the first point, custom uses all points as bends. With no points the app supplies a default. Notes, groups and connections support fontSize from 6 to 96, strokeColor, strokeWidth and strokeStyle. Groups may have memberIDs. Use get_board to obtain the revision. Deleting a note removes its group memberships and connections.", ["board_id": stringSchema, "expected_revision": integerSchema, "operations": ["type": "array", "items": ["type": "object"]]], ["board_id", "expected_revision", "operations"]),
    tool("add_project_file", "Copy a local file into the board's project files folder and add it to the project library. Optionally attach it to a note. If the board has no custom projectFilesPath, the app's default per-board folder is used. The agent process must be able to read source_path.", ["board_id": stringSchema, "expected_revision": integerSchema, "source_path": stringSchema, "note_id": stringSchema], ["board_id", "expected_revision", "source_path"]),
    tool("export_board_pdf", "Export a snapshot of a board to an absolute local PDF path using the same HTML templates as the app. template is editorial, studio, or minimal. Set overwrite to true to replace an existing file. Requires a macOS graphical session and the bundled cothink-pdf helper. This writes to the local filesystem and is disabled in read-only mode.", ["board_id": stringSchema, "expected_revision": integerSchema, "destination_path": stringSchema, "template": ["type": "string", "enum": ["editorial", "studio", "minimal"]], "overwrite": ["type": "boolean"]], ["board_id", "expected_revision", "destination_path", "template"]),
    tool("unlock_note", "Remove a note from all groups so it can move independently. This is an undoable board edit.", ["board_id": stringSchema, "note_id": stringSchema, "expected_revision": integerSchema], ["board_id", "note_id", "expected_revision"]),
    tool("lock_note", "Lock one note to a group so moving either moves them together. Transfers it from any previous group and keeps its current position. This is an undoable board edit.", ["board_id": stringSchema, "note_id": stringSchema, "group_id": stringSchema, "expected_revision": integerSchema], ["board_id", "note_id", "group_id", "expected_revision"]),
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
                if board["wallpaperAssetID"] as? String == itemID { board.removeValue(forKey: "wallpaperAssetID") }
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

private struct PDFExportRequest: Encodable {
    let board: Board
    let projectFolder: String
    let template: String
    let destination: String
    let overwrite: Bool
}

func exportBoardPDF(_ args: [String: Any], store: BoardStore) throws -> Any {
    let board = try store.get(string(args, "board_id"))
    let revision = try integer(args, "expected_revision")
    guard board.revision == revision else { throw BoardError.conflict }
    let template = try string(args, "template")
    guard BoardPDFTemplate(rawValue: template) != nil else { throw ToolFailure(message: "Invalid PDF template") }
    let path = try string(args, "destination_path")
    guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" else { throw ToolFailure(message: "destination_path must be an absolute PDF path") }
    if let value = args["overwrite"], CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() { throw ToolFailure(message: "overwrite must be a boolean") }
    let overwrite = args["overwrite"] as? Bool ?? false
    if !overwrite && FileManager.default.fileExists(atPath: path) { throw ToolFailure(message: "Destination already exists; set overwrite to true to replace it") }
    let folder = board.projectFilesPath ?? store.defaultProjectFilesDirectory(for: board.id).path
    let request = PDFExportRequest(board: board, projectFolder: folder, template: template, destination: path, overwrite: overwrite)
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("cothink-pdf")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw ToolFailure(message: "PDF helper not found; rebuild the app bundle") }
    let process = Process(), input = Pipe(), output = Pipe()
    process.executableURL = helper; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try process.run()
    do { try input.fileHandleForWriting.write(contentsOf: encoder.encode(request)); try input.fileHandleForWriting.close() }
    catch { process.terminate(); throw error }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolFailure(message: "PDF helper returned an invalid response") }
    guard process.terminationStatus == 0 else { throw ToolFailure(message: response["error"] as? String ?? "PDF export failed") }
    return response
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
            "fontSize": note.fontSize ?? 15,
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
            "fontSize": group.fontSize ?? 11,
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
            "direction": connection.effectiveDirection.rawValue,
            "route": connection.effectiveRoute.rawValue,
            "routePoints": (notesByID[connection.from].flatMap { from in notesByID[connection.to].map { connection.controlPoints(from: from, to: $0) } } ?? []).map { ["x": $0.x, "y": $0.y] },
            "fontSize": connection.fontSize ?? 11
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
    if readOnly && !["list_boards", "list_board_lists", "get_board", "get_board_context", "capture_board", "read_project_file", "read_note_image", "board_history"].contains(name) { throw ToolFailure(message: "This MCP server is configured read-only") }
    switch name {
    case "list_board_lists": return try object(store.lists())
    case "create_board_list": return try object(store.createList(title: string(args, "title")))
    case "update_board_list":
        guard let value = args["list"] else { throw ToolFailure(message: "Missing list") }
        return try object(store.replaceList(decode(value, as: BoardList.self), expectedRevision: integer(args, "expected_revision")))
    case "delete_board_list": try store.deleteList(string(args, "list_id"), expectedRevision: integer(args, "expected_revision")); return ["deleted": true]
    case "set_board_metadata":
        var board = try store.get(string(args, "board_id"))
        if let tags = args["tags"] as? [String] { board.tags = tags }
        if let flagged = args["flagged"] as? Bool { board.flagged = flagged }
        if let color = args["color"] as? String { board.color = color }
        return try object(store.replace(board, expectedRevision: integer(args, "expected_revision"), actor: actor))
    case "set_board_wallpaper":
        var board = try store.get(string(args, "board_id"))
        let revision = try integer(args, "expected_revision")
        guard board.revision == revision else { throw BoardError.conflict }
        guard ["color", "asset_id", "opacity"].contains(where: { args[$0] != nil }) else { throw ToolFailure(message: "Provide color, asset_id, or opacity") }
        if let value = args["color"] {
            if value is NSNull { board.wallpaperColor = nil }
            else if let color = value as? String { board.wallpaperColor = color }
            else { throw ToolFailure(message: "color must be a hex string or null") }
        }
        if let value = args["opacity"] {
            if value is NSNull { board.wallpaperOpacity = nil }
            else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { board.wallpaperOpacity = number.doubleValue }
            else { throw ToolFailure(message: "opacity must be a number or null") }
        }
        if let value = args["asset_id"] {
            if value is NSNull { board.wallpaperAssetID = nil }
            else if let id = value as? String, let asset = board.projectAssets.first(where: { $0.id == id }) {
                let root = (board.projectFilesPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? store.defaultProjectFilesDirectory(for: board.id)).standardizedFileURL.resolvingSymlinksInPath()
                let file = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/"), NSImage(contentsOf: file) != nil else { throw ToolFailure(message: "Wallpaper must be a readable image in the board's project folder") }
                board.wallpaperAssetID = id
            } else { throw ToolFailure(message: "asset_id must identify a project image or be null") }
        }
        return try object(store.replace(board, expectedRevision: revision, actor: actor))
    case "list_boards": return try object(store.list())
    case "get_board": return try object(store.get(string(args, "board_id")))
    case "capture_board": return try captureBoard(store.get(string(args, "board_id")), store: store)
    case "get_board_context":
        let board = try store.get(string(args, "board_id"))
        var context = boardContext(board)
        context["lists"] = try object(store.lists().filter { $0.boardIDs.contains(board.id) })
        context["board_metadata"] = ["tags": board.tags ?? [], "flagged": board.flagged ?? false, "color": board.color ?? ""] as [String: Any]
        context["wallpaper"] = ["color": board.wallpaperColor as Any? ?? NSNull(), "asset_id": board.wallpaperAssetID as Any? ?? NSNull(), "opacity": board.wallpaperOpacity ?? 0.45] as [String: Any]
        return context
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
    case "export_board_pdf": return try exportBoardPDF(args, store: store)
    case "unlock_note":
        let id = try string(args, "board_id"), noteID = try string(args, "note_id"), revision = try integer(args, "expected_revision")
        var board = try store.get(id)
        guard board.revision == revision else { throw BoardError.conflict }
        guard board.notes.contains(where: { $0.id == noteID }) else { throw ToolFailure(message: "Note not found") }
        guard board.unlockNote(id: noteID) else { return try object(board) }
        return try object(store.replace(board, expectedRevision: revision, actor: actor))
    case "lock_note":
        let id = try string(args, "board_id"), noteID = try string(args, "note_id"), groupID = try string(args, "group_id"), revision = try integer(args, "expected_revision")
        var board = try store.get(id)
        guard board.revision == revision else { throw BoardError.conflict }
        guard board.notes.contains(where: { $0.id == noteID }) else { throw ToolFailure(message: "Note not found") }
        guard board.groups.contains(where: { $0.id == groupID }) else { throw ToolFailure(message: "Group not found") }
        guard board.lockNote(id: noteID, toGroup: groupID) else { return try object(board) }
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
