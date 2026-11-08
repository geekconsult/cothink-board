import XCTest
@testable import CoThinkApp
import BoardCore

final class TabRoutingTests: XCTestCase {
    @MainActor
    private func freshModel() throws -> BoardViewModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cothink-tab-tests-\(UUID().uuidString)", isDirectory: true)
        let model = BoardViewModel(storeDirectory: home)
        try XCTAssertNotNil(model.board, "init must create and select a board")
        model.pendingInlineEditID = nil
        return model
    }

    @MainActor
    private func seedNote(_ model: BoardViewModel, x: Double = 100, y: Double = 100) throws -> BoardCore.Note {
        model.addNote(x: x, y: y)
        model.pendingInlineEditID = nil
        let board = try XCTUnwrap(model.board)
        return try XCTUnwrap(board.notes.last)
    }

    @MainActor
    func testPlainTabOnUnlinkedNoteCreatesConnectedNoteToTheRight() throws {
        let model = try freshModel()
        let anchor = try seedNote(model)
        model.addViaTab(from: anchor.id, shift: false)
        let board = try XCTUnwrap(model.board)
        let created = try XCTUnwrap(board.notes.last)
        XCTAssertEqual(created.parentID, nil, "an unlinked anchor must not adopt the new note into a tree")
        XCTAssertEqual(created.x, anchor.x + anchor.width + 70, accuracy: 0.001)
        XCTAssertEqual(created.y, anchor.y, accuracy: 0.001)
        XCTAssertTrue(board.connections.contains { $0.from == anchor.id && $0.to == created.id && $0.effectiveDirection == .oneWay })
        XCTAssertEqual(model.selectedNoteID, created.id)
        XCTAssertEqual(model.pendingInlineEditID, created.id, "the new note must open straight into editing")
    }

    @MainActor
    func testPlainTabOnTreeLinkedNoteCreatesChild() throws {
        let model = try freshModel()
        let anchor = try seedNote(model)
        let existingChild = try seedNote(model, x: 400, y: 100)
        _ = model.mutate { board in
            if let i = board.notes.firstIndex(where: { $0.id == existingChild.id }) { board.notes[i].parentID = anchor.id }
        }
        model.addViaTab(from: anchor.id, shift: false)
        let board = try XCTUnwrap(model.board)
        let created = try XCTUnwrap(board.notes.last)
        XCTAssertEqual(created.parentID, anchor.id)
        XCTAssertEqual(created.x, anchor.x + anchor.width + 60, accuracy: 0.001)
        XCTAssertEqual(created.y, existingChild.y + existingChild.height + 24, accuracy: 0.001, "a new child stacks below the last existing child")
        XCTAssertFalse(board.connections.contains { $0.from == anchor.id && $0.to == created.id }, "tree children link by parentID, not a connection")
    }

    @MainActor
    func testShiftTabCreatesChildEvenFromUnlinkedNote() throws {
        let model = try freshModel()
        let anchor = try seedNote(model)
        model.addViaTab(from: anchor.id, shift: true)
        let board = try XCTUnwrap(model.board)
        let created = try XCTUnwrap(board.notes.last)
        XCTAssertEqual(created.parentID, anchor.id, "shift-Tab starts a tree from any note")
        XCTAssertEqual(created.x, anchor.x + anchor.width + 60, accuracy: 0.001)
        XCTAssertEqual(model.pendingInlineEditID, created.id)
    }
}
