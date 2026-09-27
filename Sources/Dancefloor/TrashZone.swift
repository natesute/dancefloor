import AppKit

/// A bin that fades in at the bottom of the screen while a dancer is being dragged.
/// Dropping a dancer on it removes the dancer.
@MainActor
final class TrashZone: NSPanel {
    private static let size: CGFloat = 76
    private let circle = NSVisualEffectView()
    private let icon = NSImageView()
    private(set) var isHot = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        alphaValue = 0

        circle.material = .hudWindow
        circle.state = .active
        circle.wantsLayer = true
        circle.layer?.cornerRadius = Self.size / 2
        circle.layer?.masksToBounds = true
        icon.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove dancer")
        icon.symbolConfiguration = .init(pointSize: 26, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.frame = circle.bounds.insetBy(dx: 18, dy: 18)
        icon.autoresizingMask = [.width, .height]
        circle.frame = NSRect(x: 0, y: 0, width: Self.size, height: Self.size)
        circle.addSubview(icon)
        contentView = circle
    }

    /// Fade in at the bottom centre of the screen the pointer is on.
    func appear() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - Self.size / 2, y: visible.minY + 28))
        }
        setHot(false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    func disappear() {
        setHot(false)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if self.alphaValue == 0 { self.orderOut(nil) } }
        }
    }

    /// Highlights when the pointer is over the bin (with some slack so it's easy to hit).
    @discardableResult
    func track(pointer: NSPoint) -> Bool {
        setHot(isVisible && frame.insetBy(dx: -24, dy: -24).contains(pointer))
        return isHot
    }

    private func setHot(_ hot: Bool) {
        guard hot != isHot || circle.layer?.backgroundColor == nil else { return }
        isHot = hot
        circle.layer?.backgroundColor = hot ? NSColor.systemRed.cgColor : NSColor.clear.cgColor
        icon.contentTintColor = hot ? .white : .labelColor
        icon.image = NSImage(systemSymbolName: hot ? "trash.fill" : "trash", accessibilityDescription: "Remove dancer")
    }
}
