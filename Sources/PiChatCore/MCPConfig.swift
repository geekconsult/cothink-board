import Foundation

public struct MCPServerSpec: Identifiable, Equatable {
    public let name: String
    public let command: String
    public let args: [String]
    public let env: [String: String]
    public let enabled: Bool

    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    public var id: String { name }
}

extension MCPServerSpec {
    /// Tool-name safe server label: lowercase, [a-z0-9_-] only, no leading/trailing dashes.
    public static func sanitizeName(_ raw: String) -> String {
        var cleaned = ""
        for scalar in raw.trimmingCharacters(in: .whitespaces).lowercased().unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 45 || v == 95 {
                cleaned.append(Character(scalar))
            } else {
                cleaned.append("-")
            }
        }
        var collapsed = ""
        for character in cleaned {
            if character == "-" && collapsed.last == "-" { continue }
            collapsed.append(character)
        }
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return trimmed.isEmpty ? "server" : String(trimmed.prefix(28))
    }
}

/// Stores external MCP servers as {"mcpServers": {"<name>": {command, args, env, enabled}}}.
/// This is the Claude Desktop config shape, so imported config files work as-is.
public enum MCPServerStore {
    public static func defaultURL(home: URL) -> URL {
        home.appendingPathComponent("MCP", isDirectory: true).appendingPathComponent("mcp-servers.json")
    }

    public static func load(at url: URL) -> [MCPServerSpec] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    public static func save(_ servers: [MCPServerSpec], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var map: [String: Any] = [:]
        for server in servers {
            var spec: [String: Any] = ["command": server.command]
            if !server.args.isEmpty { spec["args"] = server.args }
            if !server.env.isEmpty { spec["env"] = server.env }
            if !server.enabled { spec["enabled"] = false }
            map[server.name] = spec
        }
        let root = ["mcpServers": map]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

public extension MCPServerStore {
    /// Accepts {"mcpServers": {...}}, {"mcp_servers": {...}}, or a bare name-to-spec map.
    /// URL/SSE server entries have no stdio command and are skipped.
    static func parse(_ text: String) -> [MCPServerSpec] {
        guard let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var section: [String: Any]?
        for key in ["mcpServers", "mcp_servers", "servers"] {
            if let value = root[key] as? [String: Any] { section = value; break }
        }
        let source = section ?? root
        var servers: [MCPServerSpec] = []
        var seenNames = Set<String>()
        for (rawName, rawSpec) in source.sorted(by: { $0.key < $1.key }) {
            guard let spec = rawSpec as? [String: Any] else { continue }
            guard let command = spec["command"] as? String, !command.isEmpty else { continue }
            let name = MCPServerSpec.sanitizeName(rawName)
            guard !seenNames.contains(name), name != "server" else { continue }
            seenNames.insert(name)
            let args = (spec["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            var env: [String: String] = [:]
            if let envDict = spec["env"] as? [String: Any] {
                for (key, value) in envDict { if let value = value as? String { env[key] = value } }
            }
            let enabled = spec["enabled"] as? Bool ?? true
            servers.append(MCPServerSpec(name: name, command: command, args: args, env: env, enabled: enabled))
        }
        return servers
    }

    static func importJSON(_ text: String, into existing: [MCPServerSpec]) -> (servers: [MCPServerSpec], imported: Int) {
        let importedServers = parse(text)
        var merged = existing
        var count = 0
        for imported in importedServers {
            if let index = merged.firstIndex(where: { $0.name == imported.name }) {
                merged[index] = imported
            } else {
                merged.append(imported)
                count += 1
            }
        }
        return (merged, count)
    }
}
