import AppKit
import DancefloorCore
import SwiftUI

/// Small decoded previews, shared by the popover grid and the swap strip.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: GIFAnimation] = [:]
    private var inFlight: [URL: Task<GIFAnimation?, Never>] = [:]

    func animation(for url: URL) async -> GIFAnimation? {
        if let hit = cache[url] { return hit }
        if let task = inFlight[url] { return await task.value }
        let task = Task<GIFAnimation?, Never> {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await URLSession.shared.data(from: url).0
            }
            return data.flatMap { GIFAnimation(data: $0, maxPixelSize: 200) }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        if cache.count > 300 { cache.removeAll() }
        cache[url] = result
        return result
    }
}

/// Plays a GIF at its own speed with a Core Animation keyframe animation (no per-frame work).
final class GIFLayerView: NSView {
    var animation: GIFAnimation? {
        didSet { if oldValue !== animation { apply() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    private func apply() {
        guard let layer else { return }
        layer.removeAllAnimations()
        guard let animation, let first = animation.frames.first else {
            layer.contents = nil
            return
        }
        layer.contents = first
        guard animation.frames.count > 1 else { return }
        let keyframes = CAKeyframeAnimation(keyPath: "contents")
        keyframes.values = animation.frames
        keyframes.keyTimes = (animation.frameStarts + [1]).map { NSNumber(value: $0) }
        keyframes.calculationMode = .discrete
        keyframes.duration = animation.duration
        keyframes.repeatCount = .infinity
        keyframes.isRemovedOnCompletion = false
        layer.add(keyframes, forKey: "gif")
    }
}

struct GIFThumbnail: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var url: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> GIFLayerView { GIFLayerView() }

    func updateNSView(_ view: GIFLayerView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        view.animation = nil
        let url = url
        Task { @MainActor in
            let animation = await ThumbnailCache.shared.animation(for: url)
            if context.coordinator.url == url { view.animation = animation }
        }
    }
}

/// A square tile with a hover ring and a small + badge.
struct PickerTile: View {
    let item: PickerItem
    var isBusy = false
    var badge: String? = "plus"
    var onHover: ((Bool) -> Void)?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
            GIFThumbnail(url: item.previewURL).padding(2)
            if isBusy {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hovering, let badge {
                Image(systemName: badge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.accentColor))
                    .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: hovering ? 2 : 0))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            onHover?(inside)
        }
        .onTapGesture(perform: action)
        .help(item.title)
    }
}
