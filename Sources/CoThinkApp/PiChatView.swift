import SwiftUI
import AppKit
import BoardCore
import PiChatCore

private enum ChatMarkdownBlock {
    case text(String)
    case table(headers: [String], rows: [[String]])
}

struct PiChatView: View {
    let board: Board
    @StateObject private var chat = PiChatController()
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @AppStorage("agentChatFontSize") private var chatFontSize = 14.0
    @State private var input = ""
    @State private var settingsVisible = false
    @State private var offerAgentSetup = false
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
        case .running: return chat.activityText.isEmpty ? "Working…" : chat.activityText
        case .failed: return "Connection failed"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                MascotLogo().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent chat").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(chat.phase == .ready || chat.phase == .running ? Color.green : Color.secondary.opacity(0.55)).frame(width: 6, height: 6)
                        Text(status).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { settingsVisible.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).modifier(GlassControl()).help("Pi settings")
                    .accessibilityLabel("Pi settings")
                    .popover(isPresented: $settingsVisible, arrowEdge: .top) {
                        settingsPanel.padding(16).frame(width: 340)
                    }
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .background(.thinMaterial)
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
                            HStack(alignment: .bottom, spacing: 0) {
                                if message.role == .user { Spacer(minLength: 30) }
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(label(message.role)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                    markdownMessage(message.text).font(.system(size: chatFontSize)).textSelection(.enabled)
                                        .foregroundStyle(message.role == .error ? Color.red : Color.primary)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 10)
                                .frame(maxWidth: 540, alignment: .leading)
                                .background(message.role == .user ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.primary.opacity(0.055)))
                                if message.role != .user { Spacer(minLength: 20) }
                            }
                            .id(message.id)
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 16)
                }
                .onChange(of: chat.messages) { _, messages in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            VStack(alignment: .trailing, spacing: 8) {
                HStack {
                    TextField("Ask about this board…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...5).focused($inputFocused)
                        .onSubmit(send)
                        .disabled(chat.phase != .ready)
                    if chat.phase == .running { Button("Stop", systemImage: "stop.fill") { chat.cancel() } }
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).accessibilityLabel("Send")
                        .disabled(chat.phase != .ready || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .modifier(GlassFloatingSurface())
            }.padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(.thinMaterial)
        .onAppear {
            if piExecutablePath.isEmpty {
                discoverPi()
            }
            if !piExecutablePath.isEmpty { connect() }
            else { settingsVisible = true; offerAgentSetup = true }
        }
        .onDisappear { chat.stop() }
        .alert("Set up agent chat?", isPresented: $offerAgentSetup) {
            Button("Set Up Pi") { installPi() }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Agent chat uses Pi and a model provider. Setup installs Pi in your user folder and requires Node.js and npm.")
        }
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
                HStack {
                    Button("Set Up Pi…", action: installPi)
                    Button("Check Again") { discoverPi() }
                }
                Text("After installation, use /login and /model in Pi, then check again here.")
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
    @ViewBuilder
    private func markdownMessage(_ text: String) -> some View {
        let blocks = chatMarkdownBlocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { entry in
                switch entry.element {
                case .text(let value):
                    markdownText(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .table(let headers, let rows):
                    chatMarkdownTable(headers: headers, rows: rows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func markdownText(_ text: String) -> Text {
        do {
            return Text(try AttributedString(markdown: text, options: .init(interpretedSyntax: .full)))
        } catch {
            return Text(text)
        }
    }
    private func chatMarkdownTable(headers: [String], rows: [[String]]) -> some View {
        let columnCount = max(1, headers.count)
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, columnCount: columnCount, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                    tableRow(entry.element, columnCount: columnCount, isHeader: false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
        .scrollIndicators(.visible)
    }
    private func tableRow(_ values: [String], columnCount: Int, isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { index in
                markdownText(index < values.count ? values[index] : "")
                    .font(isHeader ? .system(size: chatFontSize, weight: .semibold) : .system(size: chatFontSize))
                    .frame(minWidth: 112, maxWidth: 220, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(isHeader ? Color.primary.opacity(0.08) : Color.clear)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.09)).frame(width: 1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
    }
    private func chatMarkdownBlocks(_ source: String) -> [ChatMarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [ChatMarkdownBlock] = []
        var prose: [String] = []
        var index = 0
        var inCodeFence = false
        func flushProse() {
            if !prose.isEmpty { blocks.append(.text(prose.joined(separator: "\n"))); prose.removeAll() }
        }
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCodeFence.toggle(); prose.append(lines[index]); index += 1; continue }
            if !inCodeFence, index + 1 < lines.count,
               let header = markdownTableCells(lines[index]),
               let delimiter = markdownTableCells(lines[index + 1]),
               !header.isEmpty, delimiter.count == header.count,
               delimiter.allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                flushProse()
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = markdownTableCells(lines[index]) {
                    rows.append(row); index += 1
                }
                blocks.append(.table(headers: header, rows: rows))
                continue
            }
            prose.append(lines[index]); index += 1
        }
        flushProse()
        return blocks.isEmpty ? [.text(source)] : blocks
    }
    private func markdownTableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in line {
            if escaped { cell.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.count > 1 ? cells : nil
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
    private func discoverPi() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/share/cothink/pi/bin/cothink-pi").path, "/opt/homebrew/bin/pi", "/usr/local/bin/pi", home.appendingPathComponent(".local/bin/pi").path]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { piExecutablePath = found }
    }
    private func installPi() {
        guard let url = Bundle.main.url(forResource: "install-pi", withExtension: "command") else { return }
        NSWorkspace.shared.open(url)
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
