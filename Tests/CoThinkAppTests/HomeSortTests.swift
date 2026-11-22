import XCTest
@testable import CoThinkApp
import BoardCore

final class HomeSortTests: XCTestCase {
    private func board(_ id: String, _ title: String) -> Board {
        var board = Board(title: title)
        board.id = id
        return board
    }

    func testRecentSortOrdersByTimestampDescendingWithUnopenedLast() {
        let boards = [board("o1", "One"), board("o2", "Two"), board("u1", "Three"), board("u2", "Four")]
        let now = Date()
        let lastOpened = ["o1": now.addingTimeInterval(-60), "o2": now]
        XCTAssertEqual(HomeSort.recent.sorted(boards, lastOpened: lastOpened).map(\.id), ["o2", "o1", "u1", "u2"])
    }

    func testTitleSortIsCaseInsensitiveWithUntitledFallback() {
        let boards = [board("beta", "beta"), board("alpha", "Alpha"), board("untitled", ""), board("gamma", "gamma")]
        XCTAssertEqual(HomeSort.title.sorted(boards, lastOpened: [:]).map(\.id), ["alpha", "beta", "gamma", "untitled"])
    }

    func testRecentSortWithEmptyLastOpenedKeepsInputOrder() {
        let boards = [board("x", "Xray"), board("y", "Yak"), board("z", "Zebra")]
        XCTAssertEqual(HomeSort.recent.sorted(boards, lastOpened: [:]).map(\.id), ["x", "y", "z"])
    }
}
