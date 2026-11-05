import SwiftUI
import AppKit
import BoardCore
import PiChatCore

/// Floating agent-chat window: hosts PiChatView for the currently selected board.
struct AgentChatWindow: View {
    @ObservedObject var model: BoardViewModel
    let session: AgentChatSession
    var body: some View {
        Group {
            if let board = model.board {
                PiChatView(board: board, session: session).id(board.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No board selected").font(.title3.weight(.semibold))
                    Text("Select a board to talk with Pi about it.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.thinMaterial)
            }
        }
        .frame(minWidth: 360, minHeight: 480)
        .onAppear {
            AuxiliaryWindowHost.shared.setTitle(id: "agent-chat", "Agent chat · \(model.board?.title ?? "")")
        }
        .onChange(of: model.board?.id) { _, _ in
            AuxiliaryWindowHost.shared.setTitle(id: "agent-chat", "Agent chat · \(model.board?.title ?? "")")
        }
    }
}

/// Roomy settings window for agent chat (pi path, model, memory, voice, text size).
struct AgentChatSettingsWindow: View {
    @ObservedObject var model: BoardViewModel
    let session: AgentChatSession
    @ObservedObject private var chat: PiChatController
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @AppStorage("agentChatFontSize") private var chatFontSize = 14.0
    @AppStorage("piModelKey") private var piModelKey = ""
    @AppStorage("jevApiKey") private var jevApiKey = ""
    @AppStorage("voiceFilterEnabled") private var voiceFilterEnabled = true
    @AppStorage("speakRepliesEnabled") private var speakRepliesEnabled = true
    @State private var memoryDraft = ""
    @State private var offerAgentSetup = false
    init(model: BoardViewModel, session: AgentChatSession) {
        self.model = model
        self.session = session
        _chat = ObservedObject(wrappedValue: session.chat)
    }

    private var isFailed: Bool {
        if case .failed = chat.phase { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Agent chat settings").font(.headline)
                    Spacer()
                    Circle().fill(chat.phase == .ready || chat.phase == .running ? Color.green : Color.secondary.opacity(0.55)).frame(width: 7, height: 7)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Pi executable").font(.caption.weight(.semibold))
                    HStack(spacing: 8) {
                        TextField("Path to Pi executable", text: $piExecutablePath)
                            .textFieldStyle(.roundedBorder).font(.caption)
                        Button("Choose…", action: choosePi)
                    }
                    Text("Uses your Pi model and credentials. Chat tools can edit the open board.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Set Up Pi…", action: AgentChatSession.installPi)
                        Button("Check Again") { discoverPi() }
                    }
                    Text("After installation, use /login and /model in Pi, then check again here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ModelMenuSection(
                    models: visibleModels,
                    label: selectedModelLabel,
                    selectionKey: piModelKey,
                    onSelect: handleModelSelection
                )
                MemoryEditorSection(
                    initialText: memoryDraft,
                    onSave: { saveMemory($0) },
                    onClear: { clearMemory() }
                )
                VStack(alignment: .leading, spacing: 7) {
                    Text("Voice").font(.caption.weight(.semibold))
                    Toggle("Filter commands with Jev", isOn: $voiceFilterEnabled)
                    Toggle("Speak Pi replies aloud", isOn: $speakRepliesEnabled)
                    SecureField("Typesafe API key", text: $jevApiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Text("Jev filters unrelated speech. Board ideas, planning, and details are sent to Pi. Leave empty to send everything.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Message text size").font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(Int(chatFontSize)) pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $chatFontSize, in: 12...22, step: 1)
                        .accessibilityLabel("Chat message text size")
                    Text("Preview of chat text").font(.system(size: chatFontSize)).lineLimit(1)
                }
                HStack {
                    if chat.phase == .stopped || isFailed {
                        Button("Connect") { connect() }
                            .disabled(piExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("Disconnect") { session.disconnect() }
                    }
                    Spacer()
                    Button { AuxiliaryWindowHost.shared.open(id: "mcp-servers") } label: { Label("MCP Servers…", systemImage: "point.3.connected.trianglepath.dotted") }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 440, minHeight: 540)
        .navigationTitle("Agent chat settings")
        .onAppear {
            if piExecutablePath.isEmpty { piExecutablePath = AgentChatSession.discoverPiPath() }
            chat.pendingModelKey = piModelKey.isEmpty ? nil : piModelKey
            loadMemory()
            offerAgentSetup = piExecutablePath.isEmpty
        }
        .alert("Set up agent chat?", isPresented: $offerAgentSetup) {
            Button("Set Up Pi") { AgentChatSession.installPi() }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Agent chat uses Pi and a model provider. Setup installs Pi in your user folder and requires Node.js and npm.")
        }
    }

    private var statusText: String {
        switch chat.phase {
        case .stopped: return "Disconnected"
        case .starting: return "Connecting…"
        case .ready: return chat.modelName.isEmpty ? "Connected" : "Connected · \(chat.modelName)"
        case .running: return chat.activityText.isEmpty ? "Working…" : chat.activityText
        case .failed: return "Connection failed"
        }
    }

    private let hiddenModelKeys: Set<String> = ["zai/glm-4.7", "zai/glm-5-turbo"]
    private var visibleModels: [PiModel] { chat.availableModels.filter { !hiddenModelKeys.contains($0.key) } }
    private var selectedModelLabel: String {
        if let model = chat.availableModels.first(where: { $0.key == piModelKey }) { return model.name }
        return chat.modelName.isEmpty ? "Pi default" : chat.modelName
    }
    private func handleModelSelection(_ key: String) {
        piModelKey = key
        chat.selectModel(key: key)
        if key.isEmpty { connect() }
    }
    private func connect() {
        guard let board = model.board else { return }
        session.connect(boardID: board.id, piPath: piExecutablePath)
    }
    private func choosePi() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Pi executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            piExecutablePath = url.path
            connect()
        }
    }
    private func discoverPi() {
        let found = AgentChatSession.discoverPiPath()
        if !found.isEmpty { piExecutablePath = found; connect() }
    }
    private func loadMemory() {
        guard let board = model.board else { return }
        memoryDraft = AgentMemory.load(home: session.home, boardID: board.id)
    }
    private func saveMemory(_ text: String) {
        guard let board = model.board else { return }
        do {
            try AgentMemory.save(text, home: session.home, boardID: board.id)
            memoryDraft = AgentMemory.load(home: session.home, boardID: board.id)
        } catch { model.error = "Could not save memory: \(error.localizedDescription)" }
    }
    private func clearMemory() {
        guard let board = model.board else { return }
        do {
            try AgentMemory.clear(home: session.home, boardID: board.id)
            memoryDraft = AgentMemory.load(home: session.home, boardID: board.id)
        } catch { model.error = "Could not clear memory: \(error.localizedDescription)" }
    }
}

/// Standalone MCP servers manager window.
struct MCPServersWindow: View {
    @ObservedObject var model: BoardViewModel
    let session: AgentChatSession
    @State private var servers: [MCPServerSpec] = []
    @State private var message: String?
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var newArgs = ""
    @State private var newEnv = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MCP servers").font(.headline)
                Spacer()
                Button("Import JSON…") { importJSON() }
                Button("Refresh") { load() }
            }
            Text("Tools from these servers are bridged into Pi chat as mcp_<server>_<tool>. New or changed servers apply from the next chat session.")
                .font(.caption).foregroundStyle(.secondary)
            if servers.isEmpty {
                Text("No external MCP servers yet. Import a Claude Desktop style mcpServers JSON file or add one below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(servers) { server in
                    HStack(spacing: 10) {
                        Circle().fill(server.enabled ? Color.green : Color.gray).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name).font(.callout.weight(.semibold))
                            Text(server.command + (server.args.isEmpty ? "" : " " + server.args.joined(separator: " ")))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            if !server.env.isEmpty {
                                Text("env: " + server.env.keys.sorted().joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text(server.enabled ? "enabled" : "disabled").font(.caption2).foregroundStyle(.secondary)
                        Button(role: .destructive) { remove(server.name) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove \(server.name)")
                    }
                    .padding(.vertical, 3)
                }
            }
            .overlay { if servers.isEmpty { EmptyView() } }
            VStack(alignment: .leading, spacing: 7) {
                Text("Add a server").font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Name", text: $newName).textFieldStyle(.roundedBorder).frame(width: 120)
                    TextField("Command", text: $newCommand).textFieldStyle(.roundedBorder)
                    TextField("Args (space separated)", text: $newArgs).textFieldStyle(.roundedBorder).frame(width: 170)
                }
                HStack(spacing: 8) {
                    TextField("Env KEY=VALUE (space separated)", text: $newEnv).textFieldStyle(.roundedBorder)
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("MCP servers")
        .onAppear { load() }
    }

    private func load() {
        servers = MCPServerStore.load(at: session.mcpConfigURL)
    }
    private func add() {
        let safeName = MCPServerSpec.sanitizeName(newName)
        let args = newArgs.split(separator: " ").map(String.init)
        var env: [String: String] = [:]
        for pair in newEnv.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { env[String(parts[0])] = String(parts[1]) }
        }
        let spec = MCPServerSpec(name: safeName, command: newCommand.trimmingCharacters(in: .whitespaces), args: args, env: env)
        if let index = servers.firstIndex(where: { $0.name == safeName }) { servers[index] = spec } else { servers.append(spec) }
        newName = ""; newCommand = ""; newArgs = ""; newEnv = ""
        persist()
    }
    private func remove(_ name: String) {
        servers.removeAll { $0.name == name }
        persist()
    }
    private func importJSON() {
        let panel = NSOpenPanel()
        panel.title = "Import MCP servers JSON"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let result = MCPServerStore.importJSON(text, into: servers)
        servers = result.servers
        persist()
        message = "Imported \(result.imported) new server\(result.imported == 1 ? "" : "s") from \(url.lastPathComponent)."
    }
    private func persist() {
        do {
            try MCPServerStore.save(servers, to: session.mcpConfigURL)
            message = "Saved. Tools apply from the next chat session."
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// Chat history window: past Pi sessions for the current board.
struct ChatHistoryWindow: View {
    @ObservedObject var model: BoardViewModel
    let session: AgentChatSession
    @ObservedObject private var chat: PiChatController
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @State private var sessions: [ChatSessionSummary] = []

    init(model: BoardViewModel, session: AgentChatSession) {
        self.model = model
        self.session = session
        _chat = ObservedObject(wrappedValue: session.chat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chat history").font(.headline)
                Spacer()
                Button("New chat") { newChat() }
                    .disabled(piExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.board == nil)
            }
            if sessions.isEmpty {
                Text("No past sessions on this board yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(sessions) { summary in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(summary.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout.weight(.semibold))
                                if summary.isCurrent {
                                    Text("current")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                                }
                            }
                            Text(summary.firstUserMessage)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(summary.messageCount) msgs").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Button("Open") { open(summary) }
                            .disabled(summary.isCurrent)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .navigationTitle("Chat history")
        .onAppear { refresh() }
        .onChange(of: chat.currentSessionFile) { _, _ in refresh() }
    }

    private func refresh() {
        guard let board = model.board else { sessions = []; return }
        sessions = ChatSessionSummary.scan(home: session.home, boardID: board.id, currentSessionFile: chat.currentSessionFile)
    }
    private func newChat() {
        guard let board = model.board else { return }
        session.connect(boardID: board.id, piPath: piExecutablePath, sessionMode: .newSession)
        refresh()
    }
    private func open(_ summary: ChatSessionSummary) {
        guard let board = model.board else { return }
        session.connect(boardID: board.id, piPath: piExecutablePath, sessionMode: .resume(path: summary.url.path))
        refresh()
    }
}

struct ModelMenuSection: View {
    let models: [PiModel]
    let label: String
    let selectionKey: String
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Model").font(.caption.weight(.semibold))
            if models.isEmpty {
                Text("Models appear here after connecting.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(get: { selectionKey }, set: { onSelect($0) })) {
                    Text("Pi default (reconnects)").tag("")
                    ForEach(models, id: \.key) { model in
                        Text("\(model.name) · \(model.provider)").tag(model.key)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(label)
            }
        }
    }
}
