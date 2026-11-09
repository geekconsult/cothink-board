import Foundation

// Stress-board generator for performance sampling. Usage: gen-stress-board <scratch-home>
// Writes 300 notes (200 loose + 100 tree children), 40 connections, 3 groups.

let home = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "stress-home"
let store = try BoardStore(directory: URL(fileURLWithPath: home, isDirectory: true))
let colors = ["#F8E2A7", "#CFE3F8", "#D9EED4", "#F2D8D8", "#E4DDF4"]
let words = ["แผน", "งาน", "รีวิว", "ไอเดีย", "โน้ต", "ตาราง", "ประชุม", "ส่งมอบ"]

var notes: [Note] = []
for i in 0..<300 {
    let body = (0..<(3 + i % 4)).map { words[($0 + i) % words.count] }.joined(separator: " ")
    var note = Note(id: "s\(i)", text: body, x: Double((i % 20) * 260), y: Double((i / 20) * 190))
    note.color = colors[i % colors.count]
    if i >= 200 { note.parentID = "s\((i - 200) / 2)" }
    notes.append(note)
}

var connections: [Connection] = []
for i in 0..<40 {
    connections.append(Connection(id: "c\(i)", from: "s\(i * 3)", to: "s\(i * 3 + 1)"))
}

var groups: [BoardGroup] = []
for g in 0..<3 {
    var group = BoardGroup(id: "g\(g)", x: Double(g * 1400), y: 80, width: 1150)
    group.memberIDs = (0..<12).map { "s\(g * 40 + $0)" }
    groups.append(group)
}

let reserved = try store.create(title: "Perf stress", actor: "user")
var saved = try store.get(reserved.id)
saved.notes = notes
saved.connections = connections
saved.groups = groups
_ = try store.replace(saved, expectedRevision: 0, actor: "user")
print("stress board written: 300 notes, 40 connections, 3 groups")
