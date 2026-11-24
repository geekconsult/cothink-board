import SwiftUI

struct AppPrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

struct AppPanelBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            Color(nsColor: .windowBackgroundColor)
                .overlay {
                    if !reduceTransparency {
                        LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear, .clear],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
        }
    }
}

struct AppPanelHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    var closeLabel = "Close"
    var close: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium))
                .foregroundStyle(.tint).frame(width: 42, height: 42)
                .modifier(GlassFloatingSurface())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2).help(subtitle)
                }
            }
            Spacer(minLength: 0)
            if let close {
                Button(action: close) { Image(systemName: "xmark").frame(width: 16, height: 20) }
                    .buttonStyle(.plain).modifier(GlassControl())
                    .keyboardShortcut(.cancelAction).accessibilityLabel(closeLabel).help(closeLabel)
            }
        }

    }
}
