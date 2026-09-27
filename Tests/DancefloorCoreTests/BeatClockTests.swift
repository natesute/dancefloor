import DancefloorCore
import Testing

@Suite struct BeatClockTests {
    /// Estimates every half second at 120 BPM, with bar starts on beats 2, 6, 10… but one
    /// guess in three pointing somewhere else.
    @Test func settlesOnMajorityBarStartDespiteNoise() {
        let clock = BeatClock()
        let period = 0.5
        for step in 0..<40 {
            let now = Double(step) * 0.5 + 10
            let beat = (now / period).rounded(.down) * period
            let truth = 2 * period + ((beat - 2 * period) / (4 * period)).rounded(.down) * 4 * period
            let wrong = step % 3 == 0
            let downbeat = wrong ? truth + Double(step % 4 == 0 ? 1 : 3) * period : truth
            clock.update(BeatEstimate(bpm: 120, beatTime: beat, confidence: 0.8,
                                      downbeatTime: downbeat, downbeatConfidence: 0.6), now: now)
        }
        // Downbeats at 2, 6, 10… beats from t=0 → a bar-relative position that's a whole bar.
        let t = 2 * period + 40 * period
        let barPos = clock.barBeatPosition(at: t + clock.offset)
        let remainder = barPos.truncatingRemainder(dividingBy: 4)
        #expect(abs(remainder) < 0.05 || abs(remainder - 4) < 0.05, "bar position \(barPos)")
    }
}
