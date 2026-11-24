import SwiftUI

struct BoardCursor: Decodable, Identifiable, Equatable {
    let id, email, avatar: String
    let x, y: CGFloat
}
struct BoardCursorReply: Decodable {
    let revision: Int
    let cursors: [BoardCursor]
    let views: [PersonCamera]?
    let invites: ViewInvitations?
}
@MainActor
final class BoardCursorFeed: ObservableObject {
    @Published private(set) var items: [BoardCursor] = []
    func replace(_ next: [BoardCursor]) {
        if next != items { items = next }
    }
}

struct BoardCursorLayer: View {
    @ObservedObject var feed: BoardCursorFeed
    let zoom: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ink = Color(red: 0.22, green: 0.25, blue: 0.40)

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(feed.items) { cursor in
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: .zero)
                        p.addLine(to: CGPoint(x: 17, y: 12))
                        p.addLine(to: CGPoint(x: 9, y: 13))
                        p.addLine(to: CGPoint(x: 5, y: 20))
                        p.closeSubpath()
                    }.fill(ink).frame(width: 17, height: 20)
                    HStack(spacing: 4) {
                        ProfileFace(id: cursor.avatar, size: 19)
                        Text(cursor.email.components(separatedBy: "@").first ?? cursor.email)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 110)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(2).padding(.trailing, 4).background(ink, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white, lineWidth: 1))
                    .offset(x: 12, y: 12)
                }
                .fixedSize().scaleEffect(1 / zoom, anchor: .topLeading)
                .offset(x: cursor.x, y: cursor.y)
                .animation(reduceMotion ? nil : .linear(duration: 0.07), value: CGPoint(x: cursor.x, y: cursor.y))
                .accessibilityElement(children: .ignore).accessibilityLabel("\(cursor.email)’s cursor")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
    }
}

struct BoardPointerTracking: ViewModifier {
    let presence: BoardPresence
    let boardID: String
    let viewport: CGRect
    let zoom: CGFloat
    let active: Bool
    // Pointer motion must not invalidate the board's entire SwiftUI view tree.
    private final class Pointer { var point: CGPoint? }
    @State private var pointer = Pointer()

    static func boardPoint(_ point: CGPoint, viewport: CGRect, zoom: CGFloat) -> CGPoint? {
        guard zoom > 0, CGRect(origin: .zero, size: viewport.size).contains(point) else { return nil }
        return CGPoint(x: ((point.x + viewport.minX) / zoom).rounded(),
                       y: ((point.y + viewport.minY) / zoom).rounded())
    }
    private func publish() {
        presence.point(at: active ? pointer.point.flatMap { Self.boardPoint($0, viewport: viewport, zoom: zoom) } : nil)
    }
    func body(content: Content) -> some View {
        content.onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): pointer.point = point
            case .ended: pointer.point = nil
            }
            publish()
        }
        .onChange(of: viewport) { _, _ in publish() }
        .onChange(of: zoom) { _, _ in publish() }
        .onChange(of: active) { _, isActive in if !isActive { pointer.point = nil }; publish() }
        .onChange(of: boardID) { _, _ in pointer.point = nil; publish() }
        .onDisappear { pointer.point = nil; presence.point(at: nil) }
    }
}
