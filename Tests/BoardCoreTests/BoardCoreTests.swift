import XCTest
@testable import BoardCore

final class BoardCoreTests: XCTestCase {
    func testCopyGroupPreservesMembersAndConnectionsWithNewIDs() throws {
        var a = Note(id: "a", text: "A", x: 20, y: 30)
        a.assetIDs = ["asset"]
        let b = Note(id: "b", text: "B", x: 300, y: 30)
        let outside = Note(id: "c", text: "Outside", x: 600, y: 30)
        var group = BoardGroup(id: "g", x: 0, y: 0)
        group.memberIDs = ["a", "b"]
        var inside = Connection(id: "inside", from: "a", to: "b", direction: .twoWay, label: "related")
        inside.route = .custom; inside.routePoints = [ConnectionPoint(x: 250, y: 80)]
        let external = Connection(id: "external", from: "b", to: "c")
        var board = Board(notes: [a, b, outside], connections: [inside, external], groups: [group], assets: [ProjectAsset(id: "asset", name: "doc.pdf", relativePath: "doc.pdf")])
        let fragment = BoardFragment.capture(from: board, noteIDs: [], groupID: "g", connectionID: nil)
        XCTAssertEqual(fragment.notes.map(\.id), ["a", "b"])
        XCTAssertEqual(fragment.connections.map(\.id), ["inside"])
        let inserted = fragment.insert(into: &board, offset: 36, assetIDs: ["asset": "new-asset"])
        XCTAssertEqual(inserted.notes.count, 2)
        XCTAssertEqual(Set(board.groups.last!.memberIDs!), Set(inserted.notes))
        let copied = board.connections.last!
        XCTAssertEqual(copied.from, inserted.notes[0]); XCTAssertEqual(copied.to, inserted.notes[1])
        XCTAssertEqual(copied.effectiveDirection, .twoWay); XCTAssertEqual(copied.label, "related")
        XCTAssertEqual(copied.routePoints, [ConnectionPoint(x: 286, y: 116)])
        XCTAssertEqual(board.notes[3].assetIDs, ["new-asset"])
        XCTAssertEqual(board.notes[3].x, 56)
    }
    func testMultiSelectionMoveDragsNotesAndLockedGroupsTogether() {
        var board = Board(notes: [Note(id: "a", text: "A", x: 100, y: 100), Note(id: "b", text: "B", x: 500, y: 100), Note(id: "c", text: "C", x: 900, y: 100)])
        var group = BoardGroup(id: "g", x: 80, y: 80)
        group.memberIDs = ["a"]
        board.groups = [group]
        // Dragging the {a, b} selection moves both notes and a's locked group as one
        // unit, clamped so no object moves above the canvas edge.
        board.moveSelection(noteIDs: ["a", "b"], dx: 50, dy: -200)
        XCTAssertEqual(board.notes.first { $0.id == "a" }?.x, 150)
        XCTAssertEqual(board.notes.first { $0.id == "a" }?.y, 20)
        XCTAssertEqual(board.notes.first { $0.id == "b" }?.x, 550)
        XCTAssertEqual(board.notes.first { $0.id == "b" }?.y, 20)
        XCTAssertEqual(board.groups.first?.x, 130)
        XCTAssertEqual(board.groups.first?.y, 0)
        XCTAssertEqual(board.notes.first { $0.id == "c" }?.x, 900)
        XCTAssertEqual(board.notes.first { $0.id == "c" }?.y, 100)
    }

    func testMarqueeCopyPasteDuplicatesNotesLinksAndEnclosedGroups() {
        var board = Board(notes: [Note(id: "a", text: "A", x: 100, y: 30), Note(id: "b", text: "B", x: 400, y: 30), Note(id: "c", text: "C", x: 900, y: 30)])
        var group = BoardGroup(id: "g", x: 80, y: 10)
        group.memberIDs = ["a", "b"]
        board.groups = [group]
        board.connections = [Connection(id: "ab", from: "a", to: "b"), Connection(id: "bc", from: "b", to: "c")]
        // A marquee over a and b encloses group g completely, so the copy carries it.
        let enclosed = Set(board.groups
            .filter { !($0.memberIDs ?? []).isEmpty }
            .filter { ($0.memberIDs ?? []).allSatisfy { ["a", "b"].contains($0) } }
            .map(\.id))
        XCTAssertEqual(enclosed, ["g"])
        let fragment = BoardFragment.capture(from: board, noteIDs: ["a", "b"], groupID: nil, connectionID: nil, extraGroupIDs: enclosed)
        XCTAssertEqual(Set(fragment.notes.map(\.id)), ["a", "b"])
        XCTAssertEqual(fragment.groups.map(\.id), ["g"])
        XCTAssertEqual(fragment.connections.map(\.id), ["ab"])
        let inserted = fragment.insert(into: &board, offset: 36)
        XCTAssertEqual(inserted.notes.count, 2)
        XCTAssertEqual(board.notes.count, 5)
        XCTAssertEqual(board.groups.count, 2)
        XCTAssertEqual(board.connections.count, 3)
        XCTAssertEqual(Set(board.groups.last!.memberIDs!), Set(inserted.notes))
        let copied = board.connections.first { $0.id != "ab" && $0.id != "bc" }!
        XCTAssertEqual(copied.from, inserted.notes[0]); XCTAssertEqual(copied.to, inserted.notes[1])
        XCTAssertEqual(board.notes.first { $0.id == inserted.notes[0] }?.x, 136)
    }

    func testWallpaperPersistsValidatesAndAppearsInPDFHTML() throws {
        let store = try store()
        var board = try store.create(title: "Wallpaper", actor: "user")
        XCTAssertNil(board.wallpaperColor); XCTAssertNil(board.wallpaperAssetID)
        board.assets = [ProjectAsset(id: "wall", name: "wall.png", relativePath: "wall.png")]
        board.wallpaperColor = "#DDEEFF"; board.wallpaperAssetID = "wall"; board.wallpaperOpacity = 0.65
        let saved = try store.replace(board, expectedRevision: 0, actor: "user")
        let reloaded = try store.get(saved.id)
        XCTAssertEqual(reloaded.wallpaperColor, "#DDEEFF"); XCTAssertEqual(reloaded.wallpaperAssetID, "wall")
        XCTAssertEqual(reloaded.wallpaperOpacity, 0.65)
        let html = BoardPDFHTML.render(board: reloaded, template: .editorial, images: ["wall": "data:image/png;base64,YWJj"])
        XCTAssertTrue(html.contains("fill=\"#DDEEFF\"")); XCTAssertTrue(html.contains("<image href=\"data:image/png;base64,YWJj\""))
        XCTAssertTrue(html.contains("opacity=\"0.65\""))
        XCTAssertTrue(BoardPDFHTML.render(board: reloaded, template: .minimal).contains("Wallpaper image unavailable"))
        var invalid = reloaded; invalid.assets = []
        XCTAssertThrowsError(try store.replace(invalid, expectedRevision: saved.revision, actor: "user"))
        invalid = reloaded; invalid.wallpaperColor = "red"
        XCTAssertThrowsError(try store.replace(invalid, expectedRevision: saved.revision, actor: "user"))
        invalid = reloaded; invalid.wallpaperOpacity = 1.1
        XCTAssertThrowsError(try store.replace(invalid, expectedRevision: saved.revision, actor: "user"))
        let undone = try store.undo(saved.id, actor: "user", expectedRevision: saved.revision)
        XCTAssertNil(undone.wallpaperAssetID); XCTAssertNil(undone.wallpaperColor)
    }
    func testPDFTemplatesEscapeContentAndIncludeBoardContext() {
        var board = Board(title: "Planning <script>", notes: [Note(id: "a", text: "Alpha & detail\nsecond line\nสวัสดี"), Note(id: "b", text: "Beta", x: 400)])
        board.notes[0].assetIDs = ["asset"]
        board.assets = [ProjectAsset(id: "asset", name: "diagram <draft>.png", relativePath: "diagram.png")]
        var edge = Connection(from: "a", to: "b", direction: .twoWay, label: "relates & supports")
        edge.route = .custom; edge.routePoints = [ConnectionPoint(x: 300, y: 300)]
        board.connections = [edge]
        let outputs = BoardPDFTemplate.allCases.map { BoardPDFHTML.render(board: board, template: $0, images: ["asset": "data:image/png;base64,YWJj"]) }
        XCTAssertEqual(Set(outputs).count, 3)
        for html in outputs {
            XCTAssertTrue(html.contains("Planning &lt;script&gt;"))
            XCTAssertFalse(html.contains("<script>"))
            XCTAssertTrue(html.contains("Alpha &amp; detail\nsecond line"))
            XCTAssertTrue(html.contains("สวัสดี"))
            XCTAssertTrue(html.contains("relates &amp; supports"))
            XCTAssertTrue(html.contains("diagram &lt;draft&gt;.png"))
            XCTAssertTrue(html.contains("data:image/png;base64,YWJj"))
            XCTAssertTrue(html.contains("L 300.00 300.00"))
        }
        let omitted = BoardPDFHTML.render(board: board, template: .minimal, images: ["asset": ""])
        XCTAssertTrue(omitted.contains("Image unavailable or exceeds the export limit."))
    }
    func testLockAndUnlockSingleNoteAndTransferBetweenGroups() throws {
        let store = try store()
        let original = try store.importBoard(Board(notes: [Note(id: "n", x: 50, y: 70)], groups: [BoardGroup(id: "a"), BoardGroup(id: "b")]), actor: "user")
        var board = original
        XCTAssertTrue(board.lockNote(id: "n", toGroup: "a"))
        XCTAssertFalse(board.lockNote(id: "n", toGroup: "a"))
        XCTAssertFalse(board.lockNote(id: "missing", toGroup: "a"))
        XCTAssertTrue(board.lockNote(id: "n", toGroup: "b"))
        XCTAssertEqual(board.groups[0].memberIDs ?? [], [])
        XCTAssertEqual(board.groups[1].memberIDs, ["n"])
        XCTAssertEqual(board.notes[0].x, 50)
        let saved = try store.replace(board, expectedRevision: original.revision, actor: "user")
        XCTAssertTrue(board.moveGroup(id: "b", dx: 20, dy: 10))
        XCTAssertEqual(board.notes[0].x, 70)
        XCTAssertTrue(board.unlockNote(id: "n"))
        XCTAssertTrue(board.moveGroup(id: "b", dx: 20, dy: 10))
        XCTAssertEqual(board.notes[0].x, 70)
        let unlocked = try store.replace(board, expectedRevision: saved.revision, actor: "user")
        let undone = try store.undo(unlocked.id, actor: "user", expectedRevision: unlocked.revision)
        XCTAssertEqual(undone.groupContaining(noteID: "n")?.id, "b")
    }
    func testConnectionRoutesAndFontSizesPersistAndValidate() throws {
        let store = try store()
        var board = Board(notes: [Note(id: "a"), Note(id: "b", x: 500)])
        board.notes[0].fontSize = 24
        var group = BoardGroup(id: "g"); group.fontSize = 20; board.groups = [group]
        var edge = Connection(from: "a", to: "b")
        edge.route = .custom; edge.routePoints = [ConnectionPoint(x: 300, y: 400), ConnectionPoint(x: 450, y: 400)]; edge.fontSize = 18
        board.connections = [edge]
        let saved = try store.importBoard(board, actor: "user")
        let reopened = try store.get(saved.id)
        XCTAssertEqual(reopened.connections[0].routePoints, edge.routePoints)
        XCTAssertEqual(reopened.connections[0].effectiveRoute, .custom)
        XCTAssertEqual(reopened.notes[0].fontSize, 24)
        XCTAssertEqual(reopened.groups[0].fontSize, 20)
        XCTAssertEqual(reopened.connections[0].fontSize, 18)
        var bad = reopened; bad.connections[0].routePoints = [ConnectionPoint(x: -1, y: 0)]
        XCTAssertThrowsError(try store.replace(bad, expectedRevision: reopened.revision, actor: "agent"))
        bad = reopened; bad.notes[0].fontSize = 500
        XCTAssertThrowsError(try store.replace(bad, expectedRevision: reopened.revision, actor: "agent"))
        XCTAssertEqual(Connection(from: "a", to: "b").effectiveRoute, .straight)
    }
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
    func testMoveBoardAnchorsReorderEntriesAndPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try BoardStore(directory: dir)
        let created = try ["a", "b", "c", "d"].map { try store.create(title: $0, actor: "user") }
        let ids = created.map(\.id)
        try store.move(boardID: ids[1], to: .top)
        XCTAssertEqual(try store.list().map(\.title), ["b", "a", "c", "d"])
        try store.move(boardID: ids[1], to: .after(ids[3]))
        XCTAssertEqual(try store.list().map(\.title), ["a", "c", "d", "b"])
        try store.move(boardID: ids[2], to: .before(ids[0]))
        XCTAssertEqual(try store.list().map(\.title), ["c", "a", "d", "b"])
        try store.move(boardID: ids[1], to: .bottom)
        XCTAssertEqual(try store.list().map(\.title), ["c", "a", "d", "b"])
        try store.move(boardID: ids[0], to: .top)
        XCTAssertEqual(try store.list().map(\.title), ["a", "c", "d", "b"])
        let reopened = try BoardStore(directory: dir)
        XCTAssertEqual(try reopened.list().map(\.title), ["a", "c", "d", "b"])
        XCTAssertEqual(try reopened.list().map(\.revision), [0, 0, 0, 0])
    }
    func testMoveBoardEdgeCases() throws {
        let store = try store()
        let created = try ["a", "b", "c"].map { try store.create(title: $0, actor: "user") }
        let ids = created.map(\.id)
        XCTAssertThrowsError(try store.move(boardID: "missing", to: .top))
        try store.move(boardID: ids[0], to: .before("no-such-board"))
        XCTAssertEqual(try store.list().map(\.title), ["b", "c", "a"])
        try store.move(boardID: ids[0], to: .after(ids[0]))
        XCTAssertEqual(try store.list().map(\.title), ["b", "c", "a"])
        try store.move(boardID: ids[0], to: .before(ids[2]))
        XCTAssertEqual(try store.list().map(\.title), ["b", "a", "c"])
    }
    func testDeleteBoardsAtomicWithSingleListRevisionBump() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try BoardStore(directory: dir)
        let created = try ["a", "b", "c"].map { try store.create(title: $0, actor: "user") }
        let ids = created.map(\.id)
        var list = try store.createList(title: "Research")
        list.boardIDs = ids
        let saved = try store.replaceList(list, expectedRevision: 0)
        try store.deleteBoards([ids[0], ids[1]])
        XCTAssertEqual(try store.list().map(\.title), ["c"])
        let after = try XCTUnwrap(store.lists().first)
        XCTAssertEqual(after.boardIDs, [ids[2]])
        XCTAssertEqual(after.revision, saved.revision + 1)
        try store.deleteBoards(["unknown-1", "unknown-2"])
        XCTAssertEqual(try store.list().map(\.title), ["c"])
        XCTAssertEqual(try store.lists().first?.revision, saved.revision + 1)
        let reopened = try BoardStore(directory: dir)
        XCTAssertEqual(try reopened.list().map(\.title), ["c"])
        XCTAssertEqual(try reopened.lists().first?.boardIDs, [ids[2]])
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
    func testMultiSelectionMovesLockedGroupsOnlyOnceAndClampsTogether() {
        var group = BoardGroup(id: "g", x: 100, y: 80, width: 400, height: 300)
        group.memberIDs = ["a", "b"]
        var board = Board(notes: [Note(id: "a", x: 110, y: 90), Note(id: "b", x: 220, y: 160), Note(id: "c", x: 50, y: 40)], groups: [group])
        board.moveSelection(noteIDs: ["a", "b", "c"], dx: -100, dy: -100)
        XCTAssertEqual(board.notes.map(\.x), [60, 170, 0])
        XCTAssertEqual(board.notes.map(\.y), [50, 120, 0])
        XCTAssertEqual(board.groups[0].x, 50)
        XCTAssertEqual(board.groups[0].y, 40)
        XCTAssertEqual(board.groups[0].memberIDs, ["a", "b"])
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

    func testShapeFieldDecodesLegacyJSONAsNil() throws {
        let json = """
        {"id":"n1","text":"Note","x":10,"y":20,"width":200,"height":100,"color":"#FFFFFF"}
        """
        let note = try JSONDecoder().decode(Note.self, from: Data(json.utf8))
        XCTAssertNil(note.shape)
        var ellipse = Note(id: "e", x: 10, y: 20, width: 200, height: 100)
        ellipse.shape = .ellipse
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(ellipse))
        XCTAssertEqual(decoded.shape, .ellipse)
    }

    func testResizeCornersKeepOppositeCornerAndMinimumSize() {
        let rect = BoardRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(rect.resized(from: .topLeft, dx: 30, dy: 20), BoardRect(x: 130, y: 120, width: 170, height: 80))
        XCTAssertEqual(rect.resized(from: .topRight, dx: 30, dy: 20), BoardRect(x: 100, y: 120, width: 230, height: 80))
        XCTAssertEqual(rect.resized(from: .bottomLeft, dx: 30, dy: 20), BoardRect(x: 130, y: 100, width: 170, height: 120))
        XCTAssertEqual(rect.resized(from: .bottomRight, dx: 30, dy: 20), BoardRect(x: 100, y: 100, width: 230, height: 120))
        XCTAssertEqual(rect.resized(from: .topLeft, dx: 500, dy: 500), BoardRect(x: 220, y: 150, width: 80, height: 50))
    }
    func testShapeFactoryDefaults() {
        let expected: [NoteShape: (Double, Double)] = [.rectangle: (160, 120), .ellipse: (160, 120), .diamond: (160, 120), .line: (160, 80)]
        for (shape, size) in expected {
            let note = Note.makeShape(shape, x: 40, y: 60)
            XCTAssertFalse(note.id.isEmpty)
            XCTAssertEqual(note.x, 40); XCTAssertEqual(note.y, 60)
            XCTAssertEqual(note.width, size.0); XCTAssertEqual(note.height, size.1)
            XCTAssertEqual(note.color, "#F3F1EC")
            XCTAssertEqual(note.shape, shape)
            XCTAssertEqual(note.text, "")
        }
    }

    func testBoardRectResizedHonorsCustomMinimums() {
        let rect = BoardRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(rect.resized(from: .bottomRight, dx: -40, dy: -99, minWidth: 1, minHeight: 1), BoardRect(x: 100, y: 100, width: 160, height: 1))
        XCTAssertEqual(rect.resized(from: .bottomRight, dx: -40, dy: -99), BoardRect(x: 100, y: 100, width: 160, height: 50))
    }

    func testLineNoteGeometryValidationAllowsZeroHeight() throws {
        let store = try store()
        var lineBoard = try store.create(title: "Lines", actor: "test")
        lineBoard.notes = [Note(id: "l", x: 100, y: 100, width: 160, height: 0, color: "#F3F1EC", shape: .line)]
        XCTAssertNoThrow(try store.replace(lineBoard, expectedRevision: 0, actor: "test"))
        let flatBoard = Board(notes: [Note(id: "l", x: 100, y: 100, width: 160, height: 0, color: "#F3F1EC")])
        XCTAssertThrowsError(try store.importBoard(flatBoard, actor: "test")) { error in
            guard case BoardError.invalid = error else { return XCTFail("expected BoardError.invalid, got \(error)") }
        }
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

    // MARK: Mindmap tree layer (wave 1)

    func assertError(_ error: Error, _ expected: BoardError, file: StaticString = #filePath, line: UInt = #line) {
        switch (error as? BoardError, expected) {
        case (.notFound, .notFound), (.conflict, .conflict), (.noUndo, .noUndo), (.noRedo, .noRedo):
            break
        case (.invalid(let got), .invalid(let want)):
            XCTAssertEqual(got, want, file: file, line: line)
        default:
            XCTFail("\(error) is not \(expected)", file: file, line: line)
        }
    }
    func invalidReason(of error: Error) -> String {
        guard case BoardError.invalid(let reason) = error else { return "not invalid: \(error)" }
        return reason
    }

    func testParentIDRoundTripsAndLegacyJSONDecodesNil() throws {
        let json = """
        {"version":1,"id":"old","title":"Old","revision":0,"notes":[{"id":"n1","text":"Note","x":10,"y":20,"width":200,"height":100,"color":"#FFFFFF"},{"id":"n2","text":"Other","x":400,"y":20,"width":100,"height":60,"color":"#FFFFFF"}],"connections":[{"id":"c","from":"n1","to":"n2","arrow":true}],"groups":[]}
        """
        let legacy = try JSONDecoder().decode(Board.self, from: Data(json.utf8))
        XCTAssertNil(legacy.notes[0].parentID)
        XCTAssertNil(legacy.notes[1].parentID)
        var board = Board(notes: [Note(id: "n1"), Note(id: "n2")])
        board.notes[1].parentID = "n1"
        let store = try store()
        let saved = try store.importBoard(board, actor: "test")
        let reloaded = try store.get(saved.id)
        XCTAssertEqual(reloaded.notes[1].parentID, "n1")
        XCTAssertNil(reloaded.notes[0].parentID)
        let encoded = try JSONEncoder().encode(reloaded)
        XCTAssertEqual(try JSONDecoder().decode(Board.self, from: encoded), reloaded)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("\"parentID\""))
    }

    func testValidateRejectsMissingSelfAndCyclicParents() throws {
        let store = try store()
        let saved = try store.importBoard(Board(notes: [Note(id: "n1"), Note(id: "n2")]), actor: "test")
        XCTAssertEqual(try store.list().count, 1)
        var broken = saved
        broken.notes[0].parentID = "ghost"
        XCTAssertThrowsError(try store.importBoard(broken, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent") }
        XCTAssertThrowsError(try store.replace(broken, expectedRevision: saved.revision, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent") }
        broken = saved
        broken.notes[0].parentID = "n1"
        XCTAssertThrowsError(try store.importBoard(broken, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent cycle") }
        XCTAssertThrowsError(try store.replace(broken, expectedRevision: saved.revision, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent cycle") }
        broken = saved
        broken.notes[0].parentID = "n2"
        broken.notes[1].parentID = "n1"
        XCTAssertThrowsError(try store.importBoard(broken, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent cycle") }
        XCTAssertThrowsError(try store.replace(broken, expectedRevision: saved.revision, actor: "test")) { XCTAssertEqual(invalidReason(of: $0), "note parent cycle") }
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.get(saved.id), saved)
    }

    func testSetParentMovesDetachesAndRejectsCycles() throws {
        var board = Board(notes: [Note(id: "r"), Note(id: "a"), Note(id: "b"), Note(id: "c"), Note(id: "z", x: 3000, y: 3000)])
        try board.setNoteParent("a", to: "r")
        try board.setNoteParent("b", to: "a")
        try board.setNoteParent("c", to: "b")
        XCTAssertEqual(board.parent(of: "a")?.id, "r")
        XCTAssertEqual(board.children(of: "a").map(\.id), ["b"])
        XCTAssertEqual(board.descendantIDs(of: "r"), ["a", "b", "c"])
        XCTAssertTrue(board.isTreeLinked(noteID: "c"))
        XCTAssertFalse(board.isTreeLinked(noteID: "z"))
        let before = board
        XCTAssertThrowsError(try board.setNoteParent("missing", to: "r")) { assertError($0, .notFound) }
        XCTAssertThrowsError(try board.setNoteParent("a", to: "missing")) { assertError($0, .notFound) }
        XCTAssertThrowsError(try board.setNoteParent("a", to: "a")) { assertError($0, .invalid("self parent")) }
        XCTAssertThrowsError(try board.setNoteParent("b", to: "c")) { assertError($0, .invalid("cycle")) }
        XCTAssertThrowsError(try board.setNoteParent("r", to: "c")) { assertError($0, .invalid("cycle")) }
        XCTAssertEqual(board, before)
        try board.setNoteParent("b", to: "r")
        XCTAssertEqual(board.notes.first { $0.id == "b" }?.parentID, "r")
        XCTAssertEqual(board.children(of: "a").map(\.id), [])
        try board.setNoteParent("b", to: nil)
        XCTAssertNil(board.notes.first { $0.id == "b" }?.parentID)
    }

    func testDeleteNotesPromotesToNearestSurviving() {
        func chainBoard() -> Board {
            var board = Board(notes: [Note(id: "r"), Note(id: "a"), Note(id: "b"), Note(id: "c")])
            board.notes[1].parentID = "r"
            board.notes[2].parentID = "a"
            board.notes[3].parentID = "b"
            board.connections = [Connection(id: "ra", from: "r", to: "a"), Connection(id: "bc", from: "b", to: "c")]
            var group = BoardGroup(id: "g")
            group.memberIDs = ["r", "a"]
            board.groups = [group]
            return board
        }
        func parentID(_ id: String, in board: Board) -> String? {
            board.notes.first { $0.id == id }?.parentID
        }
        var board = chainBoard()
        board.deleteNotes(["a"])
        XCTAssertEqual(board.notes.map(\.id), ["r", "b", "c"])
        XCTAssertEqual(parentID("b", in: board), "r")
        XCTAssertEqual(parentID("c", in: board), "b")
        XCTAssertEqual(board.connections.map(\.id), ["bc"])
        XCTAssertEqual(board.groups[0].memberIDs, ["r"])
        board = chainBoard()
        board.deleteNotes(["a", "b"])
        XCTAssertEqual(board.notes.map(\.id), ["r", "c"])
        XCTAssertEqual(parentID("c", in: board), "r")
        XCTAssertEqual(board.connections.map(\.id), [])
        XCTAssertEqual(board.groups[0].memberIDs, ["r"])
        board = chainBoard()
        board.deleteNotes(["r"])
        XCTAssertEqual(board.notes.map(\.id), ["a", "b", "c"])
        XCTAssertNil(parentID("a", in: board))
        XCTAssertEqual(parentID("b", in: board), "a")
        XCTAssertEqual(parentID("c", in: board), "b")
        XCTAssertEqual(board.connections.map(\.id), ["bc"])
        XCTAssertEqual(board.groups[0].memberIDs, ["a"])
    }

    func testSelectionMoveCarriesSubtreeAndLockedGroups() {
        func family() -> Board {
            var board = Board(notes: [Note(id: "p", x: 100, y: 100), Note(id: "c1", x: 300, y: 300), Note(id: "c2", x: 500, y: 500), Note(id: "u", x: 800, y: 80)])
            board.notes[1].parentID = "p"
            board.notes[2].parentID = "p"
            var group = BoardGroup(id: "g", x: 80, y: 80)
            group.memberIDs = ["c2", "u"]
            board.groups = [group]
            return board
        }
        var board = family()
        board.moveSelection(noteIDs: ["p"], dx: 100, dy: 50)
        XCTAssertEqual(board.notes.first { $0.id == "p" }?.x, 200); XCTAssertEqual(board.notes.first { $0.id == "p" }?.y, 150)
        XCTAssertEqual(board.notes.first { $0.id == "c1" }?.x, 400); XCTAssertEqual(board.notes.first { $0.id == "c1" }?.y, 350)
        XCTAssertEqual(board.notes.first { $0.id == "c2" }?.x, 600); XCTAssertEqual(board.notes.first { $0.id == "c2" }?.y, 550)
        XCTAssertEqual(board.notes.first { $0.id == "u" }?.x, 900); XCTAssertEqual(board.notes.first { $0.id == "u" }?.y, 130)
        XCTAssertEqual(board.groups[0].x, 180); XCTAssertEqual(board.groups[0].y, 130)
        board = family()
        board.moveSelection(noteIDs: ["p"], dx: -500, dy: -500)
        XCTAssertEqual(board.notes.first { $0.id == "p" }?.x, 20); XCTAssertEqual(board.notes.first { $0.id == "p" }?.y, 20)
        XCTAssertEqual(board.notes.first { $0.id == "c1" }?.x, 220); XCTAssertEqual(board.notes.first { $0.id == "c1" }?.y, 220)
        XCTAssertEqual(board.notes.first { $0.id == "c2" }?.x, 420); XCTAssertEqual(board.notes.first { $0.id == "c2" }?.y, 420)
        XCTAssertEqual(board.notes.first { $0.id == "u" }?.x, 720); XCTAssertEqual(board.notes.first { $0.id == "u" }?.y, 0)
        XCTAssertEqual(board.groups[0].x, 0); XCTAssertEqual(board.groups[0].y, 0)
    }

    func testMindmapLayoutDeterministicOverlapFree() {
        func familyBoard() -> Board {
            var board = Board(notes: [
                Note(id: "r", x: 100, y: 100, width: 200, height: 80),
                Note(id: "a", x: 900, y: 40, width: 200, height: 80),
                Note(id: "b", x: 700, y: 40, width: 200, height: 80),
                Note(id: "a1", x: 1300, y: 800, width: 200, height: 80),
                Note(id: "solo", x: 2000, y: 1000, width: 200, height: 80),
            ])
            board.notes[1].parentID = "r"
            board.notes[2].parentID = "r"
            board.notes[3].parentID = "a"
            return board
        }
        let board = familyBoard()
        let first = board.mindmapLayout(rootID: "r")
        let second = board.mindmapLayout(rootID: "r")
        XCTAssertEqual(first.mapValues { [$0.x, $0.y] }, second.mapValues { [$0.x, $0.y] })
        XCTAssertEqual(Set(first.keys), ["a", "b", "a1"])
        // a and b share a pre-layout y, so array index breaks the tie: a stacks above b.
        // Subtree heights are 80, so the 184-tall block centers on r's center (140): a(48), b(152).
        XCTAssertEqual(first["a"]?.x, 360); XCTAssertEqual(first["a"]?.y, 48)
        XCTAssertEqual(first["b"]?.x, 360); XCTAssertEqual(first["b"]?.y, 152)
        XCTAssertEqual(first["a1"]?.x, 620); XCTAssertEqual(first["a1"]?.y, 48)
        let spread = board.mindmapLayout(rootID: "r", gapX: 100, gapY: 10)
        XCTAssertEqual(spread["a"]?.x, 400); XCTAssertEqual(spread["a"]?.y, 55)
        XCTAssertEqual(spread["b"]?.x, 400); XCTAssertEqual(spread["b"]?.y, 145)
        XCTAssertEqual(spread["a1"]?.x, 700); XCTAssertEqual(spread["a1"]?.y, 55)
        let rects = first.values.map { BoardRect(x: $0.x, y: $0.y, width: 200, height: 80) }
        for (index, rect) in rects.enumerated() {
            for other in rects[(index + 1)...] {
                let disjoint = rect.x + rect.width <= other.x || other.x + other.width <= rect.x
                    || rect.y + rect.height <= other.y || other.y + other.height <= rect.y
                XCTAssertTrue(disjoint, "\(rect) overlaps \(other)")
            }
        }
        var tidied = familyBoard()
        tidied.tidySubtree(rootID: "r")
        XCTAssertEqual(tidied.notes.first { $0.id == "r" }?.x, 100); XCTAssertEqual(tidied.notes.first { $0.id == "r" }?.y, 100)
        XCTAssertEqual(tidied.notes.first { $0.id == "a" }?.x, 360); XCTAssertEqual(tidied.notes.first { $0.id == "a" }?.y, 48)
        XCTAssertEqual(tidied.notes.first { $0.id == "b" }?.x, 360); XCTAssertEqual(tidied.notes.first { $0.id == "b" }?.y, 152)
        XCTAssertEqual(tidied.notes.first { $0.id == "a1" }?.x, 620); XCTAssertEqual(tidied.notes.first { $0.id == "a1" }?.y, 48)
        XCTAssertEqual(tidied.notes.first { $0.id == "solo" }?.x, 2000); XCTAssertEqual(tidied.notes.first { $0.id == "solo" }?.y, 1000)
        let once = tidied
        tidied.tidySubtree(rootID: "r")
        XCTAssertEqual(tidied, once)
    }

    func testFragmentPasteDropsParentOutsideCopy() {
        var board = Board(notes: [Note(id: "p"), Note(id: "k")])
        board.notes[1].parentID = "p"
        let childOnly = BoardFragment.capture(from: board, noteIDs: ["k"], groupID: nil, connectionID: nil)
        XCTAssertEqual(childOnly.notes.map(\.id), ["k"])
        childOnly.insert(into: &board, offset: 36)
        XCTAssertEqual(board.notes.count, 3)
        XCTAssertNil(board.notes[2].parentID)
        let pair = BoardFragment.capture(from: board, noteIDs: ["p", "k"], groupID: nil, connectionID: nil)
        pair.insert(into: &board, offset: 36)
        XCTAssertEqual(board.notes.count, 5)
        XCTAssertNil(board.notes[3].parentID)
        XCTAssertEqual(board.notes[4].parentID, board.notes[3].id)
    }

    func testTidySubtreeScopeAndIdempotence() {
        var board = Board(notes: [Note(id: "r1", x: 0, y: 0), Note(id: "c1", x: 1000, y: 1000), Note(id: "r2", x: 50, y: 900), Note(id: "c2", x: 2000, y: 2000)])
        board.notes[1].parentID = "r1"
        board.notes[3].parentID = "r2"
        board.tidySubtree(rootID: "r1")
        XCTAssertEqual(board.notes.first { $0.id == "r1" }?.x, 0); XCTAssertEqual(board.notes.first { $0.id == "r1" }?.y, 0)
        XCTAssertEqual(board.notes.first { $0.id == "c1" }?.x, 260); XCTAssertEqual(board.notes.first { $0.id == "c1" }?.y, 0)
        XCTAssertEqual(board.notes.first { $0.id == "r2" }?.x, 50); XCTAssertEqual(board.notes.first { $0.id == "r2" }?.y, 900)
        XCTAssertEqual(board.notes.first { $0.id == "c2" }?.x, 2000); XCTAssertEqual(board.notes.first { $0.id == "c2" }?.y, 2000)
        let scoped = board
        board.tidySubtree(rootID: "r1")
        board.tidySubtree(rootID: "missing")
        XCTAssertEqual(board, scoped)
        board.tidySubtree(rootID: nil)
        XCTAssertEqual(board.notes.first { $0.id == "c2" }?.x, 310); XCTAssertEqual(board.notes.first { $0.id == "c2" }?.y, 900)
        let once = board
        board.tidySubtree(rootID: nil)
        XCTAssertEqual(board, once)
        board.notes.append(Note(id: "solo", x: 1234, y: 4321))
        let quiet = board
        board.tidySubtree(rootID: "solo")
        board.tidySubtree(rootID: "missing")
        XCTAssertEqual(board, quiet)
    }

    // MARK: Fold/collapse data layer (wave 2)

    func testToggleFoldHidesSubtreeAndNestedFoldsCompose() {
        func family() -> Board {
            var board = Board(notes: [Note(id: "r"), Note(id: "a"), Note(id: "b"), Note(id: "c"), Note(id: "a1"), Note(id: "a2")])
            board.notes[1].parentID = "r"
            board.notes[2].parentID = "r"
            board.notes[3].parentID = "r"
            board.notes[4].parentID = "a"
            board.notes[5].parentID = "a1"
            return board
        }
        var board = family()
        XCTAssertTrue(board.hiddenNoteIDs().isEmpty)
        XCTAssertTrue(board.toggleFold(noteID: "r"))
        XCTAssertEqual(board.hiddenNoteIDs(), ["a", "b", "c", "a1", "a2"])
        XCTAssertTrue(board.toggleFold(noteID: "r"))
        XCTAssertTrue(board.hiddenNoteIDs().isEmpty)
        XCTAssertTrue(board.toggleFold(noteID: "a"))
        XCTAssertEqual(board.hiddenNoteIDs(), ["a1", "a2"])
        XCTAssertTrue(board.toggleFold(noteID: "r"))
        XCTAssertEqual(board.hiddenNoteIDs(), ["a", "b", "c", "a1", "a2"])
        XCTAssertTrue(board.toggleFold(noteID: "r"))
        XCTAssertEqual(board.hiddenNoteIDs(), ["a1", "a2"])
        XCTAssertEqual(board.notes.first { $0.id == "a" }?.collapsed, true)
        XCTAssertNil(board.notes.first { $0.id == "r" }?.collapsed)
        let before = board
        XCTAssertFalse(board.toggleFold(noteID: "a2"))
        XCTAssertFalse(board.toggleFold(noteID: "ghost"))
        XCTAssertEqual(board, before)
    }

    func testCollapsedRoundTripsAndLegacyJSONDecodesNil() throws {
        let json = """
        {"version":1,"id":"old","title":"Old","revision":0,"notes":[{"id":"n1","text":"Note","x":10,"y":20,"width":200,"height":100,"color":"#FFFFFF"},{"id":"n2","text":"Other","x":400,"y":20,"width":100,"height":60,"color":"#FFFFFF"}],"connections":[{"id":"c","from":"n1","to":"n2","arrow":true}],"groups":[]}
        """
        let legacy = try JSONDecoder().decode(Board.self, from: Data(json.utf8))
        XCTAssertNil(legacy.notes[0].collapsed)
        XCTAssertNil(legacy.notes[1].collapsed)
        var board = Board(notes: [Note(id: "n1", text: "Root"), Note(id: "n2"), Note(id: "n3")])
        board.notes[1].parentID = "n1"
        board.notes[2].parentID = "n1"
        board.notes[2].collapsed = false
        XCTAssertTrue(board.toggleFold(noteID: "n1"))
        let store = try store()
        let saved = try store.importBoard(board, actor: "test")
        let reloaded = try store.get(saved.id)
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(reloaded.notes.first { $0.id == "n1" }?.collapsed, true)
        XCTAssertNil(reloaded.notes.first { $0.id == "n2" }?.collapsed)
        XCTAssertEqual(reloaded.notes.first { $0.id == "n3" }?.collapsed, false)
        let encoded = try JSONEncoder().encode(reloaded)
        XCTAssertEqual(try JSONDecoder().decode(Board.self, from: encoded), reloaded)
        XCTAssertTrue(String(data: encoded, encoding: .utf8)!.contains("\"collapsed\""))
    }

    func testDeleteFoldedParentPromotesVisibleChildren() {
        var board = Board(notes: [Note(id: "r"), Note(id: "a"), Note(id: "b"), Note(id: "c")])
        board.notes[1].parentID = "r"
        board.notes[2].parentID = "r"
        board.notes[3].parentID = "r"
        XCTAssertTrue(board.toggleFold(noteID: "r"))
        XCTAssertEqual(board.hiddenNoteIDs(), ["a", "b", "c"])
        board.deleteNotes(["r"])
        XCTAssertEqual(board.notes.map(\.id), ["a", "b", "c"])
        XCTAssertTrue(board.notes.allSatisfy { $0.parentID == nil && $0.collapsed == nil })
        XCTAssertTrue(board.hiddenNoteIDs().isEmpty)
    }

    func testLineFlippedDecodesLegacyJSONAsNil() throws {
        let json = """
        {"id":"n1","text":"Note","x":10,"y":20,"width":200,"height":100,"color":"#FFFFFF"}
        """
        let note = try JSONDecoder().decode(Note.self, from: Data(json.utf8))
        XCTAssertNil(note.lineFlipped)
        var line = Note(id: "l", x: 0, y: 0, width: 160, height: 0, color: "#F3F1EC", shape: .line)
        line.lineFlipped = true
        let decoded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded.lineFlipped, true)
    }

    func testShapeFactoryTakesFrameAndFlip() {
        let line = Note.makeShape(.line, x: 5, y: 6, width: 100, height: 0, flipped: true)
        XCTAssertEqual(line.x, 5); XCTAssertEqual(line.y, 6)
        XCTAssertEqual(line.width, 100); XCTAssertEqual(line.height, 0)
        XCTAssertEqual(line.lineFlipped, true)
        let rect = Note.makeShape(.rectangle, x: 1, y: 2, width: 70, height: 40, flipped: true)
        XCTAssertEqual(rect.x, 1); XCTAssertEqual(rect.y, 2)
        XCTAssertEqual(rect.width, 70); XCTAssertEqual(rect.height, 40)
        XCTAssertNil(rect.lineFlipped)
        let defaultLine = Note.makeShape(.line, x: 0, y: 0)
        XCTAssertEqual(defaultLine.width, 160); XCTAssertEqual(defaultLine.height, 80)
        XCTAssertEqual(defaultLine.lineFlipped, false)
    }

    func testSvgLineRespectsFlippedDiagonal() {
        func lineBoard(flipped: Bool) -> Board {
            var board = Board(notes: [Note(id: "l", x: 10, y: 20, width: 100, height: 0, color: "#F3F1EC", shape: .line)])
            board.notes[0].lineFlipped = flipped
            return board
        }
        let unflipped = BoardPDFHTML.svg(board: lineBoard(flipped: false), images: [:])
        XCTAssertTrue(unflipped.contains("x1=\"10.00\""))
        XCTAssertTrue(unflipped.contains("x2=\"110.00\""))
        let flipped = BoardPDFHTML.svg(board: lineBoard(flipped: true), images: [:])
        XCTAssertTrue(flipped.contains("x1=\"110.00\""))
        XCTAssertTrue(flipped.contains("x2=\"10.00\""))
    }

    func testSVGOverviewHidesFoldedSubtree() {
        func family(folded: Bool) -> Board {
            var board = Board(notes: [
                Note(id: "r", text: "Root card", x: 0, y: 0, width: 200, height: 80),
                Note(id: "a", text: "Hidden child card", x: 400, y: 0, width: 200, height: 80),
                Note(id: "v", text: "Visible note card", x: 0, y: 300, width: 200, height: 80),
            ])
            board.notes[1].parentID = "r"
            board.connections = [Connection(id: "va", from: "v", to: "a", label: "V to A link")]
            if folded { XCTAssertTrue(board.toggleFold(noteID: "r")) }
            return board
        }
        let unfolded = BoardPDFHTML.svg(board: family(folded: false), images: [:])
        XCTAssertTrue(unfolded.contains("Hidden child card"))
        XCTAssertTrue(unfolded.contains("V to A link"))
        XCTAssertTrue(unfolded.contains("M 200.00 40.00 L 300.00 40.00"))
        let folded = BoardPDFHTML.svg(board: family(folded: true), images: [:])
        XCTAssertFalse(folded.contains("Hidden child card"))
        XCTAssertTrue(folded.contains("Visible note card"))
        XCTAssertFalse(folded.contains("V to A link"))
        XCTAssertFalse(folded.contains("M 200.00 40.00 L 300.00 40.00"))
    }
}
