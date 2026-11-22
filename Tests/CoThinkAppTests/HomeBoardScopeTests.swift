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
