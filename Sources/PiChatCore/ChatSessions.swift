import Foundation

/// Which recorded Pi session a chat opens.
public enum ChatSessionMode: Equatable {
    case continueLast
    case newSession
    case resume(path: String)
}

public struct ChatSessionSummary: Identifiable, Equatable {
    public let id: String
    public let url: URL
    public let date: Date
    public let firstUserMessage: String
    public let messageCount: Int
    public let isCurrent: Bool

    public init(url: URL, date: Date, firstUserMessage: String, messageCount: Int, isCurrent: Bool) {
        self.id = url.path
        self.url = url
        self.date = date
        self.firstUserMessage = firstUserMessage
        self.messageCount = messageCount
        self.isCurrent = isCurrent
    }
}

public extension ChatSessionSummary {
    /// Pi stores one .jsonl per session in AgentSessions/<encodedBoardID>/.
    static func scan(home: URL, boardID: String, currentSessionFile: String?) -> [ChatSessionSummary] {
        let directory = AgentMemory.sessionDirectoryURL(home: home, boardID: boardID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let summaries = files
            .filter { $0.pathExtension == "jsonl" }
            .map { parseSessionFile(at: $0, modificationDate: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) }
            .compactMap { $0 }
            .sorted { $0.date > $1.date }
        if let currentSessionFile, !currentSessionFile.isEmpty {
            let currentPath = URL(fileURLWithPath: currentSessionFile).resolvingSymlinksInPath().path
            return summaries.map { summary in
                ChatSessionSummary(url: summary.url, date: summary.date, firstUserMessage: summary.firstUserMessage, messageCount: summary.messageCount, isCurrent: summary.url.resolvingSymlinksInPath().path == currentPath)
            }
        }
        return summaries
    }

    static func parseSessionFile(at url: URL, modificationDate: Date?) -> ChatSessionSummary? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var sessionDate = modificationDate ?? Date()
        var firstUserMessage = ""
        var messageCount = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if entry["type"] as? String == "session", let timestamp = entry["timestamp"] as? String {
                if let parsed = Self.sessionDateFormatter.date(from: timestamp) { sessionDate = parsed }
            }
            guard entry["type"] as? String == "message", let message = entry["message"] as? [String: Any] else { continue }
            messageCount += 1
            if firstUserMessage.isEmpty, message["role"] as? String == "user" {
                firstUserMessage = Self.text(fromContent: message["content"], limit: 90)
            }
        }
        guard messageCount > 0 else { return nil }
        return ChatSessionSummary(url: url, date: sessionDate, firstUserMessage: firstUserMessage.isEmpty ? "(no user message)" : firstUserMessage, messageCount: messageCount, isCurrent: false)
    }

    static func text(fromContent content: Any?, limit: Int) -> String {
        if let text = content as? String { return String(text.prefix(limit)) }
        guard let parts = content as? [[String: Any]] else { return "" }
        let text = parts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static let sessionDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct ContextUsage: Equatable {
    public var usedTokens: Int?
    public var contextWindow: Int?
    public var messageCount: Int?
    public var isCompacting: Bool
    public var autoCompactionEnabled: Bool

    public var percent: Double? {
        guard let usedTokens, usedTokens > 0, let contextWindow, contextWindow > 0 else { return nil }
        return Double(usedTokens) / Double(contextWindow)
    }

    public init(usedTokens: Int? = nil, contextWindow: Int? = nil, messageCount: Int? = nil, isCompacting: Bool = false, autoCompactionEnabled: Bool = false) {
        self.usedTokens = usedTokens
        self.contextWindow = contextWindow
        self.messageCount = messageCount
        self.isCompacting = isCompacting
        self.autoCompactionEnabled = autoCompactionEnabled
    }

    /// get_state data: model.contextWindow, messageCount, compaction flags.
    public static func update(fromState data: [String: Any], into usage: ContextUsage) -> ContextUsage {
        var updated = usage
        if let model = data["model"] as? [String: Any] {
            updated.contextWindow = Self.number(model["contextWindow"]).map { Int($0) }
        }
        updated.messageCount = Self.number(data["messageCount"]).map { Int($0) }
        if let compacting = data["isCompacting"] as? Bool { updated.isCompacting = compacting }
        if let auto = data["autoCompactionEnabled"] as? Bool { updated.autoCompactionEnabled = auto }
        return updated
    }

    /// Assistant message with usage: tokens sent as context on that call.
    public static func usageTokens(fromMessage message: [String: Any]) -> Int? {
        guard let usage = message["usage"] as? [String: Any] else { return nil }
        let input = Self.number(usage["input"]) ?? 0
        let cacheRead = Self.number(usage["cacheRead"]) ?? 0
        let cacheWrite = Self.number(usage["cacheWrite"]) ?? 0
        let total = Int(input + cacheRead + cacheWrite)
        return total > 0 ? total : nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

public enum AgentMemory {
    public static func encodedBoardID(_ boardID: String) -> String {
        Data(boardID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sessionDirectoryURL(home: URL, boardID: String) -> URL {
        home.appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent(encodedBoardID(boardID), isDirectory: true)
    }

    public static func memoryURL(home: URL, boardID: String) -> URL {
        sessionDirectoryURL(home: home, boardID: boardID).appendingPathComponent("memory.md")
    }

    public static let emptyTemplate = "# Agent memory\n\nDurable facts, preferences, and decisions Pi should know in every chat session.\n"

    public static func load(home: URL, boardID: String) -> String {
        let url = memoryURL(home: home, boardID: boardID)
        guard FileManager.default.fileExists(atPath: url.path), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    public static func save(_ text: String, home: URL, boardID: String) throws {
        let url = memoryURL(home: home, boardID: boardID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func clear(home: URL, boardID: String) throws {
        try save(emptyTemplate, home: home, boardID: boardID)
    }
}
