import DancefloorCore
import Testing

@Suite struct BeatTrackerTests {
    @Test(arguments: [90.0, 100, 120, 128, 140, 174])
    func findsTempoOfClickTrack(bpm: Double) {
        let sr = 48_000.0
        let audio = ClickTrack.make(bpm: bpm, seconds: 12, sampleRate: sr, startOffset: 0.137)
        let tracker = BeatTracker(sampleRate: sr)
        for start in stride(from: 0, to: audio.count, by: 512) {
            let end = min(start + 512, audio.count)
            _ = tracker.process(Array(audio[start..<end]), time: Double(start) / sr)
        }
        let e = try! #require(tracker.estimate)
        // Very fast tempos may lock to half-time, which is how people dance to them anyway.
        let target = bpm > 160 && abs(e.bpm - bpm / 2) < 1.5 ? bpm / 2 : bpm
        #expect(abs(e.bpm - target) < 1.5, "got \(e.bpm)")

        // The reported beat time should sit on the click grid (within 25 ms).
        let period = 60 / target
        let offset = (e.beatTime - 0.137).truncatingRemainder(dividingBy: period)
        let err = min(abs(offset), abs(period - abs(offset)))
        #expect(err < 0.025, "phase error \(err)s")
    }

    @Test func silenceGivesNoEstimate() {
        let tracker = BeatTracker(sampleRate: 48_000)
        let zeros = [Float](repeating: 0, count: 48_000 * 6)
        _ = tracker.process(zeros, time: 0)
        #expect(tracker.estimate == nil)
    }
}

@Suite struct DownbeatTests {
    @Test(arguments: [100.0, 124, 140])
    func findsBarStartsOnAccentedTrack(bpm: Double) {
        let sr = 48_000.0
        let start = 0.21
        let audio = ClickTrack.make(bpm: bpm, seconds: 20, sampleRate: sr, startOffset: start, bars: true)
        let tracker = BeatTracker(sampleRate: sr)
        for i in stride(from: 0, to: audio.count, by: 512) {
            _ = tracker.process(Array(audio[i..<min(i + 512, audio.count)]), time: Double(i) / sr)
        }
        let e = try! #require(tracker.estimate)
        let downbeat = try! #require(e.downbeatTime)
        let bar = 4 * 60 / bpm
        let offset = (downbeat - start).truncatingRemainder(dividingBy: bar)
        let err = min(abs(offset), abs(bar - abs(offset)))
        #expect(err < 0.03, "downbeat off by \(err)s (confidence \(e.downbeatConfidence))")
    }
}
