import Foundation

/// Chooses how many beats one GIF loop spans at the current tempo.
///
/// Loops always span a power-of-two number of beats so moves line up with bars, and the
/// choice keeps playback within about 1.4x of the GIF's own speed: a slow groove on a fast
/// track spans more beats instead of playing frantically.
public enum LoopFit {
    public static let choices: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 32]

    /// Keeps `current` unless another choice is clearly closer, so a tempo sitting near a
    /// boundary doesn't make the dancer flip between speeds.
    public static func beatsPerLoop(nativeDuration: Double, beatPeriod: Double, current: Double? = nil) -> Double {
        let ideal = nativeDuration / beatPeriod
        func cost(_ beats: Double) -> Double { abs(log2(beats / ideal)) }
        let best = choices.min { cost($0) < cost($1) }!
        if let current, choices.contains(current), cost(current) < cost(best) + 0.15 { return current }
        return best
    }

    /// Playback speed relative to the GIF's own timing (1 = unchanged).
    public static func speed(nativeDuration: Double, beatPeriod: Double, beatsPerLoop: Double) -> Double {
        nativeDuration / (beatsPerLoop * beatPeriod)
    }
}
