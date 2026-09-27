import Foundation

/// Synthetic test audio: a kick-like click on every beat, optionally with off-beat hats.
public enum ClickTrack {
    public static func make(bpm: Double, seconds: Double, sampleRate: Double = 48_000,
                            startOffset: Double = 0, offbeats: Bool = true, bars: Bool = false) -> [Float] {
        let count = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: count)
        let period = 60 / bpm
        var rng = SystemRandomNumberGenerator()
        var beat = 0
        while true {
            let t = startOffset + Double(beat) * period
            let start = Int(t * sampleRate)
            if start >= count { break }
            // Kick: decaying 60 Hz sine.
            for i in 0..<Int(0.15 * sampleRate) where start + i < count {
                let s = Double(i) / sampleRate
                out[start + i] += Float(0.8 * sin(2 * .pi * 60 * s) * exp(-s * 30))
                // Beater click so the kick isn't pure sub-bass.
                if i < Int(0.004 * sampleRate) {
                    out[start + i] += Float.random(in: -0.15...0.15, using: &rng)
                }
            }
            if bars && beat % 4 == 0 {
                // Bar start: a louder kick and a chord change (two chords alternating by bar).
                for i in 0..<Int(0.15 * sampleRate) where start + i < count {
                    let t = Double(i) / sampleRate
                    out[start + i] += Float(0.4 * sin(2 * .pi * 60 * t) * exp(-t * 30))
                }
                let chord: [Double] = (beat / 4) % 2 == 0 ? [261.6, 329.6, 392.0] : [220.0, 277.2, 329.6]
                let barLength = Int(4 * period * sampleRate)
                for i in 0..<barLength where start + i < count {
                    let t = Double(i) / sampleRate
                    out[start + i] += Float(chord.reduce(0) { $0 + 0.05 * sin(2 * .pi * $1 * t) })
                }
            }
            if offbeats {
                let hat = Int((t + period / 2) * sampleRate)
                for i in 0..<Int(0.03 * sampleRate) where hat + i < count && hat + i >= 0 {
                    let s = Double(i) / sampleRate
                    out[hat + i] += Float.random(in: -0.2...0.2, using: &rng) * Float(exp(-s * 150))
                }
            }
            beat += 1
        }
        return out
    }
}
