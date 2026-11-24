import XCTest
import EventKit
import BoardCore
@testable import CoThinkApp

final class BoardReminderTests: XCTestCase {
    func testCreatesAppleReminderWithBoardLinkAndTimedAlarm() throws {
        let store = EKEventStore()
        let list = EKCalendar(for: .reminder, eventStore: store)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let item = BoardReminder.make(in: store, calendar: list, boardID: "planning",
                                      title: "ทบทวนแผนงาน", due: due)
        XCTAssertEqual(item.title, "ทบทวนแผนงาน")
        XCTAssertEqual(item.url?.absoluteString, "cothink://board/planning")
        XCTAssertEqual(item.calendar, list)
        XCTAssertEqual(item.alarms?.first?.absoluteDate, due)
        XCTAssertEqual(try XCTUnwrap(item.dueDateComponents?.date), due)
        let undated = BoardReminder.make(in: store, calendar: list, boardID: "design",
                                         title: "Sketch", due: nil)
        XCTAssertNotEqual(item.url, undated.url)
        XCTAssertNil(undated.dueDateComponents)
        XCTAssertTrue(undated.alarms?.isEmpty ?? true)
    }

    func testRefreshReflectsRenamesCompletionAndRemovalInAppleRecords() {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        let first = BoardReminder.make(in: store, calendar: calendar, boardID: "work", title: "First", due: nil)
        let next = BoardReminder.make(in: store, calendar: calendar, boardID: "work", title: "Next", due: nil)
        let other = BoardReminder.make(in: store, calendar: calendar, boardID: "home", title: "Other", due: nil)
        let otherList = EKCalendar(for: .reminder, eventStore: store)
        other.calendar = otherList
        next.url = nil
        first.url = URL(string: "https://example.org")
        first.title = "Renamed"
        first.isCompleted = true
        let visible = BoardReminder.inList(calendar.calendarIdentifier, items: [first, next, other])
        XCTAssertEqual(visible.map(\.title), ["Next", "Renamed"])
        XCTAssertEqual(visible.map(\.isCompleted), [false, true])
        XCTAssertEqual(BoardReminder.inList(calendar.calendarIdentifier, items: [other, first]), [first])
    }

    @MainActor
    func testPlacedReminderIsOneMovablePersistedCanvasObject() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BoardViewModel(storeDirectory: directory)
        let board = try XCTUnwrap(model.board)
        let point = CGPoint(x: 180, y: 220)
        XCTAssertTrue(model.placeReminder("test-item", title: "Review", boardID: board.id, at: point))
        XCTAssertTrue(model.placeReminder("test-item", title: "Review", boardID: board.id, at: point))
        let card = try XCTUnwrap(model.board?.notes.first(where: { $0.reminderID == "test-item" }))
        XCTAssertEqual(model.selectedNoteID, card.id)
        XCTAssertEqual(card.x, point.x)
        XCTAssertEqual(card.y, point.y)
        XCTAssertTrue(model.mutate { $0.moveSelection(noteIDs: [card.id], dx: 44, dy: 33) })
        let stored = try BoardStore(directory: directory).get(board.id)
        let cards = stored.notes.filter { $0.reminderID == "test-item" }
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.x, 224)
        XCTAssertEqual(cards.first?.y, 253)
        model.deleteSelection()
        XCTAssertFalse(model.board?.notes.contains { $0.id == card.id } ?? true)
        model.undo()
        XCTAssertEqual(model.board?.notes.first(where: { $0.id == card.id })?.reminderID, "test-item")
    }

    @MainActor
    func testAddToExistingBoxKeepsOrderAndPositionAcrossReloadAndUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BoardViewModel(storeDirectory: directory)
        let board = try XCTUnwrap(model.board)
        let point = CGPoint(x: 75, y: 130)
        XCTAssertTrue(model.placeReminder("first", title: "Plan", boardID: board.id, at: point))
        let boxID = try XCTUnwrap(model.selectedNoteID)
        for id in ["second", "third", "third"] {
            XCTAssertTrue(model.placeReminder(id, title: id, boardID: board.id, at: .zero, in: boxID))
        }
        let saved = try BoardStore(directory: directory).get(board.id)
        XCTAssertEqual(saved.notes.count, board.notes.count + 1)
        let box = try XCTUnwrap(saved.notes.first { $0.id == boxID })
        XCTAssertEqual(box.reminderItems.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(box.reminderItems.map(\.title), ["Plan", "second", "third"])
        XCTAssertEqual(box.x, point.x)
        XCTAssertEqual(box.y, point.y)
        XCTAssertGreaterThan(box.height, 108)
        XCTAssertFalse(model.placeReminder("other", title: "Other", boardID: board.id, at: .zero, in: "missing"))
        model.undo()
        XCTAssertEqual(model.board?.notes.first { $0.id == boxID }?.reminderItems.map(\.id), ["first", "second"])
    }

    func testEditingListAndPriorityPreservesTimeUntilChanged() throws {
        let store = EKEventStore()
        let first = EKCalendar(for: .reminder, eventStore: store)
        let second = EKCalendar(for: .reminder, eventStore: store)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let item = BoardReminder.make(in: store, calendar: first, boardID: "board", title: "Review", due: due)
        item.priority = 3
        let original = ReminderDetails(item: item)
        var edit = original
        edit.listID = second.calendarIdentifier
        edit.apply(to: item, calendar: second, original: original)
        XCTAssertEqual(item.calendar, second)
        XCTAssertEqual(item.priority, 3)
        XCTAssertEqual(item.alarms?.first?.absoluteDate, due)
        let next = ReminderDetails(item: item)
        edit = next
        edit.date = due.addingTimeInterval(3600)
        edit.priority = .medium
        edit.apply(to: item, calendar: second, original: next)
        XCTAssertEqual(item.priority, 5)
        XCTAssertEqual(item.alarms?.count, 1)
        XCTAssertEqual(item.alarms?.first?.absoluteDate, edit.date)
        XCTAssertEqual(item.dueDateComponents?.date, edit.date)
        let timed = ReminderDetails(item: item)
        edit.scheduled = false
        edit.priority = .none
        edit.apply(to: item, calendar: second, original: timed)
        XCTAssertNil(item.dueDateComponents)
        XCTAssertTrue(item.alarms?.isEmpty ?? true)
        XCTAssertEqual(item.priority, 0)
    }

}
