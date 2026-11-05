import XCTest
@testable import CoThinkApp

final class JevClassifierTests: XCTestCase {
    func testRequestBodyCarriesJevContract() throws {
        let body = JevClassifier.requestBody(utterance: "move the top note to the left")
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        XCTAssertEqual(body["state"] as? String, "move the top note to the left")
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        let question = try XCTUnwrap(questions["is_board_command"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "noul")
        XCTAssertFalse(try XCTUnwrap(question["instructions"] as? String).isEmpty)
    }

    func testParseNoulReadsBoardCommandAnswer() throws {
        let sample = Data(#"{"answers":{"is_board_command":{"noul":0.9}}}"#.utf8)
        XCTAssertEqual(try JevClassifier.parseNoul(sample), 0.9)
    }

    func testParseNoulThrowsOnMalformedData() {
        XCTAssertThrowsError(try JevClassifier.parseNoul(Data("not json".utf8)))
    }

    func testParseNoulThrowsWhenAnswersPathMissing() {
        XCTAssertThrowsError(try JevClassifier.parseNoul(Data(#"{"status":"ok"}"#.utf8)))
    }

    func testCommandThresholdBoundary() {
        XCTAssertTrue(JevClassifier.isCommand(noul: 0.9))
        XCTAssertFalse(JevClassifier.isCommand(noul: 0.39))
        XCTAssertTrue(JevClassifier.isCommand(noul: 0.4))
    }
}
