import SwiftUI
import PiChatCore

/// Pulse-driven orb shown by voice mode: the agent's "presence".
private struct OrbView: View {
    let color: Color
    let active: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.20)).frame(width: 300, height: 300).blur(radius: 32)
            Circle().fill(RadialGradient(colors: [color.opacity(0.8), color.opacity(0.12)], center: .center, startRadius: 6, endRadius: 130))
                .frame(width: 190, height: 190)
            Circle().fill(.white.opacity(0.18)).frame(width: 74, height: 74)
        }
        .scaleEffect(pulse ? 1.12 : 1.0)
        .animation(.easeInOut(duration: active ? 1.1 : 2.4).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
    }
}

private struct VoiceChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(title)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
    }
}

/// Immersive full-panel voice mode: orb, live transcript, and controls.
/// PiChatView owns the state; this view only renders it.
struct VoiceModeView: View {
    let listening: Bool
    let reconnecting: Bool
    let chatPhase: ChatPhase
    let combinedText: String
    let lastUtterance: String
    let assistantReply: String
    let hint: String
    let speaking: Bool
    let unavailableMessage: String?
    @Binding var jevFilterEnabled: Bool
    @Binding var speakRepliesEnabled: Bool
    let onClose: () -> Void
    let onMicToggle: () -> Void

    private var orbColor: Color {
        if unavailableMessage != nil { return .red }
        if speaking { return .green }
        if reconnecting { return .orange }
        if chatPhase == .running { return .orange }
        if listening { return .blue }
        return .gray
    }

    private var statusText: String {
        if unavailableMessage != nil { return "Voice unavailable" }
        if speaking { return "Speaking…" }
        if reconnecting { return "Reconnecting microphone…" }
        if chatPhase == .running { return "Thinking…" }
        if listening { return "Listening…" }
        return "Paused"
    }

    private var orbActive: Bool { speaking || reconnecting || chatPhase == .running || listening }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).opacity(0.6)
            VStack(spacing: 16) {
                HStack {
                    VoiceChip(title: "Jev filter", systemImage: "sparkles", isOn: jevFilterEnabled) { jevFilterEnabled.toggle() }
                    VoiceChip(title: "Speak replies", systemImage: "speaker.wave.2", isOn: speakRepliesEnabled) { speakRepliesEnabled.toggle() }
                    Spacer()
                    Button { onClose() } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Exit voice mode")
                }
                Spacer()
                OrbView(color: orbColor, active: orbActive)
                Text(statusText).font(.title3.weight(.semibold))
                if !combinedText.isEmpty {
                    Text(combinedText).font(.title3).multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                } else if !assistantReply.isEmpty {
                    Text(assistantReply).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineLimit(6)
                        .frame(maxWidth: 460)
                } else if !lastUtterance.isEmpty {
                    Text(lastUtterance).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                } else if unavailableMessage == nil {
                    Text("Speak a board command…").font(.title3).foregroundStyle(.tertiary)
                }
                if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
                if let unavailableMessage { Text(unavailableMessage).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center) }
                Spacer()
                Button { onMicToggle() } label: {
                    ZStack {
                        Circle().fill(listening || reconnecting ? Color.red : Color.accentColor).frame(width: 68, height: 68)
                        Image(systemName: listening || reconnecting ? "pause.fill" : "mic.fill").font(.title2).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(listening || reconnecting ? "Pause microphone" : "Resume microphone")
                Text(reconnecting ? "Switching audio input. Click to pause." : (listening ? "Mic is live. Click to pause." : "Mic paused. Click to resume."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }
}
