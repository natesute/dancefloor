import AppKit
import CoreAudio
import DancefloorCore
import QuartzCore
import Carbon
import SwiftUI
import os

private let log = Logger(subsystem: "com.natesute.dancefloor", category: "app")

struct SavedDancer: Codable {
    let source: GifSource
    let title: String
    let term: String?
    let x: Double
    let y: Double
    let height: Double
}

/// Feeds tap audio into the tracker on the audio queue and reports estimates on main.
private final class Analyzer: @unchecked Sendable {
    private var tracker: BeatTracker?
    var onEstimate: ((BeatEstimate?) -> Void)?

    func feed(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, time: Double) {
        if tracker?.sampleRate != sampleRate { tracker = BeatTracker(sampleRate: sampleRate) }
        guard let tracker, tracker.process(samples, time: time) else { return }
        let estimate = tracker.estimate
        DispatchQueue.main.async { self.onEstimate?(estimate) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, DancerWindowDelegate, DancefloorController, SwapStripDelegate {
    private let library = GifLibrary()
    private let clock = BeatClock()
    private let tap = SystemAudioTap()
    private let analyzer = Analyzer()
    private lazy var picker = PickerModel(library: library)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var dancers: [DancerWindow] = []
    private var strip: SwapStrip?
    private var appBeforeStrip: NSRunningApplication?
    private var hoverTask: Task<Void, Never>?
    private var fullGifCache: [String: LoadedGif] = [:]
    private var displayLink: CADisplayLink?
    private var audioError: String?
    /// True while saved dancers are loading, so a half-restored list never overwrites the saved one.
    private var isRestoring = false
    private var popoverClosedAt: CFTimeInterval = 0
    private let trash = TrashZone()
    private var hideHotKey: HotKey?

    var syncOffset: Double {
        get { UserDefaults.standard.object(forKey: "syncOffset") as? Double ?? 0.05 }
        set { UserDefaults.standard.set(newValue, forKey: "syncOffset"); clock.offset = newValue }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        clock.offset = syncOffset

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🕺"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        picker.controller = self
        popover.behavior = .transient
        popover.delegate = self
        // Fixed size: letting SwiftUI drive it made the popover grow with the grid and get
        // pushed up past the top of the screen.
        let hosting = NSHostingController(rootView: PickerView(model: picker))
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.contentSize = PickerView.size

        analyzer.onEstimate = { [weak self] estimate in self?.handle(estimate) }
        tap.onAudio = { [analyzer] samples, sampleRate, time in
            analyzer.feed(samples, sampleRate: sampleRate, time: time)
        }
        startAudio()
        watchDefaultOutputDevice()

        let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        displayLink = link

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.closeStrip(restoreFocus: false) }
        }

        hideHotKey = HotKey(keyCode: kVK_ANSI_D, modifiers: cmdKey | optionKey) { [weak self] in
            self?.dancersHidden.toggle()
        }

        restoreDancers()

        // Launch with `--args -debugShowPicker YES` or `-debugOpenStrip YES` to check the UI without clicking.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "debugShowPicker") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.togglePopover() }
        }
        if defaults.bool(forKey: "debugShowTrash") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.trash.appear() }
        }
        if defaults.bool(forKey: "debugOpenStrip") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.dancers.first.map(self.openStrip) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveDancers()
        tap.stop()
    }

    // MARK: - Audio

    private func startAudio() {
        do {
            try tap.start()
            audioError = nil
            log.notice("Audio tap started")
        } catch {
            audioError = "\(error)"
            log.error("Audio tap failed: \(error, privacy: .public)")
        }
        updateStatus()
    }

    private func watchDefaultOutputDevice() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.startAudio() }
        }
    }

    private func handle(_ estimate: BeatEstimate?) {
        if let e = estimate {
            log.info("Beat \(e.bpm, format: .fixed(precision: 2)) BPM, confidence \(e.confidence, format: .fixed(precision: 2))")
            clock.update(e, now: CACurrentMediaTime())
        }
        updateStatus()
    }

    private func updateStatus() {
        let locked = clock.isLocked(at: CACurrentMediaTime())
        statusItem?.button?.title = locked ? "🕺 \(Int(clock.bpm.rounded()))" : "🕺"
        let problem = audioError == nil ? nil : "Can't hear your Mac's audio. Allow Dancefloor under Privacy → Audio Recording."
        if picker.audioProblem != problem { picker.audioProblem = problem }
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let locked = clock.isLocked(at: now)
        let beat = locked ? clock.barBeatPosition(at: now) : nil
        let period = locked ? clock.period : nil
        for dancer in dancers { dancer.tick(beat: beat, period: period, now: now) }
    }

    // MARK: - Popover

    func popoverDidClose(_ notification: Notification) { popoverClosedAt = CACurrentMediaTime() }

    @objc private func togglePopover() {
        // A transient popover closes on mouse-down outside it, including on the 🕺 button,
        // before this action runs. Treat that click as "close" rather than reopening.
        if popover.isShown || CACurrentMediaTime() - popoverClosedAt < 0.3 {
            popover.performClose(nil)
            return
        }
        closeStrip(restoreFocus: false)
        guard let button = statusItem.button else { return }
        picker.refresh()
        updateStatus()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - DancefloorController

    func addDancer(from item: PickerItem) async throws {
        addDancer(try await loadFull(item))
    }

    func randomiseAll() {
        if dancers.isEmpty { return addRandomDancer() }
        for dancer in dancers { swapToRandom(dancer) }
    }

    func removeAllDancers() {
        closeStrip(restoreFocus: false)
        for dancer in dancers { dancer.close() }
        dancers.removeAll()
        saveDancers()
        updateStatus()
    }

    func openFolder() { NSWorkspace.shared.open(library.folder) }

    func closePicker() { popover.performClose(nil) }

    var dancersHidden = false {
        didSet {
            guard dancersHidden != oldValue else { return }
            if dancersHidden { closeStrip(restoreFocus: false) }
            for dancer in dancers {
                if dancersHidden { dancer.orderOut(nil) } else { dancer.orderFrontRegardless() }
            }
            statusItem.button?.appearsDisabled = dancersHidden
            if picker.dancersHidden != dancersHidden { picker.dancersHidden = dancersHidden }
        }
    }

    // MARK: - Scenes

    private var scenes: [String: [SavedDancer]] {
        get {
            UserDefaults.standard.data(forKey: "scenes")
                .flatMap { try? JSONDecoder().decode([String: [SavedDancer]].self, from: $0) } ?? [:]
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "scenes") }
    }

    var sceneNames: [String] { scenes.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func saveScene(named name: String) { scenes[name] = currentLayout() }

    func deleteScene(named name: String) { scenes[name] = nil }

    func loadScene(named name: String) {
        guard let layout = scenes[name] else { return }
        removeAllDancers()
        dancersHidden = false
        restore(layout)
    }

    // MARK: - Dancers

    private func addDancer(_ gif: LoadedGif, height: CGFloat = 220, center: NSPoint? = nil) {
        if dancersHidden { dancersHidden = false }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let point = center ?? NSPoint(
            x: .random(in: visible.minX + 150...max(visible.minX + 151, visible.maxX - 150)),
            y: .random(in: visible.minY + 150...max(visible.minY + 151, visible.maxY - 150)))
        let dancer = DancerWindow(gif: gif, speedBias: library.speedBias(for: gif.source),
                                  beatShift: library.beatShift(for: gif.source), height: height, center: point)
        dancer.dancerDelegate = self
        dancer.orderFrontRegardless()
        dancers.append(dancer)
        saveDancers()
        updateStatus()
    }

    private func addRandomDancer() {
        Task {
            do { addDancer(try await library.random()) } catch { picker.message = error.localizedDescription }
        }
    }

    private func swapToRandom(_ dancer: DancerWindow) {
        guard !dancer.isLoading else { return }
        dancer.isLoading = true
        Task {
            defer { dancer.isLoading = false }
            do {
                let gif = try await library.random(excluding: dancer.gif.source)
                commit(gif, to: dancer)
            } catch {
                picker.message = error.localizedDescription
            }
        }
    }

    private func commit(_ gif: LoadedGif, to dancer: DancerWindow) {
        dancer.replaceGif(gif, speedBias: library.speedBias(for: gif.source), beatShift: library.beatShift(for: gif.source))
        saveDancers()
    }

    /// Full-size GIF for a picker item, cached so hover-then-click doesn't download twice.
    private func loadFull(_ item: PickerItem) async throws -> LoadedGif {
        if let hit = fullGifCache[item.id] { return hit }
        let gif = try await library.load(item)
        if fullGifCache.count > 40 { fullGifCache.removeAll() }
        fullGifCache[item.id] = gif
        return gif
    }

    func dancerWantsNewGif(_ dancer: DancerWindow) { swapToRandom(dancer) }

    func dancerWantsToBeKept(_ dancer: DancerWindow) {
        do { try library.keep(dancer.gif) } catch { picker.message = error.localizedDescription }
    }

    func dancerDidChangeTuning(_ dancer: DancerWindow) {
        library.setSpeedBias(dancer.speedBias, for: dancer.gif.source)
        library.setBeatShift(dancer.beatShift, for: dancer.gif.source)
    }

    func dancerDidMove(_ dancer: DancerWindow) {
        if trash.isVisible {
            let dropped = trash.track(pointer: NSEvent.mouseLocation)
            trash.disappear()
            if dropped { return discard(dancer) }
        }
        saveDancers()
        if strip?.dancer === dancer { strip?.position() }
    }

    func dancerDidStartDragging(_ dancer: DancerWindow) {
        closeStrip(restoreFocus: true)
        trash.appear()
    }

    func dancerIsDragging(_ dancer: DancerWindow) {
        dancer.alphaValue = trash.track(pointer: NSEvent.mouseLocation) ? 0.4 : 1
    }

    /// Shrink and fade out, then remove.
    private func discard(_ dancer: DancerWindow) {
        let frame = dancer.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            dancer.animator().alphaValue = 0
            dancer.animator().setFrame(frame.insetBy(dx: frame.width * 0.4, dy: frame.height * 0.4), display: true)
        }) {
            MainActor.assumeIsolated { self.dancerWantsRemoval(dancer) }
        }
    }

    func dancerWasClicked(_ dancer: DancerWindow) {
        if strip?.dancer === dancer { return closeStrip(restoreFocus: true) }
        openStrip(for: dancer)
    }

    func dancerWantsRemoval(_ dancer: DancerWindow) {
        if strip?.dancer === dancer { closeStrip(restoreFocus: true) }
        dancer.close()
        dancers.removeAll { $0 === dancer }
        saveDancers()
        updateStatus()
    }

    private func currentLayout() -> [SavedDancer] {
        dancers.map {
            SavedDancer(source: $0.gif.source, title: $0.gif.title, term: $0.gif.term,
                        x: $0.center.x, y: $0.center.y, height: $0.dancerHeight)
        }
    }

    private func saveDancers() {
        guard !isRestoring else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(currentLayout()), forKey: "dancers")
    }

    private func restoreDancers() {
        guard let data = UserDefaults.standard.data(forKey: "dancers"),
              let saved = try? JSONDecoder().decode([SavedDancer].self, from: data), !saved.isEmpty else {
            // Nothing saved: start with one dancer so there's something to see.
            return addRandomDancer()
        }
        restore(saved)
    }

    private func restore(_ saved: [SavedDancer]) {
        isRestoring = true
        Task { @MainActor in
            // Download in parallel, add in the saved order.
            let gifs = await withTaskGroup(of: (Int, LoadedGif?).self) { group in
                for (i, s) in saved.enumerated() {
                    group.addTask { @MainActor in (i, try? await self.library.load(s.source, title: s.title, term: s.term)) }
                }
                var results = [LoadedGif?](repeating: nil, count: saved.count)
                for await (i, gif) in group { results[i] = gif }
                return results
            }
            for (s, gif) in zip(saved, gifs) {
                guard let gif else { continue }
                addDancer(gif, height: s.height, center: NSPoint(x: s.x, y: s.y))
            }
            isRestoring = false
            if dancers.isEmpty { addRandomDancer() } else { saveDancers() }
        }
    }

    // MARK: - Swap strip

    private func openStrip(for dancer: DancerWindow) {
        closeStrip(restoreFocus: false)
        popover.performClose(nil)
        let newStrip = SwapStrip(dancer: dancer)
        newStrip.stripDelegate = self
        newStrip.model.canKeep = dancer.gif.source.isGiphy
        newStrip.position()
        strip = newStrip

        // Activate so hovering the alternatives registers; hand focus back when the strip closes.
        if !NSApp.isActive { appBeforeStrip = NSWorkspace.shared.frontmostApplication }
        NSApp.activate()
        newStrip.makeKeyAndOrderFront(nil)
        loadAlternatives(for: newStrip)
    }

    private func loadAlternatives(for strip: SwapStrip) {
        guard let dancer = strip.dancer else { return }
        strip.model.isLoading = true
        strip.model.message = nil
        Task {
            do {
                strip.model.items = try await library.alternatives(for: dancer.gif)
            } catch {
                strip.model.items = []
                strip.model.message = error.localizedDescription
            }
            strip.model.isLoading = false
        }
    }

    private func closeStrip(restoreFocus: Bool) {
        guard let current = strip else { return }
        strip = nil
        current.close()
        if restoreFocus, let app = appBeforeStrip { app.activate() }
        appBeforeStrip = nil
    }

    func swapStripDidClose(_ closed: SwapStrip) {
        hoverTask?.cancel()
        closed.dancer?.setPreview(nil)
        if strip === closed { strip = nil }
    }

    func swapStrip(_ strip: SwapStrip, hovered item: PickerItem?) {
        hoverTask?.cancel()
        guard let dancer = strip.dancer else { return }
        guard let item else { return dancer.setPreview(nil) }
        hoverTask = Task {
            guard let gif = try? await loadFull(item), !Task.isCancelled else { return }
            dancer.setPreview(gif, speedBias: library.speedBias(for: gif.source), beatShift: library.beatShift(for: gif.source))
        }
    }

    func swapStrip(_ strip: SwapStrip, picked item: PickerItem) {
        guard let dancer = strip.dancer else { return }
        hoverTask?.cancel()
        strip.model.busyID = item.id
        Task {
            defer { strip.model.busyID = nil }
            do {
                commit(try await loadFull(item), to: dancer)
                closeStrip(restoreFocus: true)
            } catch {
                strip.model.message = error.localizedDescription
            }
        }
    }

    func swapStrip(_ strip: SwapStrip, perform action: StripAction) {
        guard let dancer = strip.dancer else { return }
        switch action {
        case .slower: dancer.halveSpeed()
        case .faster: dancer.doubleSpeed()
        case .shiftHalfBeat: dancer.shiftHalfBeat()
        case .keep:
            guard !strip.model.kept else { return }
            dancerWantsToBeKept(dancer)
            strip.model.kept = true
        case .remove: dancerWantsRemoval(dancer)
        case .refresh: loadAlternatives(for: strip)
        }
    }
}
