import Foundation
import CoreFoundation
import BoardCore

let coordinateSchema: [String: Any] = ["type": "number", "minimum": 0, "maximum": 10_000_000]
let positionSchema: [String: Any] = ["type": "object", "properties": ["x": coordinateSchema, "y": coordinateSchema],
                                     "required": ["x","y"], "additionalProperties": false]
let reminderRowsSchema: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 500, "items": [
    "type": "object", "required": ["title"], "additionalProperties": false,
    "properties": ["title": ["type": "string", "minLength": 1, "maxLength": 20000],
                   "completed": ["type": "boolean"], "flagged": ["type": "boolean"],
                   "priority": ["type": "integer", "minimum": 0, "maximum": 9],
                   "due": ["type": "string", "description": "YYYY-MM-DD or an ISO timestamp with timezone"]]
] as [String: Any]]

private func number(_ value: Any?, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
    guard let value else { return fallback }
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), range.contains(n.doubleValue) else {
        throw ToolFailure(message: "Invalid numeric coordinate or size")
    }
    return n.doubleValue
}

func canvasPosition(_ raw: Any?) throws -> (x: Double, y: Double)? {
    guard let raw else { return nil }
    guard let fields = raw as? [String: Any], Set(fields.keys) == ["x","y"] else {
        throw ToolFailure(message: "position must contain x and y")
    }
    return (x: try number(fields["x"], default: 120, range: 0...10_000_000),
                   y: try number(fields["y"], default: 100, range: 0...10_000_000))
}

func boardReminderRows(_ raw: Any?) throws -> [CloudReminderItem] {
    guard let fields = raw as? [[String: Any]], (1...500).contains(fields.count),
          fields.allSatisfy({ Set($0.keys).isSubset(of: ["title","completed","due","flagged","priority"]) }) else {
        throw ToolFailure(message: "Provide 1–500 reminder items with title and optional completed, due, flagged and priority")
    }
    var rows = try decode(fields, as: [CloudReminderItem].self)
    let iso = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let calendarDate = DateFormatter()
    calendarDate.locale = Locale(identifier: "en_US_POSIX")
    calendarDate.timeZone = TimeZone(secondsFromGMT: 0)
    calendarDate.dateFormat = "yyyy-MM-dd"
    for i in rows.indices {
        rows[i].title = rows[i].title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20000).contains(rows[i].title.count), (0...9).contains(rows[i].priority ?? 0) else {
            throw ToolFailure(message: "Use a nonempty reminder title and priority between 0 and 9")
        }
        if let due = rows[i].due {
            let day = calendarDate.date(from: due).map(calendarDate.string(from:))
            guard day == due || iso.date(from: due) != nil || fractional.date(from: due) != nil else {
                throw ToolFailure(message: "Use an ISO date or a timestamp with timezone for due")
            }
        }
    }
    return rows
}

func writeCanvasNote(_ args: [String: Any], reminder: Bool, store: BoardStore) throws -> Board {
    var board = try store.get(string(args, "board_id"))
    let revision = try integer(args, "expected_revision")
    guard board.revision == revision else { throw BoardError.conflict }
    if reminder {
        let rows = try boardReminderRows(args["items"])
        let point = try canvasPosition(args["position"])
        if args["note_id"] != nil {
            let id = try string(args, "note_id")
            guard point == nil, let index = board.notes.firstIndex(where: { $0.id == id && $0.isReminderBox }) else {
                throw ToolFailure(message: "Provide an existing reminder box ID and omit position when updating")
            }
            guard board.notes[index].reminderID == nil else { throw ToolFailure(message: "Edit Apple-linked reminders in the Mac app") }
            board.notes[index].reminderSnapshots = rows
        } else {
            var note = Note(x: point?.x ?? 120, y: point?.y ?? 100, width: 300, height: Double(min(700,54 + rows.count * 56)))
            note.reminderSnapshots = rows
            board.notes.append(note)
        }
    } else {
        let text = try string(args, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        let color = args["color"] as? String ?? "#f1f2f3"
        guard (1...20000).contains(text.count), color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw ToolFailure(message: "Provide note text and a valid hex color")
        }
        let note = Note(text: text, x: try number(args["x"], default: 120, range: 0...10_000_000),
                        y: try number(args["y"], default: 100, range: 0...10_000_000),
                        width: try number(args["width"], default: 220, range: 80...700),
                        height: try number(args["height"], default: 150, range: 50...700), color: color)
        board.notes.append(note)
    }
    return try store.replace(board, expectedRevision: revision, actor: actor)
}
