import Foundation

/// Smooth, continuous beat position driven by periodic `BeatEstimate`s.
///
/// Estimates arrive twice a second and jitter a little; the clock nudges its tempo and
/// phase toward them instead of jumping, so the dancers don't stutter.
public final class BeatClock {
    public private(set) var period: Double = 0.5
    /// Time at which beat position is 0.
    private var anchor: Double = 0
    private var lastConfidentUpdate: Double = -.infinity

    /// Seconds to delay the dancers relative to the detected beat (covers output latency).
    public var offset: Double = 0
    /// Keep dancing at the last tempo this long after confidence drops.
    public var holdSeconds = 4.0
    public var minConfidence = 0.15

    public init() {}

    public var bpm: Double { 60 / period }

    public func isLocked(at t: Double) -> Bool { t - lastConfidentUpdate < holdSeconds }

    public func beatPosition(at t: Double) -> Double { (t - offset - anchor) / period }

    public func update(_ e: BeatEstimate, now: Double) {
        guard e.confidence >= minConfidence else { return }
        let wasLocked = isLocked(at: now)
        lastConfidentUpdate = now

        if !wasLocked || abs(e.period / period - 1) > 0.08 {
            period = e.period
            anchor = e.beatTime
            return
        }

        // Ease the tempo toward the estimate while keeping the current position continuous.
        let position = beatPosition(at: now)
        let newPeriod = period + 0.25 * (e.period - period)
        anchor = (now - offset) - position * newPeriod
        period = newPeriod

        // Pull the phase part of the way toward the estimated beat.
        let p = (e.beatTime - anchor) / period
        anchor += 0.3 * (p - p.rounded()) * period
    }
}
