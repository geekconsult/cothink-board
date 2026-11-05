import XCTest
@testable import PiChatCore

final class ChatSessionsTests: XCTestCase {
    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cothink-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEncodedBoardIDIsBase64URLWithoutPadding() {
        let expected = Data("Chat1".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(AgentMemory.encodedBoardID("Chat1"), expected)
        XCTAssertFalse(AgentMemory.encodedBoardID("Chat1").contains("="))
    }

    func testMemorySaveLoadClearRoundtrip() throws {
        let home = makeTempHome()
        XCTAssertEqual(AgentMemory.load(home: home, boardID: "b1"), "")
        try AgentMemory.save("Alpha fact\nBeta fact", home: home, boardID: "b1")
        XCTAssertEqual(AgentMemory.load(home: home, boardID: "b1"), "Alpha fact\nBeta fact")
        try AgentMemory.clear(home: home, boardID: "b1")
        XCTAssertEqual(AgentMemory.load(home: home, boardID: "b1"), AgentMemory.emptyTemplate)
    }

    func testSessionScanParsesAndSorts() throws {
        let home = makeTempHome()
        let dir = AgentMemory.sessionDirectoryURL(home: home, boardID: "board-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let older = dir.appendingPathComponent("2026-01-01T00-00-00-000Z_old.jsonl")
        let newer = dir.appendingPathComponent("2026-02-02T03-04-05-000Z_new.jsonl")
        let olderJSON = """
        {"type": "session", "version": 3, "id": "old", "timestamp": "2026-01-01T00:00:00.000Z", "cwd": "/tmp"}
        {"type": "message", "id": "m1", "message": {"role": "user", "content": [{"type": "text", "text": "แรกสุด คำถามไทย"}]}}
        {"type": "message", "id": "m2", "message": {"role": "assistant", "content": [{"type": "text", "text": "คำตอบ"}]}}
        """
        let newerJSON = """
        {"type": "session", "id": "new", "timestamp": "2026-02-02T03:04:05.000Z"}
        {"type": "message", "id": "n1", "message": {"role": "user", "content": "plain string content"}}
        {"type": "message", "id": "n2", "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}
        {"type": "message", "id": "n3", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "hm"}]}}
        """
        try olderJSON.write(to: older, atomically: true, encoding: .utf8)
        try newerJSON.write(to: newer, atomically: true, encoding: .utf8)
        let sessions = ChatSessionSummary.scan(home: home, boardID: "board-x", currentSessionFile: newer.path)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first?.url.lastPathComponent, "2026-02-02T03-04-05-000Z_new.jsonl")
        XCTAssertTrue(sessions.first?.isCurrent ?? false)
        XCTAssertFalse(sessions.last?.isCurrent ?? true)
        XCTAssertEqual(sessions.first?.firstUserMessage, "plain string content")
        XCTAssertEqual(sessions.first?.messageCount, 3)
        XCTAssertEqual(sessions.last?.firstUserMessage, "แรกสุด คำถามไทย")
        XCTAssertEqual(sessions.last?.messageCount, 2)
    }

    func testSessionScanSkipsEmptyAndMissingDirs() throws {
        let home = makeTempHome()
        XCTAssertEqual(ChatSessionSummary.scan(home: home, boardID: "no-such-board", currentSessionFile: nil), [])
        let dir = AgentMemory.sessionDirectoryURL(home: home, boardID: "empty-board")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "just noise".write(to: dir.appendingPathComponent("x.jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ChatSessionSummary.scan(home: home, boardID: "empty-board", currentSessionFile: nil), [])
    }

    func testContextUsageFromProbeState() {
        let state: [String: Any] = [
            "model": ["contextWindow": 204800],
            "messageCount": 7,
            "isCompacting": false,
            "autoCompactionEnabled": true,
        ]
        let usage = ContextUsage.update(fromState: state, into: ContextUsage())
        XCTAssertEqual(usage.contextWindow, 204800)
        XCTAssertEqual(usage.messageCount, 7)
        XCTAssertTrue(usage.autoCompactionEnabled)
        XCTAssertNil(usage.percent)
    }

    func testUsageTokensAndPercent() {
        let message: [String: Any] = ["usage": ["input": 2363, "output": 311, "cacheRead": 0, "cacheWrite": 0]]
        XCTAssertEqual(ContextUsage.usageTokens(fromMessage: message), 2363)
        var usage = ContextUsage(usedTokens: 2363, contextWindow: 204800)
        XCTAssertEqual(usage.percent ?? 0, 2363.0 / 204800.0, accuracy: 0.0001)
        usage.usedTokens = 0
        XCTAssertNil(usage.percent)
    }

    func testIsThaiDetection() {
        XCTAssertTrue(TextScript.isThai("สวัสดีครับ"))
        XCTAssertTrue(TextScript.isThai("mixed hello ไทย"))
        XCTAssertFalse(TextScript.isThai("plain english only"))
        XCTAssertFalse(TextScript.isThai(""))
    }
}
