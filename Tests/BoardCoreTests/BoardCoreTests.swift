import XCTest
@testable import BoardCore

final class BoardCoreTests: XCTestCase {
    func testCanvasExtentExpandsForObjectBounds() {
        let empty = BoardRect.canvasExtent(containing: [])
        XCTAssertEqual(empty.width, 3000); XCTAssertEqual(empty.height, 2000)
        let far = BoardRect.canvasExtent(containing: [BoardRect(x: 2900, y: 1900, width: 400, height: 300)])
        XCTAssertEqual(far.width, 4000); XCTAssertEqual(far.height, 3000)
        let resized = BoardRect.canvasExtent(containing: [BoardRect(x: 100, y: 100, width: 4500, height: 100)])
        XCTAssertEqual(resized.width, 5500); XCTAssertEqual(resized.height, 2000)
    }
    func testBoardListPersistenceConflictsAndBoardRemoval() throws {
        let store = try store()
        let board = try store.create(title: "Project", actor: "user")
        var list = try store.createList(title: "Research")
        list.description = "Related work"; list.boardIDs = [board.id]; list.tags = ["planning"]; list.flagged = true
        let saved = try store.replaceList(list, expectedRevision: 0)
        XCTAssertEqual(try store.lists().first, saved)
        XCTAssertThrowsError(try store.replaceList(list, expectedRevision: 0))
        var invalid = saved; invalid.boardIDs.append("missing")
        XCTAssertThrowsError(try store.replaceList(invalid, expectedRevision: saved.revision))
        try store.delete(board.id, expectedRevision: board.revision)
        let after = try XCTUnwrap(store.lists().first)
        XCTAssertEqual(after.boardIDs, [])
        XCTAssertEqual(after.revision, saved.revision + 1)
        XCTAssertThrowsError(try store.deleteList(after.id, expectedRevision: saved.revision))
        try store.deleteList(after.id, expectedRevision: after.revision)
        XCTAssertTrue(try store.lists().isEmpty)
    }
    func testBoardTitleDraftDistinguishesNoEditFromRealConflict() {
        XCTAssertEqual(BoardTitleDraft.decision(baseline: "Alpha", draft: "Alpha", current: "Beta"), .unchanged)
        XCTAssertEqual(BoardTitleDraft.decision(baseline: "Alpha", draft: "My edit", current: "Beta"), .conflict)
        XCTAssertEqual(BoardTitleDraft.decision(baseline: "Alpha", draft: "My edit", current: "Alpha"), .save)
        XCTAssertEqual(BoardTitleDraft.decision(baseline: "Alpha", draft: "  ", current: "Alpha"), .invalid)
    }
    func testUnlockNoteKeepsOtherMembersAndAllowsIndependentMove() throws {
        let store = try store()
        var group = BoardGroup(id: "g", x: 100, y: 80)
        group.memberIDs = ["a", "b"]
        let original = try store.importBoard(Board(notes: [Note(id: "a"), Note(id: "b")], groups: [group]), actor: "user")
        var changed = original
        XCTAssertTrue(changed.unlockNote(id: "a"))
        XCTAssertNil(changed.groupContaining(noteID: "a"))
        XCTAssertEqual(changed.groups[0].memberIDs, ["b"])
        changed.notes[0].x += 50
        XCTAssertEqual(changed.groups[0].x, original.groups[0].x)
        let saved = try store.replace(changed, expectedRevision: original.revision, actor: "user")
        let undone = try store.undo(saved.id, actor: "user", expectedRevision: saved.revision)
        XCTAssertEqual(undone.groups[0].memberIDs, ["a", "b"])
    }
    func testMovingGroupPreservesMemberOffsetsAndCanBeUndone() throws {
        let store = try store()
        var group = BoardGroup(id: "g", x: 100, y: 80, width: 400, height: 300)
        group.memberIDs = ["a", "b"]
        let a = Note(id: "a", x: 110, y: 90)
        let b = Note(id: "b", x: 220, y: 160)
        let original = try store.importBoard(Board(notes: [a, b], groups: [group]), actor: "user")
        var moved = original
        XCTAssertTrue(moved.moveGroup(id: "g", dx: -500, dy: -500))
        XCTAssertEqual(moved.groups[0].x, 0)
        XCTAssertEqual(moved.notes[0].x, 10)
        XCTAssertEqual(moved.notes[1].x, 120)
        XCTAssertEqual(moved.notes[1].y - moved.notes[0].y, 70)
        let saved = try store.replace(moved, expectedRevision: original.revision, actor: "user")
        let undone = try store.undo(saved.id, actor: "user", expectedRevision: saved.revision)
        XCTAssertEqual(undone.notes, original.notes)
        XCTAssertEqual(undone.groups, original.groups)
    }
    func testSelectionWorksInEitherDirectionAndGroupMembersPersist() throws {
        let forward = BoardRect.selection(fromX: 20, fromY: 30, toX: 300, toY: 200)
        let reverse = BoardRect.selection(fromX: 300, fromY: 200, toX: 20, toY: 30)
        XCTAssertEqual(forward, reverse)
        let inside = Note(id: "inside", x: 50, y: 50, width: 80, height: 50)
        let outside = Note(id: "outside", x: 400, y: 50, width: 80, height: 50)
        XCTAssertTrue(forward.containsCenter(of: inside))
        XCTAssertFalse(forward.containsCenter(of: outside))
        var group = BoardGroup(x: forward.x, y: forward.y, width: forward.width, height: forward.height)
        group.memberIDs = [inside.id]
        let board = Board(notes: [inside, outside], groups: [group])
        let store = try store()
        let saved = try store.importBoard(board, actor: "test")
        XCTAssertEqual(try store.get(saved.id).groups[0].memberIDs, [inside.id])
        group.memberIDs = ["missing"]
        XCTAssertThrowsError(try store.importBoard(Board(notes: [inside], groups: [group]), actor: "test"))
    }
    func testLegacyJSONAndStyledRoundTrip() throws {
        let json = """
        {"version":1,"id":"old","title":"Old","revision":0,"notes":[{"id":"n1","text":"Note","x":10,"y":20,"width":200,"height":100,"color":"#FFFFFF"},{"id":"n2","text":"Other","x":400,"y":20,"width":100,"height":60,"color":"#FFFFFF"}],"connections":[{"id":"c","from":"n1","to":"n2","arrow":true}],"groups":[]}
        """
        var board = try JSONDecoder().decode(Board.self, from: Data(json.utf8))
        XCTAssertNil(board.notes[0].strokeStyle)
        board.notes[0].strokeColor = "#AABBCC"
        board.notes[0].strokeWidth = 4
        board.notes[0].strokeStyle = .dotted
        board.connections[0].strokeStyle = .dashed
        let store = try store()
        let saved = try store.importBoard(board, actor: "test")
        XCTAssertEqual(try store.get(saved.id), saved)
        XCTAssertEqual(try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testResizeCornersKeepOppositeCornerAndMinimumSize() {
        let rect = BoardRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(rect.resized(from: .topLeft, dx: 30, dy: 20), BoardRect(x: 130, y: 120, width: 170, height: 80))
        XCTAssertEqual(rect.resized(from: .topRight, dx: 30, dy: 20), BoardRect(x: 100, y: 120, width: 230, height: 80))
        XCTAssertEqual(rect.resized(from: .bottomLeft, dx: 30, dy: 20), BoardRect(x: 130, y: 100, width: 170, height: 120))
        XCTAssertEqual(rect.resized(from: .bottomRight, dx: 30, dy: 20), BoardRect(x: 100, y: 100, width: 230, height: 120))
        XCTAssertEqual(rect.resized(from: .topLeft, dx: 500, dy: 500), BoardRect(x: 220, y: 150, width: 80, height: 50))
    }
    func store() throws -> BoardStore {
        try BoardStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }
    func testBoardSurvivesReopenAndJSONRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = try BoardStore(directory: dir)
        var board = try a.create(title: "Ideas", actor: "user")
        board.notes = [Note(text: "One"), Note(text: "Two", x: 500)]
        board.connections = [Connection(from: board.notes[0].id, to: board.notes[1].id)]
        board.groups = [BoardGroup(title: "Group")]
        let saved = try a.replace(board, expectedRevision: 0, actor: "agent")
        let json = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(Board.self, from: json)
        XCTAssertEqual(saved, decoded)
        XCTAssertEqual(try BoardStore(directory: dir).get(saved.id), saved)
    }
    func testStaleWriteRejectedAndUndoRedoIncrementsRevision() throws {
        let s = try store()
        var b = try s.create(title: "Ideas", actor: "user")
        b.notes.append(Note(text: "hello"))
        let saved = try s.replace(b, expectedRevision: 0, actor: "agent")
        XCTAssertThrowsError(try s.replace(b, expectedRevision: 0, actor: "user"))
        let undone = try s.undo(b.id, actor: "user")
        XCTAssertTrue(undone.notes.isEmpty)
        XCTAssertGreaterThan(undone.revision, saved.revision)
        let redone = try s.redo(b.id, actor: "user")
        XCTAssertEqual(redone.notes.first?.text, "hello")
        XCTAssertGreaterThan(redone.revision, undone.revision)
        XCTAssertEqual(try s.history(b.id).map(\.actor), ["user", "agent", "user", "user"])
    }
    func testRejectInvalidConnectionsAndImportCopiesBoard() throws {
        let s = try store()
        var b = try s.create(title: "Ideas", actor: "user")
        b.connections = [Connection(from: "missing", to: "missing2")]
        XCTAssertThrowsError(try s.replace(b, expectedRevision: 0, actor: "user"))
        b.connections = []
        let copy = try s.importBoard(b, actor: "user")
        XCTAssertNotEqual(copy.id, b.id)
        XCTAssertEqual(try s.list().count, 2)
    }
}
