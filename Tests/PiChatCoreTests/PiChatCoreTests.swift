import XCTest
@testable import PiChatCore

final class PiChatCoreTests: XCTestCase {
    @MainActor
    func testRevisionConflictShowsRecoveryOnlyAfterFreshReadAndSuccessfulEdit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'No refresh'* ]]; then
    printf '%s\n' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":true,"result":{"content":[{"type":"text","text":"Revision conflict. Read the board again before editing."}]}}' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":false}' '{"type":"agent_end"}'
  elif [[ "$line" == *'No retry'* ]]; then
    printf '%s\n' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":true,"result":{"content":[{"type":"text","text":"Revision conflict. Read the board again before editing."}]}}' '{"type":"tool_execution_end","toolName":"cothink_get_board_context","isError":false}' '{"type":"agent_end"}'
  elif [[ "$line" == *'prompt'* ]]; then
    printf '%s\n' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":true,"result":{"content":[{"type":"text","text":"Revision conflict. Read the board again before editing."}]}}' '{"type":"tool_execution_end","toolName":"cothink_get_board","isError":false}' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":false}' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Updated."}}' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "board", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        controller.send("Update the group")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertFalse(controller.messages.contains { $0.role == .error && $0.text.contains("Revision conflict") })
        XCTAssertTrue(controller.messages.contains { $0.role == .activity && $0.text.contains("re-read") && $0.text.contains("later edit succeeded") })
        controller.send("No refresh")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.messages.filter { $0.role == .error && $0.text.contains("Revision conflict") }.count, 1)
        controller.send("No retry")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.messages.filter { $0.role == .error && $0.text.contains("Revision conflict") }.count, 2)
        controller.stop()
    }
    @MainActor
    func testRPCStartupStreamingAndMissingExecutable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), mcp = dir.appendingPathComponent("mcp"), ext = dir.appendingPathComponent("bridge.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"model":{"id":"mock-model"}}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    sleep 0.1
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[{"role":"user","content":"Old question"},{"role":"assistant","content":[{"type":"text","text":"Old answer"}]}]}}'
  elif [[ "$line" == *'prompt'* ]]; then
    printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Hello "}}' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"board"}}'
    printf '{"type":"tool_execution_end","padding":"'; head -c 5000000 /dev/zero | tr '\0' a; printf '"}\n'
    printf '%s\n' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: mcp, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "board-a", piPath: pi.path, extensionPath: ext.path, mcpPath: mcp.path, home: dir))
        XCTAssertEqual(controller.phase, .starting)
        controller.send("Must not be sent before history")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.messages.map(\.text), ["Old question", "Old answer"])
        XCTAssertTrue(controller.bridgeReady)
        XCTAssertEqual(controller.modelName, "mock-model")
        controller.send("Test")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.messages.filter { $0.role == .assistant }.map(\.text), ["Old answer", "Hello board"])
        controller.stop()
        XCTAssertEqual(controller.phase, .stopped)
        controller.start(options: PiChatStartOptions(boardID: "b", piPath: dir.appendingPathComponent("missing").path, extensionPath: ext.path, mcpPath: mcp.path, home: dir))
        if case .failed(let message) = controller.phase { XCTAssertTrue(message.contains("executable")) } else { XCTFail("Expected missing Pi error") }
    }
    @MainActor
    func testBridgeStartupFailureIsShownWithoutWaitingForTimeout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        try "#!/bin/bash\nprintf 'COTHINK_MCP_ERROR: MCP unavailable\\n' >&2\nsleep 10\n".write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "b", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 {
            if case .failed = controller.phase { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .failed(let message) = controller.phase { XCTAssertEqual(message, "MCP unavailable") }
        else { XCTFail("Expected bridge startup error") }
        controller.stop()
    }
    @MainActor
    func testAbortReturnsToReadyAndBoardSwitchStopsOldSession() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'abort'* ]]; then
    printf '%s\n' '{"type":"response","command":"abort","success":true}' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "first", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        controller.start(options: PiChatStartOptions(boardID: "first", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        let second = PiChatController()
        second.start(options: PiChatStartOptions(boardID: "first", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        if case .failed(let error) = second.phase { XCTAssertTrue(error.contains("another window")) }
        else { XCTFail("Expected session lock to prevent a second writer") }
        controller.send("hello")
        XCTAssertEqual(controller.phase, .running)
        controller.cancel()
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        controller.start(options: PiChatStartOptions(boardID: "second", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.messages.isEmpty)
        second.start(options: PiChatStartOptions(boardID: "first", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where second.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(second.phase, .ready)
        second.stop(); controller.stop()
    }
    @MainActor
    func testThinkingAndToolFailureDetailsReachTheChatTranscript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'prompt'* ]]; then
    printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"agent_start"}' '{"type":"message_update","assistantMessageEvent":{"type":"thinking_start"}}' '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"private reasoning must not be displayed"}}'
    sleep 0.3
    printf '%s\n' '{"type":"tool_execution_start","toolName":"cothink_edit_board"}'
    sleep 0.3
    printf '%s\n' '{"type":"tool_execution_end","toolName":"cothink_edit_board","isError":true,"result":{"content":[{"type":"text","text":"Revision conflict. Read the board again before editing."}]}}' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"I could not update the board."}}' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "board-a", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        controller.send("Update this board")
        for _ in 0..<100 where controller.activityText != "Thinking…" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.activityText, "Thinking…")
        for _ in 0..<100 where controller.activityText != "Using cothink_edit_board…" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.activityText, "Using cothink_edit_board…")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.messages.contains { $0.role == .activity && $0.text.localizedCaseInsensitiveContains("thinking") })
        XCTAssertTrue(controller.messages.contains { $0.role == .error && $0.text.contains("Revision conflict. Read the board again before editing.") })
        XCTAssertFalse(controller.messages.contains { $0.text.contains("private reasoning") })
        controller.stop()
    }
    @MainActor
    func testModelListingSelectionAndSwitch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), mcp = dir.appendingPathComponent("mcp"), ext = dir.appendingPathComponent("bridge.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"model":{"id":"mock-a","name":"Mock A"}}}'
  elif [[ "$line" == *'get_available_models'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"local-y","name":"Local Y","provider":"ollama"},{"id":"glm-x","name":"GLM X","provider":"zai"}]}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'set_model'* ]]; then
    provider=$(printf '%s' "$line" | sed -E 's/.*"provider":"([^"]+)".*/\1/')
    model_id=$(printf '%s' "$line" | sed -E 's/.*"modelId":"([^"]+)".*/\1/')
    printf '%s\n' '{"type":"response","command":"set_model","success":true,"data":{"id":"'$model_id'","name":"Swapped '$model_id'","provider":"'$provider'"}}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: mcp, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "model-board", piPath: pi.path, extensionPath: ext.path, mcpPath: mcp.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready || controller.availableModels.count != 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.availableModels.map(\.key), ["ollama/local-y", "zai/glm-x"])
        XCTAssertEqual(controller.availableModels.map(\.name), ["Local Y", "GLM X"])
        XCTAssertEqual(controller.modelName, "Mock A")
        controller.selectModel(key: "zai/glm-x")
        for _ in 0..<100 where controller.modelName != "Swapped glm-x" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.modelName, "Swapped glm-x")
        XCTAssertEqual(controller.messages.map(\.text), ["Switched to Swapped glm-x."])
        controller.selectModel(key: "no-slash")
        XCTAssertEqual(controller.messages.map(\.text), ["Switched to Swapped glm-x.", "Invalid model choice."])
        XCTAssertEqual(controller.modelName, "Swapped glm-x")
        XCTAssertEqual(controller.phase, .ready)
        controller.selectModel(key: "")
        XCTAssertNil(controller.pendingModelKey)
        controller.pendingModelKey = "ollama/local-y"
        controller.start(options: PiChatStartOptions(boardID: "model-board", piPath: pi.path, extensionPath: ext.path, mcpPath: mcp.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready || controller.modelName != "Swapped local-y" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.modelName, "Swapped local-y")
        XCTAssertEqual(controller.availableModels.map(\.key), ["ollama/local-y", "zai/glm-x"])
        XCTAssertEqual(controller.messages.map(\.text), ["Switched to Swapped local-y."])
        controller.stop()
    }

    @MainActor
    func testThinkingToggleSendsFastestLevelAndRestoresRememberedLevel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let log = dir.appendingPathComponent("stdin.log")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  printf '%s\n' "$line" >> '\#(log.path)'
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"thinkingLevel":"high","model":{"id":"glm-x","name":"GLM X","provider":"zai"}}}'
  elif [[ "$line" == *'get_available_models'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"glm-x","name":"GLM X","provider":"zai","reasoning":true}]}}'
  elif [[ "$line" == *'get_available_thinking_levels'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_available_thinking_levels","success":true,"data":{"levels":["low","medium","high","max"]}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'set_thinking_level'* ]]; then
    level=$(printf '%s' "$line" | sed -E 's/.*"level":"([^"]+)".*/\1/')
    if [[ "$level" == "high" ]]; then settled="medium"; else settled="$level"; fi
    printf '%s\n' '{"type":"response","command":"set_thinking_level","success":true}' '{"type":"thinking_level_changed","level":"'$settled'"}'
  elif [[ "$line" == *'cannot-disable'* ]]; then
    printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"message_update","assistantMessageEvent":{"type":"error","reason":"400 This model always engages in thinking and cannot be disabled; please use low, high, or max"}}' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        func setLines() throws -> [String] {
            try String(contentsOf: log, encoding: .utf8).components(separatedBy: .newlines).filter { $0.contains("set_thinking_level") }
        }
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "thinking-board", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready || controller.thinkingLevel != "high" || controller.thinkingLevels != ["low", "medium", "high", "max"] { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.thinkingLevel, "high")
        XCTAssertTrue(controller.supportsThinking)
        controller.setThinking(enabled: false)
        for _ in 0..<100 where (try setLines()).count < 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.thinkingLevel, "low")
        XCTAssertEqual(try setLines().last?.contains(#""level":"low""#), true)
        controller.setThinking(enabled: true)
        for _ in 0..<100 where (try setLines()).count < 2 || controller.thinkingLevel != "medium" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.thinkingLevel, "medium")
        XCTAssertEqual(try setLines().last?.contains(#""level":"high""#), true)
        controller.setThinking(enabled: false)
        for _ in 0..<100 where (try setLines()).count < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.thinkingLevel, "low")
        controller.setThinking(enabled: true)
        for _ in 0..<100 where (try setLines()).count < 4 || controller.thinkingLevel != "medium" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.thinkingLevel, "medium")
        var sentLevels = try setLines()
        XCTAssertEqual(sentLevels.count, 4)
        XCTAssertEqual(sentLevels.last?.contains(#""level":"medium""#), true)
        controller.send("cannot-disable")
        for _ in 0..<100 where (try setLines()).count < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.thinkingLevel, "low")
        XCTAssertTrue(controller.messages.contains { $0.role == .activity && $0.text.contains("always thinks") && $0.text.contains("low") })
        sentLevels = try setLines()
        XCTAssertEqual(sentLevels.count, 5)
        XCTAssertEqual(sentLevels.last?.contains(#""level":"low""#), true)
        controller.stop()
    }
    @MainActor
    func testThinkingUnavailableForNonReasoningModel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let log = dir.appendingPathComponent("stdin.log")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  printf '%s\n' "$line" >> '\#(log.path)'
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"thinkingLevel":"off","model":{"id":"plain","name":"Plain","provider":"local"}}}'
  elif [[ "$line" == *'get_available_models'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"plain","name":"Plain","provider":"local","reasoning":false}]}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "plain-board", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready || controller.availableModels.count != 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.thinkingLevel, "off")
        XCTAssertFalse(controller.supportsThinking)
        controller.setThinking(enabled: true)
        XCTAssertEqual(controller.thinkingLevel, "off")
        try await Task.sleep(nanoseconds: 100_000_000)
        let sent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(sent.contains("set_thinking_level"))
        controller.stop()
    }
    @MainActor
    func testActivityLabelSaysWorkingWhenThinkingOff() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = dir.appendingPathComponent("pi"), ext = dir.appendingPathComponent("extension.ts")
        let script = #"""
#!/bin/bash
printf 'COTHINK_MCP_READY\n' >&2
while IFS= read -r line; do
  if [[ "$line" == *'get_state'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_state","success":true,"data":{"thinkingLevel":"off","model":{"id":"glm-x","name":"GLM X","provider":"zai"}}}'
  elif [[ "$line" == *'get_available_models'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_available_models","success":true,"data":{"models":[{"id":"glm-x","name":"GLM X","provider":"zai","reasoning":true}]}}'
  elif [[ "$line" == *'get_messages'* ]]; then
    printf '%s\n' '{"type":"response","command":"get_messages","success":true,"data":{"messages":[]}}'
  elif [[ "$line" == *'prompt'* ]]; then
    printf '%s\n' '{"type":"response","command":"prompt","success":true}' '{"type":"agent_start"}' '{"type":"message_update","assistantMessageEvent":{"type":"thinking_start"}}' '{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"hidden"}}'
    sleep 0.3
    printf '%s\n' '{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"Done."}}' '{"type":"agent_end"}'
  fi
done
"""#
        try script.write(to: pi, atomically: true, encoding: .utf8)
        try "".write(to: ext, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
        let controller = PiChatController()
        controller.start(options: PiChatStartOptions(boardID: "label-board", piPath: pi.path, extensionPath: ext.path, mcpPath: pi.path, home: dir))
        for _ in 0..<100 where controller.phase != .ready || controller.thinkingLevel != "off" || !controller.supportsThinking { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.supportsThinking)
        controller.send("Hello")
        for _ in 0..<100 where controller.activityText != "Working…" { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.activityText, "Working…")
        for _ in 0..<100 where controller.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.messages.contains { $0.role == .activity && $0.text == "Working…" })
        XCTAssertFalse(controller.messages.contains { $0.text == "Thinking…" })
        controller.stop()
    }

    func testBoardSkillPromptCoversRoundToolMapAndRules() {
        let prompt = CoThinkBoardSkill.systemPrompt
        XCTAssertTrue(prompt.contains("The round"), "The prompt must teach the read → plan → edit → verify round.")
        XCTAssertTrue(prompt.contains("one edit call"))
        XCTAssertTrue(prompt.contains("capture_board"), "The prompt must route layout verification through capture_board.")
        XCTAssertTrue(prompt.contains("export_board_pdf"))
        XCTAssertTrue(prompt.contains("Never guess an id"))
        XCTAssertTrue(prompt.contains("Revision scopes"))
        XCTAssertTrue(prompt.contains("lineFlipped"), "The prompt must teach the line diagonal-direction field.")
        XCTAssertTrue(prompt.contains("rectangle | ellipse | diamond | line | text"), "The prompt must list the shape enum.")
        XCTAssertTrue(prompt.contains("shapes are notes"), "The prompt must teach that shapes are notes with a shape field, not a separate entity.")
        XCTAssertFalse(prompt.contains("cloud"), "The in-app Pi only has the local server; the prompt must not teach cloud tools.")
    }

}
