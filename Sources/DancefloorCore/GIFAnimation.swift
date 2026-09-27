import CoreGraphics
import Foundation
import ImageIO

/// Decoded GIF frames plus the timing needed to map "progress through the loop" to a frame.
public final class GIFAnimation {
    public let frames: [CGImage]
    /// Start of each frame as a fraction (0..<1) of the whole loop.
    public let frameStarts: [Double]
    /// Native loop length in seconds.
    public let duration: Double
    public let pixelSize: CGSize

    public init?(data: Data, maxPixelSize: Int = 480) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        var frames: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            frames.append(image)
            delays.append(Self.delay(source: source, index: i))
        }
        guard let first = frames.first else { return nil }

        let total = delays.reduce(0, +)
        var starts: [Double] = []
        var t = 0.0
        for d in delays {
            starts.append(t / total)
            t += d
        }
        self.frames = frames
        self.frameStarts = starts
        self.duration = total
        self.pixelSize = CGSize(width: first.width, height: first.height)
    }

    /// Frame to show at `progress` (0..<1) through the loop.
    public func frameIndex(progress: Double) -> Int {
        let p = progress - progress.rounded(.down)
        var lo = 0
        var hi = frameStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frameStarts[mid] <= p { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func delay(source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        // Browsers treat tiny delays as 0.1s; match them so GIFs look the way people expect.
        return d < 0.02 ? 0.1 : d
    }
}
