import XCTest
@testable import PiChatCore

final class MCPConfigTests: XCTestCase {
    func testSaveLoadRoundtrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        let servers = [
            MCPServerSpec(name: "filesystem", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]),
            MCPServerSpec(name: "slow-server", command: "python3", args: ["-m", "server"], env: ["TOKEN": "x"], enabled: false),
        ]
        try MCPServerStore.save(servers, to: url)
        let loaded = MCPServerStore.load(at: url)
        XCTAssertEqual(loaded, servers)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"mcpServers\""))
        XCTAssertTrue(raw.contains("\"enabled\" : false"))
        try? FileManager.default.removeItem(at: url)
    }

    func testParseAcceptsClaudeShapeAndBareMap() {
        let claude = """
        {"mcpServers": {"File System": {"command": "npx", "args": ["-y", "server"], "env": {"A": "B"}}}}
        """
        let parsed = MCPServerStore.parse(claude)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "file-system")
        XCTAssertEqual(parsed.first?.command, "npx")
        XCTAssertEqual(parsed.first?.env["A"], "B")

        let bare = """
        {"my-server": {"command": "/usr/bin/server", "args": ["--x"]}}
        """
        let bareParsed = MCPServerStore.parse(bare)
        XCTAssertEqual(bareParsed.count, 1)
        XCTAssertEqual(bareParsed.first?.name, "my-server")
    }

    func testParseSkipsURLOnlyAndEmptyCommands() {
        let text = """
        {"url-server": {"url": "https://example.com/mcp"}, "cmd-server": {"command": ""}, "ok": {"command": "bin", "enabled": false}}
        """
        let parsed = MCPServerStore.parse(text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.name, "ok")
        XCTAssertFalse(parsed.first?.enabled ?? true)
    }

    func testSanitizeName() {
        XCTAssertEqual(MCPServerSpec.sanitizeName("File System"), "file-system")
        XCTAssertEqual(MCPServerSpec.sanitizeName("  --My_Server!!  "), "my_server")
        XCTAssertEqual(MCPServerSpec.sanitizeName("!!!"), "server")
        XCTAssertEqual(MCPServerSpec.sanitizeName("ภาษาไทย"), "server")
    }

    func testImportMergesByName() throws {
        let existing = [MCPServerSpec(name: "a", command: "old")]
        let (merged, imported) = MCPServerStore.importJSON("{\"mcpServers\": {\"a\": {\"command\": \"new\"}, \"b\": {\"command\": \"bin\"}}}", into: existing)
        XCTAssertEqual(imported, 1)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first(where: { $0.name == "a" })?.command, "new")
        XCTAssertEqual(merged.first(where: { $0.name == "b" })?.command, "bin")
    }
}
