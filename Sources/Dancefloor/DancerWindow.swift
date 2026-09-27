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
    /// Doublings of speed on top of the automatic fit: +1 twice as fast, -1 half as fast.
    var speedBias: Int
    /// Offset into the loop, in beats (half-beat steps).
    var beatShift: Double
    weak var dancerDelegate: DancerWindowDelegate?

    private let dancerView = DancerView()
    private var shownFrame = -1
    /// Temporarily shown while hovering an alternative in the swap strip.
    private var preview: (gif: LoadedGif, bias: Int, shift: Double)?
    private var shown: LoadedGif { preview?.gif ?? gif }
    /// Automatic beats-per-loop for the committed GIF and the preview, kept between frames
    /// so the fit only changes when the tempo clearly calls for it.
    private var fittedBeats: Double?
    private var previewFittedBeats: Double?
    var isLoading = false { didSet { dancerView.alphaValue = isLoading ? 0.5 : 1 } }

    init(gif: LoadedGif, speedBias: Int, beatShift: Double, height: CGFloat, center: NSPoint) {
        self.gif = gif
        self.speedBias = speedBias
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

    func setPreview(_ previewGif: LoadedGif?, speedBias: Int = 0, beatShift: Double = 0) {
        preview = previewGif.map { ($0, speedBias, beatShift) }
        previewFittedBeats = nil
        shownFrame = -1
        setFrame(Self.frame(for: shown.animation, height: frame.height, center: center), display: true)
    }

    func replaceGif(_ newGif: LoadedGif, speedBias: Int, beatShift: Double) {
        preview = nil
        gif = newGif
        fittedBeats = nil
        self.speedBias = speedBias
        self.beatShift = beatShift
        shownFrame = -1
        setFrame(Self.frame(for: newGif.animation, height: frame.height, center: center), display: true)
        showFrame(0)
    }

    /// Called every display refresh. `beat` and `period` are nil when there's no music to follow.
    func tick(beat: Double?, period: Double?, now: Double) {
        let anim = shown.animation
        guard let beat, let period else {
            return showFrame(anim.frameIndex(progress: now / anim.duration))
        }
        let beats: Double
        let shift: Double
        if let preview {
            previewFittedBeats = LoopFit.beatsPerLoop(nativeDuration: anim.duration, beatPeriod: period, current: previewFittedBeats)
            beats = previewFittedBeats! * pow(2, Double(-preview.bias))
            shift = preview.shift
        } else {
            fittedBeats = LoopFit.beatsPerLoop(nativeDuration: anim.duration, beatPeriod: period, current: fittedBeats)
            beats = fittedBeats! * pow(2, Double(-speedBias))
            shift = beatShift
        }
        showFrame(anim.frameIndex(progress: (beat - shift) / beats))
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

        menu.addItem(item("Faster", #selector(faster)))
        menu.addItem(item("Slower", #selector(slower)))
        let auto = item("Automatic Speed", #selector(resetSpeed))
        auto.state = speedBias == 0 ? .on : .off
        menu.addItem(auto)
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
    func halveSpeed() { speedBias = max(-3, speedBias - 1); dancerDelegate?.dancerDidChangeTuning(self) }
    func doubleSpeed() { speedBias = min(3, speedBias + 1); dancerDelegate?.dancerDidChangeTuning(self) }
    func shiftHalfBeat() {
        beatShift = (beatShift + 0.5).truncatingRemainder(dividingBy: 8)
        dancerDelegate?.dancerDidChangeTuning(self)
    }

    @objc private func resetSpeed() { speedBias = 0; dancerDelegate?.dancerDidChangeTuning(self) }
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
