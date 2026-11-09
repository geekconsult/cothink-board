import XCTest
import Combine
@testable import CoThinkApp
import BoardCore

final class PollTests: XCTestCase {
    @MainActor
    func testIdlePollsPublishNothing() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cothink-poll-tests-\(UUID().uuidString)", isDirectory: true)
        let model = BoardViewModel(storeDirectory: home)
        try XCTAssertNotNil(model.board, "init must create and select a board")
        var emissions = 0
        let subscription = model.objectWillChange.sink { _ in emissions += 1 }
        for _ in 0..<5 { model.poll() }
        XCTAssertEqual(emissions, 0, "an idle poll must not republish boards, lists, history or the board")
        _ = subscription
    }

    @MainActor
    func testPollPicksUpExternalWrites() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cothink-poll-tests-\(UUID().uuidString)", isDirectory: true)
        let model = BoardViewModel(storeDirectory: home)
        let current = try XCTUnwrap(model.board)
        var emissions = 0
        let subscription = model.objectWillChange.sink { _ in emissions += 1 }
        let other = try BoardStore(directory: home)
        var renamed = try other.get(current.id)
        renamed.title = "Renamed elsewhere"
        _ = try other.replace(renamed, expectedRevision: current.revision, actor: "agent")
        model.poll()
        XCTAssertGreaterThan(emissions, 0, "the poll after an external write must republish")
        XCTAssertEqual(model.board?.title, "Renamed elsewhere")
        XCTAssertEqual(model.boards.first(where: { $0.id == current.id })?.title, "Renamed elsewhere")
        model.poll()
        XCTAssertEqual(model.board?.title, "Renamed elsewhere", "a settled poll keeps the external change")
        _ = subscription
    }
}
