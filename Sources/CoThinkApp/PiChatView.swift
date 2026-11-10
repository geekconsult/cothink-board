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
    let session: AgentChatSession
    @ObservedObject private var chat: PiChatController
    @ObservedObject private var tts: TTSController
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @AppStorage("agentChatFontSize") private var chatFontSize = 14.0
    @AppStorage("dictationLocaleIdentifier") private var dictationLocale = ""
    @AppStorage("piModelKey") private var piModelKey = ""
    @AppStorage("jevApiKey") private var jevApiKey = ""
    @State private var input = ""
    @State private var offerAgentSetup = false
    @StateObject private var dictation = DictationController()
    @State private var dictationBase: String?
    @State private var voiceHint: String?
    @State private var voiceHintTask: Task<Void, Never>?
    @State private var pendingVoiceCommand: String?
    @State private var lastVoiceUtterance = ""
    @FocusState private var inputFocused: Bool
    @State private var voiceMode = false
    @AppStorage("voiceFilterEnabled") private var voiceFilterEnabled = true
    @AppStorage("speakRepliesEnabled") private var speakRepliesEnabled = true

    init(board: Board, session: AgentChatSession) {
        self.board = board
        self.session = session
        _chat = ObservedObject(wrappedValue: session.chat)
        _tts = ObservedObject(wrappedValue: session.tts)
    }

    private var unavailableVoiceMessage: String? {
        if case let .unavailable(message) = dictation.phase { return message }
        return nil
    }
    private var dictationActive: Bool { dictation.phase == .listening || dictation.phase == .reconnecting || dictation.phase == .requestingAuthorization }
    private var lastAssistantReply: String {
        chat.messages.last(where: { $0.role == .assistant })?.text ?? ""
    }
    private var conversationEstimate: Int {
        let characters = chat.messages
            .filter { $0.role == .user || $0.role == .assistant }
            .map { $0.text.count }
            .reduce(0, +)
        return characters / 4
    }
    private var status: String {
        switch chat.phase {
        case .stopped: return "Disconnected"
        case .starting: return "Connecting to Pi and board…"
        case .ready: return chat.modelName.isEmpty ? "Connected" : "Connected · \(chat.modelName)"
        case .running: return chat.activityText.isEmpty ? "Working…" : chat.activityText
        case .failed: return "Connection failed"
        }
    }
    private var thinkingEnabled: Bool { chat.thinkingEnabled }
    private var thinkingToggleDisabled: Bool { !chat.canToggleThinking }
    private var thinkingHelp: String {
        thinkingEnabled
            ? "Thinking: \(chat.thinkingLevel) — click for fast replies (\(chat.fastThinkingLevel))"
            : "Fast replies (\(chat.thinkingLevel)) — click to restore (\(chat.rememberedThinkingLevel))"
    }
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
            HStack(alignment: .center) {
                MascotLogo().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent · \(board.title)").font(.headline).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 5) {
                        Circle().fill(chat.phase == .ready || chat.phase == .running ? Color.green : Color.secondary.opacity(0.55)).frame(width: 6, height: 6)
                        Text(status).lineLimit(1)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ContextUsageBadge(usage: chat.contextUsage, conversationEstimate: conversationEstimate)
                Button {
                    chat.setThinking(enabled: !thinkingEnabled)
                } label: { Image(systemName: "brain").foregroundStyle(thinkingEnabled ? Color.accentColor : Color.secondary) }
                    .buttonStyle(.borderless).modifier(GlassControl()).help(thinkingHelp)
                    .accessibilityLabel(thinkingHelp)
                    .disabled(thinkingToggleDisabled)
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { toggleVoiceMode() }
                } label: { Image(systemName: "waveform") }
                    .buttonStyle(.borderless).modifier(GlassControl()).help("Voice mode")
                    .accessibilityLabel("Voice mode")
                Button { AuxiliaryWindowHost.shared.open(id: "agent-settings") } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).modifier(GlassControl()).help("Agent chat settings")
                    .accessibilityLabel("Agent chat settings")
                Button { AuxiliaryWindowHost.shared.open(id: "chat-history") } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.borderless).modifier(GlassControl()).help("Chat history")
                    .accessibilityLabel("Chat history")
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
                                    HStack(spacing: 6) {
                                        Text(label(message.role)).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        Text(message.timestamp, format: chatTimestampFormat(message.timestamp))
                                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                    }
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
                    Button(action: dictation.toggle) {
                        Image(systemName: dictationActive ? "mic.fill" : "mic")
                            .font(.title2)
                            .foregroundStyle(dictationActive ? Color.red : Color.accentColor)
                            .symbolEffect(.pulse, options: .repeating, isActive: dictation.phase == .listening)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dictationActive ? "Stop dictation" : "Dictate")
                    .help(dictationActive ? "Stop dictation" : "Dictate")
                    Menu {
                        Picker("Dictation language", selection: $dictationLocale) {
                            Text("Automatic").tag("")
                            Text("ไทย").tag("th-TH")
                            Text("English (US)").tag("en-US")
                        }
                    } label: {
                        Image(systemName: "globe")
                            .font(.body)
                            .foregroundStyle(Color.accentColor)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Dictation language")
                    .accessibilityLabel("Dictation language")
                    if chat.phase == .running { Button("Stop", systemImage: "stop.fill") { chat.cancel() } }
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.plain).accessibilityLabel("Send")
                        .disabled(chat.phase != .ready || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
                .modifier(GlassFloatingSurface())
                if case .unavailable(let message) = dictation.phase {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
                if let voiceHint {
                    Text(voiceHint).font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            }
            if voiceMode {
                VoiceModeView(
                    listening: dictation.phase == .listening,
                    reconnecting: dictation.phase == .reconnecting,
                    chatPhase: chat.phase,
                    combinedText: dictation.combinedText,
                    lastUtterance: lastVoiceUtterance,
                    assistantReply: lastAssistantReply,
                    hint: voiceHint ?? "",
                    speaking: tts.isSpeaking,
                    unavailableMessage: unavailableVoiceMessage,
                    jevFilterEnabled: $voiceFilterEnabled,
                    speakRepliesEnabled: $speakRepliesEnabled,
                    onClose: { withAnimation(.easeInOut(duration: 0.3)) { voiceMode = false; dictation.stop() } },
                    onMicToggle: { dictation.toggle() }
                )
                .zIndex(2)
            }
        }
        .background(.thinMaterial)
        .onAppear {
            dictation.preferredLocaleIdentifier = dictationLocale.isEmpty ? nil : dictationLocale
            dictation.onUtterance = { handleVoiceUtterance($0) }
            chat.pendingModelKey = piModelKey.isEmpty ? nil : piModelKey
            chat.onAssistantReply = { [weak tts = session.tts] text in
                guard let tts else { return }
                if speakRepliesEnabled { tts.speak(text) }
            }
            if piExecutablePath.isEmpty {
                piExecutablePath = AgentChatSession.discoverPiPath()
            }
            if !piExecutablePath.isEmpty {
                session.ensureConnected(boardID: board.id, piPath: piExecutablePath)
            } else {
                offerAgentSetup = true
            }
        }
        .onDisappear { dictation.stop(); tts.stop() }
        .onChange(of: dictation.phase) { oldPhase, newPhase in
            if newPhase == .listening, oldPhase != .reconnecting { dictationBase = input }
            if (oldPhase == .listening || oldPhase == .reconnecting), newPhase == .idle, let base = dictationBase {
                input = dictation.mergedInput(base: base, combined: dictation.combinedText)
                dictationBase = nil
            }
        }
        .onChange(of: dictation.combinedText) { _, combined in
            guard dictation.phase == .listening, let base = dictationBase else { return }
            input = dictation.mergedInput(base: base, combined: combined)
        }
        .onChange(of: dictationLocale) { _, locale in
            dictation.preferredLocaleIdentifier = locale.isEmpty ? nil : locale
            dictation.stop()
        }
        .onChange(of: chat.phase) { _, newPhase in
            guard newPhase == .ready, let pending = pendingVoiceCommand else { return }
            pendingVoiceCommand = nil
            chat.send(pending)
        }
        .alert("Set up agent chat?", isPresented: $offerAgentSetup) {
            Button("Set Up Pi") { AgentChatSession.installPi() }
            Button("Later", role: .cancel) { }
        } message: {
            Text("Agent chat uses Pi and a model provider. Setup installs Pi in your user folder and requires Node.js and npm.")
        }
    }
    private func label(_ role: ChatMessage.Role) -> String {
        switch role { case .user: return "You"; case .assistant: return "Pi"; case .activity: return "Activity"; case .error: return "Error" }
    }
    private func chatTimestampFormat(_ date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated).hour().minute()
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
    private func toggleVoiceMode() {
        voiceMode.toggle()
        if voiceMode { dictation.start() } else { dictation.stop() }
    }
    private func send() {
        let dictating = dictation.phase == .listening || dictation.phase == .reconnecting
        if dictating { dictation.stop() }
        let text = (dictating
            ? dictation.mergedInput(base: dictationBase ?? "", combined: dictation.combinedText)
            : input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, chat.phase == .ready else { return }
        input = ""; dictationBase = nil; chat.send(text)
    }
    private func handleVoiceUtterance(_ text: String) {
        let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !utterance.isEmpty else { return }
        lastVoiceUtterance = utterance
        guard voiceFilterEnabled else {
            deliverVoiceCommand(utterance)
            return
        }
        Task {
            let outcome = await JevClassifier(apiKey: jevApiKey).classify(utterance: utterance)
            if !outcome.isCommand, outcome.filterActive {
                showVoiceHint("Speech seems unrelated to board work, discarded.")
                return
            }
            if outcome.error != nil { showVoiceHint("Voice filter unavailable, sent anyway.") }
            deliverVoiceCommand(utterance)
        }
    }
    private func deliverVoiceCommand(_ text: String) {
        guard chat.phase == .ready else {
            pendingVoiceCommand = text
            showVoiceHint("Pi is busy. The command will send when ready.")
            return
        }
        chat.send(text)
    }
    private func showVoiceHint(_ message: String) {
        voiceHintTask?.cancel()
        voiceHint = message
        voiceHintTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            voiceHint = nil
        }
    }
}
