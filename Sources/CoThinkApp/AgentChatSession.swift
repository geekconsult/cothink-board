import Foundation
import SwiftUI
import PiChatCore

/// Agent-chat state shared across the floating windows: the chat window, the
/// settings window, and the history window all drive one PiChatController so
/// the conversation survives opening and closing windows.
@MainActor
final class AgentChatSession: ObservableObject {
    let chat = PiChatController()
    let tts = TTSController()
    private var connectedBoardID: String?

    var home: URL {
        if let path = ProcessInfo.processInfo.environment["COTHINK_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CoThinkBoard", isDirectory: true)
    }

    var mcpConfigURL: URL { MCPServerStore.defaultURL(home: home) }

    func ensureConnected(boardID: String, piPath: String) {
        if connectedBoardID == boardID,
           chat.phase == .ready || chat.phase == .running || chat.phase == .starting { return }
        connect(boardID: boardID, piPath: piPath)
    }

    func connect(boardID: String, piPath: String, sessionMode: ChatSessionMode = .continueLast) {
        let trimmedPath = piPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return }
        chat.start(options: PiChatStartOptions(
            boardID: boardID,
            piPath: trimmedPath,
            extensionPath: Self.extensionPath,
            mcpPath: Self.mcpExecutablePath,
            home: home,
            sessionMode: sessionMode,
            memoryPath: AgentMemory.memoryURL(home: home, boardID: boardID).path,
            mcpServersConfigPath: mcpConfigURL.path
        ))
        connectedBoardID = boardID
    }

    func disconnect() {
        chat.stop()
        connectedBoardID = nil
    }

    static let extensionPath: String = Bundle.main.path(forResource: "CoThinkPiExtension", ofType: "ts") ?? ""
    static let mcpExecutablePath: String = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cothink-mcp").path ?? ""

    static func discoverPiPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/share/cothink/pi/bin/cothink-pi").path,
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
            home.appendingPathComponent(".local/bin/pi").path,
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
    }

    static func installPi() {
        guard let url = Bundle.main.url(forResource: "install-pi", withExtension: "command") else { return }
        NSWorkspace.shared.open(url)
    }
}
