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

    /// Beat position (mod 4) that starts a bar, decided by a decaying vote over estimates so a
    /// few wrong guesses don't make the dancers jump.
    public private(set) var barOffset = 0
    private var barVotes = [Double](repeating: 0, count: 4)

    public init() {}

    public var bpm: Double { 60 / period }

    public func isLocked(at t: Double) -> Bool { t - lastConfidentUpdate < holdSeconds }

    public func beatPosition(at t: Double) -> Double { (t - offset - anchor) / period }

    /// Beat position counted from the start of a bar, so whole multiples of 4 are downbeats.
    public func barBeatPosition(at t: Double) -> Double { beatPosition(at: t) - Double(barOffset) }

    public func update(_ e: BeatEstimate, now: Double) {
        guard e.confidence >= minConfidence else { return }
        let wasLocked = isLocked(at: now)
        lastConfidentUpdate = now

        if !wasLocked || abs(e.period / period - 1) > 0.08 {
            period = e.period
            anchor = e.beatTime
            // Beat numbering restarts, so earlier bar votes no longer mean anything.
            barOffset = 0
            barVotes = [0, 0, 0, 0]
            voteForBar(e)
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
        voteForBar(e)
    }

    private func voteForBar(_ e: BeatEstimate) {
        guard let downbeat = e.downbeatTime, e.downbeatConfidence >= 0.2 else { return }
        let slot = ((Int(((downbeat - anchor) / period).rounded()) % 4) + 4) % 4
        for i in 0..<4 { barVotes[i] *= 0.93 }
        barVotes[slot] += min(e.downbeatConfidence, 2)
        let best = barVotes.indices.max { barVotes[$0] < barVotes[$1] }!
        if best != barOffset, barVotes[best] > barVotes[barOffset] * 1.5 + 1 { barOffset = best }
    }
}
