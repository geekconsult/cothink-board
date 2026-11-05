import SwiftUI
import PiChatCore

/// Context-window gauge in the chat header. Hover shows a breakdown card:
/// measured totals plus an honest estimated split of conversation vs system+tools.
struct ContextUsageBadge: View {
    let usage: ContextUsage
    let conversationEstimate: Int
    @State private var hovered = false

    private var percentText: String {
        guard let percent = usage.percent else { return "–" }
        return "\(Int((percent * 100).rounded()))%"
    }

    private var badgeTint: Color {
        guard let percent = usage.percent else { return .secondary }
        if percent > 0.85 { return .red }
        if percent > 0.6 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(spacing: 3) {
            Text(percentText).font(.caption2.weight(.semibold)).monospacedDigit()
            ProgressView(value: usage.percent ?? 0)
                .frame(width: 44)
                .tint(badgeTint)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in hovered = hovering }
        .popover(isPresented: $hovered, arrowEdge: .bottom) {
            breakdownCard.padding(14).frame(width: 300)
        }
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Context window").font(.headline)
            if let percent = usage.percent, let used = usage.usedTokens, let window = usage.contextWindow {
                Text("Used \(used) of \(window) tokens (\(Int((percent * 100).rounded()))%)").font(.caption)
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text("Conversation").font(.caption.weight(.semibold)).frame(width: 108, alignment: .leading)
                    Text("≈ \(conversationEstimate) tokens (estimated from message text)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("System + tools").font(.caption.weight(.semibold)).frame(width: 108, alignment: .leading)
                    Text("≈ \(max(0, used - conversationEstimate)) tokens (derived from measured total)").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("\(usage.messageCount ?? 0) messages in this session").font(.caption)
                if usage.isCompacting { Text("Compacting context now…").font(.caption).foregroundStyle(.orange) }
                if usage.autoCompactionEnabled { Text("Auto-compaction trims old turns when the window fills.").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("Token usage appears after the first reply.").font(.caption).foregroundStyle(.secondary)
                if let window = usage.contextWindow {
                    Text("Model window: \(window) tokens").font(.caption)
                }
            }
        }
    }
}

struct MemoryEditorSection: View {
    let initialText: String
    let onSave: (String) -> Void
    let onClear: () -> Void
    @State private var draft: String

    init(initialText: String, onSave: @escaping (String) -> Void, onClear: @escaping () -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        self.onClear = onClear
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Agent memory").font(.caption.weight(.semibold))
                Spacer()
                Button("Save") { onSave(draft) }
                    .disabled(draft == initialText)
                Button("Clear", role: .destructive) { onClear() }
            }
            TextEditor(text: $draft)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            Text("Loaded into every new session as context. Pi can update it with the cothink_memory tool. Changes apply from the next session.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MCPServersSection: View {
    let servers: [MCPServerSpec]
    let message: String?
    let onAdd: (String, String, String) -> Void
    let onImport: () -> Void
    let onRemove: (String) -> Void
    @State private var nameField = ""
    @State private var commandField = ""
    @State private var argsField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("MCP servers").font(.caption.weight(.semibold))
                Spacer()
                Button("Import JSON…") { onImport() }
            }
            if servers.isEmpty {
                Text("No external MCP servers yet. Import a Claude Desktop style mcpServers JSON file or add one below.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(servers) { server in
                HStack(spacing: 6) {
                    Circle().fill(server.enabled ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(server.name).font(.caption.weight(.semibold))
                    Spacer()
                    Text(server.command).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button { onRemove(server.name) } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Remove \(server.name)")
                }
            }
            HStack(spacing: 6) {
                TextField("Name", text: $nameField).textFieldStyle(.roundedBorder).frame(width: 92)
                TextField("Command", text: $commandField).textFieldStyle(.roundedBorder)
                TextField("Args (space separated)", text: $argsField).textFieldStyle(.roundedBorder).frame(width: 132)
                Button("Add") {
                    onAdd(nameField, commandField, argsField)
                    nameField = ""; commandField = ""; argsField = ""
                }
                .disabled(nameField.trimmingCharacters(in: .whitespaces).isEmpty || commandField.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ChatHistorySection: View {
    let sessions: [ChatSessionSummary]
    let onNewChat: () -> Void
    let onOpen: (ChatSessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Chat history").font(.caption.weight(.semibold))
                Spacer()
                Button("New chat") { onNewChat() }
            }
            if sessions.isEmpty {
                Text("No past sessions on this board yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(sessions.prefix(6)) { session in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(session.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2.weight(.semibold))
                            if session.isCurrent {
                                Text("current")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.16), in: Capsule())
                            }
                        }
                        Text(session.firstUserMessage)
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text("\(session.messageCount) msgs").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    Button("Open") { onOpen(session) }
                        .controlSize(.small)
                        .disabled(session.isCurrent)
                }
            }
        }
    }
}
