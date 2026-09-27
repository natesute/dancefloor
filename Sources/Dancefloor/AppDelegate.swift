import AppKit
import CoreAudio
import DancefloorCore
import QuartzCore
import os

private let log = Logger(subsystem: "com.natesute.dancefloor", category: "app")

private struct SavedDancer: Codable {
    let source: GifSource
    let title: String
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, DancerWindowDelegate {
    private let library = GifLibrary()
    private let clock = BeatClock()
    private let tap = SystemAudioTap()
    private let analyzer = Analyzer()
    private var statusItem: NSStatusItem!
    private var dancers: [DancerWindow] = []
    private var displayLink: CADisplayLink?
    private var audioError: String?
    private var lastEstimate: BeatEstimate?

    private var syncOffset: Double {
        get { UserDefaults.standard.object(forKey: "syncOffset") as? Double ?? 0.05 }
        set { UserDefaults.standard.set(newValue, forKey: "syncOffset"); clock.offset = newValue }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        clock.offset = syncOffset

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🕺"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        analyzer.onEstimate = { [weak self] estimate in self?.handle(estimate) }
        tap.onAudio = { [analyzer] samples, sampleRate, time in
            analyzer.feed(samples, sampleRate: sampleRate, time: time)
        }
        startAudio()
        watchDefaultOutputDevice()

        let link = NSScreen.main?.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        displayLink = link

        restoreDancers()
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
        let now = CACurrentMediaTime()
        lastEstimate = estimate
        if let e = estimate {
            log.info("Beat \(e.bpm, format: .fixed(precision: 2)) BPM, confidence \(e.confidence, format: .fixed(precision: 2))")
        }
        if let estimate { clock.update(estimate, now: now) }
        let locked = clock.isLocked(at: now)
        statusItem.button?.title = locked ? "🕺 \(Int(clock.bpm.rounded()))" : "🕺"
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let beat = clock.isLocked(at: now) ? clock.beatPosition(at: now) : nil
        for dancer in dancers { dancer.tick(beat: beat, now: now) }
    }

    // MARK: - Dancers

    private func addDancer(_ gif: LoadedGif, height: CGFloat = 220, center: NSPoint? = nil) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let point = center ?? NSPoint(
            x: .random(in: visible.minX + 150...max(visible.minX + 151, visible.maxX - 150)),
            y: .random(in: visible.minY + 150...max(visible.minY + 151, visible.maxY - 150)))
        let dancer = DancerWindow(gif: gif, beatsPerLoop: library.beatsPerLoop(for: gif),
                                  beatShift: library.beatShift(for: gif.source), height: height, center: point)
        dancer.dancerDelegate = self
        dancer.orderFrontRegardless()
        dancers.append(dancer)
        saveDancers()
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { self.showError(error) }
        }
    }

    @objc private func addRandomDancer() {
        run { self.addDancer(try await self.library.random()) }
    }

    @objc private func searchGiphy() {
        guard library.giphyKey != nil else { return promptForKey() }
        guard let query = prompt(title: "Search GIPHY stickers", message: "Adds a random match, e.g. \"shrek\", \"dancing cat\".",
                                 placeholder: "dancing") else { return }
        run { self.addDancer(try await self.library.search(query)) }
    }

    @objc private func randomiseAll() {
        if dancers.isEmpty { return addRandomDancer() }
        for dancer in dancers { dancerWantsNewGif(dancer) }
    }

    @objc private func removeAll() {
        for dancer in dancers { dancer.close() }
        dancers.removeAll()
        saveDancers()
    }

    func dancerWantsNewGif(_ dancer: DancerWindow) {
        guard !dancer.isLoading else { return }
        dancer.isLoading = true
        run {
            defer { dancer.isLoading = false }
            let gif = try await self.library.random(excluding: dancer.gif.source)
            dancer.replaceGif(gif, beatsPerLoop: self.library.beatsPerLoop(for: gif),
                              beatShift: self.library.beatShift(for: gif.source))
            self.saveDancers()
        }
    }

    func dancerWantsToBeKept(_ dancer: DancerWindow) {
        do { try library.keep(dancer.gif) } catch { showError(error) }
    }

    func dancerDidChangeTuning(_ dancer: DancerWindow) {
        library.setBeatsPerLoop(dancer.beatsPerLoop, for: dancer.gif.source)
        library.setBeatShift(dancer.beatShift, for: dancer.gif.source)
    }

    func dancerDidMove(_ dancer: DancerWindow) { saveDancers() }

    func dancerWantsRemoval(_ dancer: DancerWindow) {
        dancer.close()
        dancers.removeAll { $0 === dancer }
        saveDancers()
    }

    private func saveDancers() {
        let saved = dancers.map {
            SavedDancer(source: $0.gif.source, title: $0.gif.title, x: $0.center.x, y: $0.center.y, height: $0.dancerHeight)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: "dancers")
    }

    private func restoreDancers() {
        guard let data = UserDefaults.standard.data(forKey: "dancers"),
              let saved = try? JSONDecoder().decode([SavedDancer].self, from: data), !saved.isEmpty else {
            // Nothing saved: start with one dancer so there's something to see.
            return addRandomDancer()
        }
        Task { @MainActor in
            for s in saved {
                guard let gif = try? await library.load(s.source, title: s.title) else { continue }
                addDancer(gif, height: s.height, center: NSPoint(x: s.x, y: s.y))
            }
            if dancers.isEmpty { addRandomDancer() }
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if let audioError {
            status = "Can't hear audio: \(audioError)"
        } else if clock.isLocked(at: CACurrentMediaTime()) {
            status = "Dancing at \(Int(clock.bpm.rounded())) BPM"
        } else {
            status = "Waiting for music…"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        menu.addItem(item("Add Dancer", #selector(addRandomDancer), key: "n"))
        menu.addItem(item("Search GIPHY…", #selector(searchGiphy), key: "f"))
        menu.addItem(item("Randomise All", #selector(randomiseAll), key: "r"))
        menu.addItem(.separator())

        let source = NSMenuItem(title: "Dancers From", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for mode in SourceMode.allCases {
            let i = item(mode.title, #selector(setSourceMode(_:)))
            i.representedObject = mode.rawValue
            i.state = library.mode == mode ? .on : .off
            sourceMenu.addItem(i)
        }
        source.submenu = sourceMenu
        menu.addItem(source)
        menu.addItem(item("Edit Random Search Terms…", #selector(editRandomTerms)))
        menu.addItem(item(library.giphyKey == nil ? "Set GIPHY API Key…" : "Change GIPHY API Key…", #selector(promptForKey)))
        menu.addItem(item("Open My GIF Folder", #selector(openFolder)))
        menu.addItem(.separator())

        let sync = NSMenuItem(title: "Sync (\(Int((syncOffset * 1000).rounded())) ms)", action: nil, keyEquivalent: "")
        let syncMenu = NSMenu()
        syncMenu.addItem(item("Dancers Earlier (−20 ms)", #selector(syncEarlier)))
        syncMenu.addItem(item("Dancers Later (+20 ms)", #selector(syncLater)))
        syncMenu.addItem(item("Reset", #selector(syncReset)))
        sync.submenu = syncMenu
        menu.addItem(sync)
        if audioError != nil { menu.addItem(item("Retry Audio", #selector(retryAudio))) }
        menu.addItem(.separator())

        menu.addItem(item("Remove All Dancers", #selector(removeAll)))
        menu.addItem(item("Quit Dancefloor", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = target ?? self
        return i
    }

    @objc private func setSourceMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = SourceMode(rawValue: raw) { library.mode = mode }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(library.folder) }
    @objc private func syncEarlier() { syncOffset -= 0.02 }
    @objc private func syncLater() { syncOffset += 0.02 }
    @objc private func syncReset() { syncOffset = 0.05 }
    @objc private func retryAudio() { startAudio() }

    @objc private func promptForKey() {
        guard let key = prompt(title: "GIPHY API key",
                               message: "Create a free app at developers.giphy.com and paste its API key here.",
                               placeholder: "API key", initial: library.giphyKey ?? "") else { return }
        library.giphyKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func editRandomTerms() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Random search terms"
        alert.informativeText = "One per line. Add Dancer and Randomise pick one of these at random and search GIPHY for it. Clear everything to restore the defaults."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.string = library.randomTerms.joined(separator: "\n")
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.isAutomaticQuoteSubstitutionEnabled = false
        alert.accessoryView = scroll
        alert.window.initialFirstResponder = text

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.randomTerms = text.string.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Alerts

    private func prompt(title: String, message: String, placeholder: String, initial: String = "") -> String? {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private func showError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Dancefloor"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
