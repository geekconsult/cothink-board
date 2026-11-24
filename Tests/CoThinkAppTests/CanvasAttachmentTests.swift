import XCTest
import BoardCore
@testable import CoThinkApp

final class CanvasAttachmentTests: XCTestCase {
    @MainActor
    func testDropCopiesFilesLinksCardsAndRollsBackPartialBatch() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let model = BoardViewModel(storeDirectory: temp)
        let board = try XCTUnwrap(model.board)
        let source = temp.appendingPathComponent("แผนงาน.txt")
        let bytes = Data("test".utf8)
        try bytes.write(to: source)
        let point = CGPoint(x: 150, y: 300)
        XCTAssertTrue(model.importFiles([source, source], boardID: board.id, at: point))
        let saved = try BoardStore(directory: temp).get(board.id)
        let folder = URL(fileURLWithPath: try XCTUnwrap(saved.projectFilesPath))
        XCTAssertEqual(saved.notes.suffix(2).map(\.assetIDs), saved.projectAssets.map { [$0.id] })
        XCTAssertEqual(saved.notes.suffix(2).map(\.x), [150, 386])
        XCTAssertEqual(saved.notes.last?.y, 300)
        XCTAssertEqual(Set(saved.projectAssets.map(\.relativePath)).count, 2)
        for asset in saved.projectAssets {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(asset.relativePath)), bytes)
        }
        XCTAssertFalse(model.importFiles([source, temp], boardID: board.id, at: point))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        XCTAssertEqual(try BoardStore(directory: temp).get(board.id), saved)
    }
}
