import AppKit
import SwiftUI

enum StripAction {
    case slower, faster, shiftHalfBeat, keep, remove, refresh
}

@MainActor
protocol SwapStripDelegate: AnyObject {
    func swapStrip(_ strip: SwapStrip, hovered item: PickerItem?)
    func swapStrip(_ strip: SwapStrip, picked item: PickerItem)
    func swapStrip(_ strip: SwapStrip, perform action: StripAction)
    func swapStripDidClose(_ strip: SwapStrip)
}

@MainActor
final class StripModel: ObservableObject {
    @Published var items: [PickerItem] = []
    @Published var isLoading = true
    @Published var busyID: String?
    @Published var canKeep = false
    @Published var kept = false
    @Published var message: String?
    private var hoveredID: String?
    weak var strip: SwapStrip?

    func hover(_ item: PickerItem, inside: Bool) {
        guard let strip else { return }
        if inside {
            hoveredID = item.id
            strip.stripDelegate?.swapStrip(strip, hovered: item)
        } else if hoveredID == item.id {
            hoveredID = nil
            strip.stripDelegate?.swapStrip(strip, hovered: nil)
        }
    }

    func pick(_ item: PickerItem) {
        guard let strip else { return }
        strip.stripDelegate?.swapStrip(strip, picked: item)
    }

    func perform(_ action: StripAction) {
        guard let strip else { return }
        strip.stripDelegate?.swapStrip(strip, perform: action)
    }
}

/// Floating row of alternatives and quick controls that opens under a clicked dancer.
@MainActor
final class SwapStrip: NSPanel {
    let model = StripModel()
    weak var dancer: DancerWindow?
    weak var stripDelegate: SwapStripDelegate?

    init(dancer: DancerWindow) {
        self.dancer = dancer
        super.init(contentRect: NSRect(x: 0, y: 0, width: 318, height: 112),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: StripView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            host.topAnchor.constraint(equalTo: background.topAnchor),
            host.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
        model.strip = self
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        super.close()
        stripDelegate?.swapStripDidClose(self)
    }

    /// Place under the dancer, or above it when there's no room below.
    func position() {
        guard let dancer, let screen = dancer.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = frame.size
        var origin = NSPoint(x: dancer.frame.midX - size.width / 2, y: dancer.frame.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = dancer.frame.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        setFrameOrigin(origin)
    }
}

private struct StripView: View {
    @ObservedObject var model: StripModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                if model.isLoading {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)).frame(width: 64, height: 64)
                    }
                } else if model.items.isEmpty {
                    Text(model.message ?? "No alternatives found.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 271, height: 64)
                } else {
                    ForEach(model.items) { item in
                        PickerTile(item: item, isBusy: model.busyID == item.id, badge: nil,
                                   onHover: { model.hover(item, inside: $0) }) { model.pick(item) }
                            .frame(width: 64, height: 64)
                    }
                }
                Button { model.perform(.refresh) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("More like this")
            }
            HStack(spacing: 5) {
                Button("½×") { model.perform(.slower) }.help("Half speed")
                Button("2×") { model.perform(.faster) }.help("Double speed")
                Button("½ beat") { model.perform(.shiftHalfBeat) }.help("Shift the dance by half a beat")
                if model.canKeep {
                    Button { model.perform(.keep) } label: { Image(systemName: model.kept ? "heart.fill" : "heart") }
                        .help("Keep in my folder")
                }
                Button { model.perform(.remove) } label: { Image(systemName: "trash") }.help("Remove dancer")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(width: 318, height: 112)
    }
}
