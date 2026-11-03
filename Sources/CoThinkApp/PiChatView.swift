import SwiftUI
import AppKit
import BoardCore
import PiChatCore

struct PiChatView: View {
    let board: Board
    @StateObject private var chat = PiChatController()
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @AppStorage("agentChatFontSize") private var chatFontSize = 14.0
    @State private var input = ""
    @State private var settingsVisible = false
    @FocusState private var inputFocused: Bool

    private var home: URL {
        if let path = ProcessInfo.processInfo.environment["COTHINK_HOME"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CoThinkBoard", isDirectory: true)
    }
    private var extensionPath: String { Bundle.main.path(forResource: "CoThinkPiExtension", ofType: "ts") ?? "" }
    private var mcpPath: String { Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("cothink-mcp").path ?? "" }
    private var status: String {
        switch chat.phase {
        case .stopped: return "Disconnected"
        case .starting: return "Connecting to Pi and board…"
        case .ready: return chat.modelName.isEmpty ? "Connected" : "Connected · \(chat.modelName)"
        case .running: return "Working…"
        case .failed: return "Connection failed"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent chat").font(.headline)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { settingsVisible.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Pi settings")
                    .accessibilityLabel("Pi settings")
                    .popover(isPresented: $settingsVisible, arrowEdge: .top) {
                        settingsPanel.padding(16).frame(width: 340)
                    }
            }.padding(14)
            Divider()
            if case .failed(let error) = chat.phase {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Work on this board with Pi").font(.subheadline.weight(.semibold))
                                Text("Ask Pi to understand, organize, or update your notes. Changes appear on the board automatically.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 10)
                        }
                        ForEach(chat.messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(label(message.role)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                markdownMessage(message.text).font(.system(size: chatFontSize)).textSelection(.enabled)
                                    .foregroundStyle(message.role == .error ? Color.red : Color.primary)
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .id(message.id)
                        }
                    }.padding(12)
                }
                .onChange(of: chat.messages) { _, messages in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            VStack(alignment: .trailing, spacing: 8) {
                TextField("Ask about this board…", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5).focused($inputFocused)
                    .onSubmit(send)
                    .disabled(chat.phase != .ready)
                HStack {
                    if chat.phase == .running { Button("Stop", systemImage: "stop.fill") { chat.cancel() } }
                    Spacer()
                    Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                        .disabled(chat.phase != .ready || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(12)
        }
        .background(.regularMaterial)
        .onAppear {
            if piExecutablePath.isEmpty {
                let candidates = ["/opt/homebrew/bin/pi", "/usr/local/bin/pi", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pi").path]
                piExecutablePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? ""
            }
            if !piExecutablePath.isEmpty { connect() }
            else { settingsVisible = true }
        }
        .onDisappear { chat.stop() }
    }
    private func label(_ role: ChatMessage.Role) -> String {
        switch role { case .user: return "You"; case .assistant: return "Pi"; case .activity: return "Activity"; case .error: return "Error" }
    }
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chat settings").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text("Pi executable").font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    TextField("Path to Pi executable", text: $piExecutablePath)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Choose…", action: choosePi)
                }
                Text("Uses your Pi model and credentials. Chat tools can edit this board.")
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
                    Button("Disconnect") { chat.stop() }
                }
                Spacer()
                Button("Done") { settingsVisible = false }
            }
        }
    }
    private var isFailed: Bool {
        if case .failed = chat.phase { return true }
        return false
    }
    private func markdownMessage(_ text: String) -> Text {
        do {
            return Text(try AttributedString(markdown: text, options: .init(interpretedSyntax: .full)))
        } catch {
            return Text(text)
        }
    }
    private func choosePi() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Pi executable"
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            piExecutablePath = url.path
            connect()
            settingsVisible = false
        }
    }
    private func connect() {
        chat.start(boardID: board.id, piPath: piExecutablePath, extensionPath: extensionPath, mcpPath: mcpPath, home: home)
        if !piExecutablePath.isEmpty { settingsVisible = false }
    }
    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chat.phase == .ready else { return }
        input = ""; chat.send(text)
    }
}
