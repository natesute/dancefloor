import AppKit

/// A bin that fades in at the bottom of the screen while a dancer is being dragged.
/// Dropping a dancer on it removes the dancer.
@MainActor
final class TrashZone: NSPanel {
    private static let size: CGFloat = 64
    private let bin = BinView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    var isHot: Bool { bin.isHot }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        alphaValue = 0
        contentView = bin
    }

    /// Fade in at the bottom centre of the screen the pointer is on.
    func appear() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.midX - Self.size / 2, y: visible.minY + 28))
        }
        bin.isHot = false
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    func disappear() {
        bin.isHot = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { if self.alphaValue == 0 { self.orderOut(nil) } }
        }
    }

    /// Highlights when the pointer is over the bin (with some slack so it's easy to hit).
    @discardableResult
    func track(pointer: NSPoint) -> Bool {
        let hot = isVisible && frame.insetBy(dx: -24, dy: -24).contains(pointer)
        if hot != bin.isHot { bin.isHot = hot }
        return hot
    }
}

/// Dark translucent disc with a white bin; red and slightly larger when armed.
private final class BinView: NSView {
    var isHot = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isHot ? 1 : 5
        let disc = bounds.insetBy(dx: inset, dy: inset)
        (isHot ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.72)).setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSColor.white.withAlphaComponent(isHot ? 0 : 0.18).setStroke()
        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()

        let config = NSImage.SymbolConfiguration(pointSize: isHot ? 24 : 21, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: isHot ? "trash.fill" : "trash", accessibilityDescription: "Remove dancer")?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                               width: size.width, height: size.height))
    }
}
