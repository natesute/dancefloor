import AppKit
import DancefloorCore

@MainActor
protocol DancerWindowDelegate: AnyObject {
    func dancerWantsNewGif(_ dancer: DancerWindow)
    func dancerWantsToBeKept(_ dancer: DancerWindow)
    func dancerDidChangeTuning(_ dancer: DancerWindow)
    func dancerDidMove(_ dancer: DancerWindow)
    func dancerWantsRemoval(_ dancer: DancerWindow)
    func dancerWasClicked(_ dancer: DancerWindow)
    func dancerDidStartDragging(_ dancer: DancerWindow)
}

/// One floating, transparent, draggable dancer. Each dancer is its own small window, so
/// clicks anywhere else on screen go straight through to whatever is underneath.
@MainActor
final class DancerWindow: NSPanel {
    private(set) var gif: LoadedGif
    var beatsPerLoop: Int
    /// Offset into the loop, in beats (half-beat steps).
    var beatShift: Double
    weak var dancerDelegate: DancerWindowDelegate?

    private let dancerView = DancerView()
    private var shownFrame = -1
    /// Temporarily shown while hovering an alternative in the swap strip.
    private var preview: (gif: LoadedGif, beats: Int, shift: Double)?
    private var shown: LoadedGif { preview?.gif ?? gif }
    var isLoading = false { didSet { dancerView.alphaValue = isLoading ? 0.5 : 1 } }

    init(gif: LoadedGif, beatsPerLoop: Int, beatShift: Double, height: CGFloat, center: NSPoint) {
        self.gif = gif
        self.beatsPerLoop = beatsPerLoop
        self.beatShift = beatShift
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = dancerView
        dancerView.window_ = self
        setFrame(Self.frame(for: gif.animation, height: height, center: center), display: false)
        showFrame(0)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var dancerHeight: CGFloat { frame.height }
    var center: NSPoint { NSPoint(x: frame.midX, y: frame.midY) }

    func setPreview(_ previewGif: LoadedGif?, beatsPerLoop: Int = 4, beatShift: Double = 0) {
        preview = previewGif.map { ($0, beatsPerLoop, beatShift) }
        shownFrame = -1
        setFrame(Self.frame(for: shown.animation, height: frame.height, center: center), display: true)
    }

    func replaceGif(_ newGif: LoadedGif, beatsPerLoop: Int, beatShift: Double) {
        preview = nil
        gif = newGif
        self.beatsPerLoop = beatsPerLoop
        self.beatShift = beatShift
        shownFrame = -1
        setFrame(Self.frame(for: newGif.animation, height: frame.height, center: center), display: true)
        showFrame(0)
    }

    /// Called every display refresh. `beat` is nil when there's no music to follow.
    func tick(beat: Double?, now: Double) {
        let anim = shown.animation
        let beats = preview?.beats ?? beatsPerLoop
        let shift = preview?.shift ?? beatShift
        let progress: Double
        if let beat {
            progress = (beat - shift) / Double(beats)
        } else {
            progress = now / anim.duration
        }
        showFrame(anim.frameIndex(progress: progress))
    }

    private func showFrame(_ index: Int) {
        guard index != shownFrame else { return }
        shownFrame = index
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dancerView.layer?.contents = shown.animation.frames[index]
        CATransaction.commit()
    }

    func resize(by factor: CGFloat) {
        let height = min(900, max(60, frame.height * factor))
        setFrame(Self.frame(for: shown.animation, height: height, center: center), display: true)
    }

    private static func frame(for anim: GIFAnimation, height: CGFloat, center: NSPoint) -> NSRect {
        let aspect = anim.pixelSize.width / max(1, anim.pixelSize.height)
        let width = height * aspect
        return NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    // MARK: - Context menu

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Change Dancer", #selector(changeGif)))
        menu.addItem(.separator())

        let beats = NSMenuItem(title: "Beats per Loop", action: nil, keyEquivalent: "")
        let beatsMenu = NSMenu()
        for n in [1, 2, 4, 8, 16] {
            let i = item("\(n)", #selector(setBeats(_:)))
            i.tag = n
            i.state = n == beatsPerLoop ? .on : .off
            beatsMenu.addItem(i)
        }
        beats.submenu = beatsMenu
        menu.addItem(beats)
        menu.addItem(item("Faster (Halve Loop)", #selector(faster)))
        menu.addItem(item("Slower (Double Loop)", #selector(slower)))
        menu.addItem(item("Shift Half a Beat", #selector(shiftHalfBeatAction)))
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(bigger)))
        menu.addItem(item("Smaller", #selector(smaller)))
        if gif.source.isGiphy {
            menu.addItem(.separator())
            menu.addItem(item("Keep in My Folder", #selector(keep)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Remove", #selector(remove)))
        let title = NSMenuItem(title: gif.title, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.insertItem(title, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func changeGif() { dancerDelegate?.dancerWantsNewGif(self) }
    @objc private func keep() { dancerDelegate?.dancerWantsToBeKept(self) }
    @objc private func remove() { dancerDelegate?.dancerWantsRemoval(self) }
    @objc private func bigger() { resize(by: 1.25); dancerDelegate?.dancerDidMove(self) }
    @objc private func smaller() { resize(by: 0.8); dancerDelegate?.dancerDidMove(self) }
    func halveSpeed() { beatsPerLoop = min(32, beatsPerLoop * 2); dancerDelegate?.dancerDidChangeTuning(self) }
    func doubleSpeed() { beatsPerLoop = max(1, beatsPerLoop / 2); dancerDelegate?.dancerDidChangeTuning(self) }
    func shiftHalfBeat() {
        beatShift = (beatShift + 0.5).truncatingRemainder(dividingBy: Double(beatsPerLoop))
        dancerDelegate?.dancerDidChangeTuning(self)
    }

    @objc private func setBeats(_ sender: NSMenuItem) { beatsPerLoop = sender.tag; dancerDelegate?.dancerDidChangeTuning(self) }
    @objc private func faster() { doubleSpeed() }
    @objc private func slower() { halveSpeed() }
    @objc private func shiftHalfBeatAction() { shiftHalfBeat() }
}

/// Draws the current frame and handles click, drag, scroll-to-resize and right-click.
@MainActor
private final class DancerView: NSView {
    weak var window_: DancerWindow?
    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        originStart = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let originStart, let window else { return }
        let now = NSEvent.mouseLocation
        if !dragged {
            // A few points of wobble still counts as a click.
            guard hypot(now.x - dragStart.x, now.y - dragStart.y) > 3 else { return }
            dragged = true
            window_.map { $0.dancerDelegate?.dancerDidStartDragging($0) }
        }
        window.setFrameOrigin(NSPoint(x: originStart.x + now.x - dragStart.x, y: originStart.y + now.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil, let w = window_ else { return }
        if dragged { w.dancerDelegate?.dancerDidMove(w) } else { w.dancerDelegate?.dancerWasClicked(w) }
        dragStart = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let w = window_ else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20
        w.resize(by: 1 + max(-0.3, min(0.3, delta)))
        if event.phase == .ended || event.momentumPhase == .ended || !event.hasPreciseScrollingDeltas {
            w.dancerDelegate?.dancerDidMove(w)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { window_?.makeMenu() }
}
