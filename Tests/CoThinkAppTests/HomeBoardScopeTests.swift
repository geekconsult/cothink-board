import XCTest
@testable import CoThinkApp
import BoardCore

final class HomeBoardScopeTests: XCTestCase {
    private func board(_ id: String, _ title: String, tags: [String] = [], notes: [Note] = []) -> Board {
        var board = Board(title: title, notes: notes)
        board.id = id
        board.tags = tags
        return board
    }

    private func list(_ id: String, _ title: String, boardIDs: [String]) -> BoardList {
        var list = BoardList(title: title)
        list.id = id
        list.boardIDs = boardIDs
        return list
    }

    func testDeskMembershipIsIndependentOfListsAndEditTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BoardStore(directory: directory)
        let board = try store.create(title: "Planning", actor: "user")
        for title in ["Work", "Research"] {
            var list = try store.createList(title: title)
            list.boardIDs = [board.id]
            _ = try store.replaceList(list, expectedRevision: list.revision)
        }
        try store.setOnDesk(board.id, included: true)
        let reopened = try BoardStore(directory: directory)
        try reopened.markOpened(board.id)
        let snapshot = try reopened.pollSnapshot(currentBoardID: board.id)
        XCTAssertEqual(snapshot.deskIDs, [board.id])
        XCTAssertEqual(snapshot.board?.editedAt, try XCTUnwrap(board.editedAt))
        try reopened.setOnDesk(board.id, included: false)
        XCTAssertEqual(try store.lists().filter { $0.boardIDs.contains(board.id) }.count, 2)
        XCTAssertEqual(try store.get(board.id), board)
        try store.setOnDesk(board.id, included: true)
        try store.deleteBoards([board.id])
        XCTAssertTrue(try store.pollSnapshot(currentBoardID: nil).deskIDs.isEmpty)
    }

    func testPinnedListIsExclusivePersistentAndClearsOnDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BoardStore(directory: directory)
        let first = try store.createList(title: "First")
        let next = try store.createList(title: "Next")
        try store.setPinnedList(first.id)
        try store.setPinnedList(next.id)
        let reopened = try BoardStore(directory: directory)
        XCTAssertEqual(try reopened.pollSnapshot(currentBoardID: nil).pinnedListID, next.id)
        try reopened.deleteList(next.id, expectedRevision: next.revision)
        XCTAssertNil(try store.pollSnapshot(currentBoardID: nil).pinnedListID)
        XCTAssertThrowsError(try store.setPinnedList(next.id))
        try store.setPinnedList(first.id)
        try store.setPinnedList(nil)
        XCTAssertNil(try store.pollSnapshot(currentBoardID: nil).pinnedListID)
    }

    func testUnfiledOmitsMembersEvenIfListedTwice() {
        let boards = [board("a", "Filed"), board("b", "Unfiled", tags: ["ไทย"])]
        let lists = [list("one", "One", boardIDs: ["a"]), list("two", "Two", boardIDs: ["a"])]
        XCTAssertEqual(HomeBoardScope.unfiled.boards(boards, lists: lists, search: "").map(\.id), ["b"])
        XCTAssertEqual(HomeBoardScope.unfiled.boards(boards, lists: lists, search: "ไทย").map(\.id), ["b"])
    }

    func testAllScopeReturnsEveryBoardRegardlessOfLists() {
        let boards = [board("alpha", "Alpha Plan"), board("beta", "Beta Plan"), board("gamma", "Gamma Plan")]
        let lists = [list("first", "First", boardIDs: ["alpha"]), list("second", "Second", boardIDs: ["beta"])]
        let ids = HomeBoardScope.all.boards(boards, lists: lists, search: "").map(\.id)
        XCTAssertEqual(ids, ["alpha", "beta", "gamma"])
    }

    func testListScopeReturnsOnlyListMembersInBoardOrder() {
        let boards = [board("alpha", "Alpha Plan"), board("beta", "Beta Plan"), board("gamma", "Gamma Plan")]
        let lists = [list("work", "Work", boardIDs: ["gamma", "alpha"])]
        let ids = HomeBoardScope.list(id: "work").boards(boards, lists: lists, search: "").map(\.id)
        XCTAssertEqual(ids, ["alpha", "gamma"])
    }

    func testListScopeWithMissingListIDReturnsNoBoards() {
        let boards = [board("alpha", "Alpha Plan"), board("beta", "Beta Plan")]
        let lists = [list("work", "Work", boardIDs: ["alpha"])]
        let ids = HomeBoardScope.list(id: "ghost").boards(boards, lists: lists, search: "").map(\.id)
        XCTAssertEqual(ids, [])
    }

    func testSearchWithinListScopeMatchesTitleTagsAndNotes() {
        let boards = [
            board("alpha", "Alpha Plan"),
            board("beta", "Beta Plan", tags: ["urgent"]),
            board("delta", "Delta Plan", notes: [Note(id: "n", text: "quarterly roadmap")]),
            board("archive", "Roadmap Archive"),
        ]
        let lists = [list("work", "Work", boardIDs: ["alpha", "beta", "delta"])]
        let scope = HomeBoardScope.list(id: "work")
        XCTAssertEqual(scope.boards(boards, lists: lists, search: "alpha").map(\.id), ["alpha"])
        XCTAssertEqual(scope.boards(boards, lists: lists, search: "urgent").map(\.id), ["beta"])
        XCTAssertEqual(scope.boards(boards, lists: lists, search: "quarterly").map(\.id), ["delta"])
        XCTAssertEqual(scope.boards(boards, lists: lists, search: "roadmap archive").map(\.id), [])
    }
}
