import DancefloorCore
import Testing

@Suite struct LoopFitTests {
    @Test(arguments: [0.3, 0.8, 1.5, 2.0, 3.7, 6.0], [70.0, 100, 128, 150, 174])
    func staysNearNativeSpeed(duration: Double, bpm: Double) {
        let period = 60 / bpm
        let beats = LoopFit.beatsPerLoop(nativeDuration: duration, beatPeriod: period)
        let speed = LoopFit.speed(nativeDuration: duration, beatPeriod: period, beatsPerLoop: beats)
        #expect(speed >= 0.7 && speed <= 1.42, "duration \(duration)s at \(bpm) BPM plays at \(speed)x")
    }

    @Test func slowGrooveOnFastTrackSpansMoreBeats() {
        // A 2 s loop: 4 beats at 120 BPM, but 8 beats at 240-ish double-time readings.
        #expect(LoopFit.beatsPerLoop(nativeDuration: 2, beatPeriod: 60.0 / 120) == 4)
        #expect(LoopFit.beatsPerLoop(nativeDuration: 2, beatPeriod: 60.0 / 240) == 8)
    }

    @Test func holdsCurrentChoiceNearBoundary() {
        // 2 s at 85 BPM: ideal 2.83 beats, right between 2 and 4.
        let period = 60.0 / 85
        #expect(LoopFit.beatsPerLoop(nativeDuration: 2, beatPeriod: period, current: 2) == 2)
        #expect(LoopFit.beatsPerLoop(nativeDuration: 2, beatPeriod: period, current: 4) == 4)
    }
}
