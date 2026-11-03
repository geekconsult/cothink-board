import SwiftUI
import AppKit
import BoardCore

/// Connects the SwiftUI overview to the actual scroll view, including trackpad scrolling.
struct ScrollViewportObserver: NSViewRepresentable {
    @Binding var viewport: CGRect
    @Binding var request: CGPoint?
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = { rect in DispatchQueue.main.async { viewport = rect } }
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) {
        view.attach()
        if let point = request, let scroll = view.enclosingScrollView {
            let clip = scroll.contentView
            let x = max(0, min(point.x - clip.bounds.width / 2, max(0, (scroll.documentView?.bounds.width ?? 0) - clip.bounds.width)))
            let y = max(0, min(point.y - clip.bounds.height / 2, max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)))
            clip.scroll(to: NSPoint(x: x, y: y)); scroll.reflectScrolledClipView(clip)
            DispatchQueue.main.async { request = nil }
        }
    }
    final class ObserverView: NSView {
        var onChange: ((CGRect) -> Void)?
        private weak var clip: NSClipView?
        private var token: NSObjectProtocol?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        func attach() {
            guard let newClip = enclosingScrollView?.contentView, clip !== newClip else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            clip = newClip; newClip.postsBoundsChangedNotifications = true
            token = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: newClip, queue: .main) { [weak self, weak newClip] _ in
                if let rect = newClip?.bounds { self?.onChange?(rect) }
            }
            onChange?(newClip.bounds)
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

struct BoardMinimap: View {
    let board: Board
    let extent: CGSize
    let zoom: Double
    let viewport: CGRect
    let navigate: (CGPoint) -> Void
    @State private var expanded = true
    private let mapWidth: CGFloat = 130
    private var mapHeight: CGFloat { mapWidth * extent.height / extent.width }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if expanded { Text("Overview").font(.caption.weight(.semibold)); Spacer(minLength: 4) }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "map") }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide overview" : "Show overview")
                    .accessibilityLabel(expanded ? "Hide board overview" : "Show board overview")
            }
            if expanded { Canvas { context, size in
                let sx = size.width / extent.width, sy = size.height / extent.height
                for group in board.groups {
                    let rect = CGRect(x: group.x * sx, y: group.y * sy, width: group.width * sx, height: group.height * sy)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color(hex: group.color).opacity(0.45)))
                }
                for note in board.notes {
                    let rect = CGRect(x: note.x * sx, y: note.y * sy, width: max(2, note.width * sx), height: max(2, note.height * sy))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color(hex: note.color)))
                }
                let rect = CGRect(x: viewport.minX / zoom * sx, y: viewport.minY / zoom * sy, width: viewport.width / zoom * sx, height: viewport.height / zoom * sy)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.13)))
                context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1.5)
            }
            .frame(width: mapWidth, height: mapHeight)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                navigate(CGPoint(x: max(0, min(mapWidth, value.location.x)) / mapWidth * extent.width * zoom,
                                 y: max(0, min(mapHeight, value.location.y)) / mapHeight * extent.height * zoom))
            })
            .accessibilityLabel("Board overview. Click or drag to navigate")
            }
        }
        .frame(width: expanded ? mapWidth : 18)
        .padding(7).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
