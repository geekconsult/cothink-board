import AppKit
import SwiftUI

/// Manages the app's auxiliary floating windows as plain NSWindows instead of
/// SwiftUI Window scenes: each window is independent (closing one never closes
/// another) and the agent chat window opens at the bottom-right corner.
@MainActor
final class AuxiliaryWindowHost {
    static let shared = AuxiliaryWindowHost()

    private var factories: [String: () -> NSWindow] = [:]
    private var windows: [String: NSWindow] = [:]

    func register(id: String, make: @escaping () -> NSWindow) {
        factories[id] = make
    }

    @discardableResult
    func open(id: String) -> NSWindow? {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            return existing
        }
        guard let make = factories[id] else { return nil }
        let window = make()
        windows[id] = window
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func setTitle(id: String, _ title: String) {
        windows[id]?.title = title
    }

    static func makeWindow(title: String, content: some View, size: NSSize, screenOrigin: NSPoint? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        if let screenOrigin {
            window.setFrameOrigin(screenOrigin)
        } else {
            window.center()
        }
        return window
    }

    /// Bottom-right of the visible screen, inset from the edges.
    static func bottomRightOrigin(for size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
    }
}
