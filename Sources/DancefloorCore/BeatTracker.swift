import Accelerate
import Foundation

public struct BeatEstimate: Sendable, Equatable {
    /// Beats per minute.
    public var bpm: Double
    /// A time (seconds, same clock as the input timestamps) at which a beat lands.
    public var beatTime: Double
    /// 0...1, how strongly periodic the recent audio is.
    public var confidence: Double
    /// A time at which a bar starts (beat 1 of 4), when there's enough history to guess.
    public var downbeatTime: Double?
    /// How much more the chosen bar position stood out than the runner-up (0 = a coin toss).
    public var downbeatConfidence: Double = 0

    public init(bpm: Double, beatTime: Double, confidence: Double, downbeatTime: Double? = nil, downbeatConfidence: Double = 0) {
        self.bpm = bpm
        self.beatTime = beatTime
        self.confidence = confidence
        self.downbeatTime = downbeatTime
        self.downbeatConfidence = downbeatConfidence
    }

    public var period: Double { 60 / bpm }
}

/// Streaming tempo and beat-phase tracker.
///
/// Mono samples go in with a timestamp; every half second it re-estimates tempo from the
/// autocorrelation of a spectral-flux onset envelope, then finds the beat phase by
/// sliding a pulse train over the most recent onsets. Bar starts come from comparing the four
/// possible positions of beat 1 over the last few bars: downbeats tend to carry the strongest
/// kick and the chord changes.
public final class BeatTracker {
    public let sampleRate: Double
    public let minBPM: Double
    public let maxBPM: Double

    private let fftSize = 1024
    private let hop = 512
    private let log2n: vDSP_Length = 10
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    private var pending: [Float] = []
    private var pendingStartTime: Double = 0
    private var prevLogMag: [Float]
    private var onsets: [Float] = []
    private var lowOnsets: [Float] = []
    private var energies: [Float] = []
    /// 12-bin pitch-class energy per frame, for spotting chord changes.
    private var chroma: [[Float]] = []
    private let pitchClassOfBin: [Int]
    private let tempoFrames: Int
    private var lastFrameTime: Double = 0
    private let onsetCapacity: Int
    private var framesSinceAnalysis = 0

    public private(set) var estimate: BeatEstimate?
    /// How much the kick band counts relative to broadband onsets when finding phase.
    public var lowBandWeight: Float = 1

    public var frameRate: Double { sampleRate / Double(hop) }

    public init(sampleRate: Double, minBPM: Double = 70, maxBPM: Double = 180, historySeconds: Double = 8) {
        self.sampleRate = sampleRate
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        prevLogMag = [Float](repeating: 0, count: fftSize / 2)
        tempoFrames = Int(historySeconds * sampleRate / Double(hop))
        // Bar detection wants more bars of history than tempo does.
        onsetCapacity = max(tempoFrames, Int(16 * sampleRate / Double(hop)))
        let binHz = sampleRate / Double(fftSize)
        pitchClassOfBin = (0..<fftSize / 2).map { i in
            let f = Double(i) * binHz
            guard f >= 110, f <= 3520 else { return -1 }
            let semis = Int((12 * log2(f / 440)).rounded())
            return ((semis % 12) + 12) % 12
        }
    }

    /// Feed mono samples. `time` is the timestamp of `samples[0]`.
    /// Returns true when a new estimate was produced.
    @discardableResult
    public func process(_ samples: UnsafeBufferPointer<Float>, time: Double) -> Bool {
        pendingStartTime = time - Double(pending.count) / sampleRate
        pending.append(contentsOf: samples)
        var updated = false
        while pending.count >= fftSize {
            let frameTime = pendingStartTime + Double(fftSize / 2) / sampleRate
            analyseFrame(time: frameTime)
            pending.removeFirst(hop)
            pendingStartTime += Double(hop) / sampleRate
            framesSinceAnalysis += 1
            if framesSinceAnalysis >= Int(frameRate / 2), onsets.count >= Int(frameRate * 4) {
                framesSinceAnalysis = 0
                estimate = analyse()
                updated = true
            }
        }
        return updated
    }

    public func process(_ samples: [Float], time: Double) -> Bool {
        samples.withUnsafeBufferPointer { process($0, time: time) }
    }

    public func reset() {
        pending.removeAll()
        onsets.removeAll()
        lowOnsets.removeAll()
        energies.removeAll()
        chroma.removeAll()
        estimate = nil
        prevLogMag = [Float](repeating: 0, count: fftSize / 2)
    }

    // MARK: - Onset envelope

    private func analyseFrame(time: Double) {
        let frame = vDSP.multiply(pending[0..<fftSize], window)
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        // Log-compressed magnitude, then half-wave rectified difference (spectral flux).
        var logMag = vDSP.multiply(Float(1) / Float(fftSize), mags)
        logMag = logMag.map { log1pf(1000 * $0) }
        // Broadband flux drives tempo. A separate low-band flux (under ~250 Hz) is kept for
        // phase, because kicks sit on the beat while hats and snares often don't.
        let lowBins = max(2, Int(250 / (sampleRate / Double(fftSize))))
        var low: Float = 0
        var full: Float = 0
        for i in 1..<half {
            let d = max(0, logMag[i] - prevLogMag[i])
            full += d
            if i <= lowBins { low += d }
        }
        prevLogMag = logMag

        var pitch = [Float](repeating: 0, count: 12)
        for i in 1..<half where pitchClassOfBin[i] >= 0 { pitch[pitchClassOfBin[i]] += mags[i] * mags[i] }

        onsets.append(full / Float(half - 1))
        lowOnsets.append(low / Float(lowBins))
        energies.append(vDSP.rootMeanSquare(frame))
        chroma.append(pitch)
        if onsets.count > onsetCapacity {
            let excess = onsets.count - onsetCapacity
            onsets.removeFirst(excess)
            lowOnsets.removeFirst(excess)
            energies.removeFirst(excess)
            chroma.removeFirst(excess)
        }
        lastFrameTime = time
    }

    // MARK: - Tempo and phase

    private func analyse() -> BeatEstimate? {
        let fr = frameRate

        // Silence gate: nothing to dance to.
        let recentEnergy = energies.suffix(Int(fr * 2)).reduce(0, +) / Float(min(energies.count, Int(fr * 2)))
        if recentEnergy < 1e-4 { return nil }

        // Tempo and phase use the most recent `historySeconds`; bars use the full buffer.
        let offset = max(0, onsets.count - tempoFrames)
        let n = onsets.count - offset
        let env = Self.highPass(Array(onsets[offset...]), smoothLen: max(3, Int(fr * 0.25)))

        // Autocorrelation over the lag range we care about (plus multiples for the comb).
        let maxLag = min(n - 1, Int(60 * fr / minBPM * 4) + 2)
        var ac = [Float](repeating: 0, count: maxLag + 1)
        env.withUnsafeBufferPointer { e in
            for lag in 0...maxLag {
                var s: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &s, vDSP_Length(n - lag))
                ac[lag] = s / Float(n - lag)
            }
        }
        guard ac[0] > 0 else { return nil }

        func acAt(_ lag: Double) -> Float {
            let i = Int(lag)
            guard i + 1 < ac.count else { return 0 }
            let f = Float(lag - Double(i))
            return ac[i] * (1 - f) + ac[i + 1] * f
        }

        // Score candidate tempos with a comb over lag multiples and a log-normal prior at 120 BPM.
        var bestBPM = 0.0
        var bestScore = -Float.infinity
        var bpm = minBPM
        while bpm <= maxBPM {
            let lag = 60 * fr / bpm
            var score: Float = 0
            var weights: Float = 0
            for k in 1...4 {
                let l = lag * Double(k)
                if Int(l) + 1 >= ac.count { break }
                score += acAt(l)
                weights += 1
            }
            score /= max(weights, 1)
            // Real tempos usually have activity on the half beat too; 2:3 mislocks don't.
            score += 0.5 * acAt(lag / 2)
            let octaves = log2(bpm / 120)
            score *= Float(exp(-0.5 * pow(octaves / 0.9, 2)))
            if score > bestScore {
                bestScore = score
                bestBPM = bpm
            }
            bpm += 0.25
        }
        let period = 60 * fr / bestBPM
        let confidence = Double(max(0, min(1, acAt(period) / ac[0])))

        // Phase: slide a decaying pulse train back from the newest frame, over a blend of
        // broadband and kick-band onsets (each scaled to unit peak).
        let low = Self.highPass(Array(lowOnsets[offset...]), smoothLen: max(3, Int(fr * 0.25)))
        let envPeak = max(vDSP.maximum(env), 1e-9)
        let lowPeak = max(vDSP.maximum(low), 1e-9)
        let phaseEnv = zip(env, low).map { $0 / envPeak + lowBandWeight * $1 / lowPeak }

        let beatsBack = min(8, Int(Double(n) / period) - 1)
        var bestPhase = 0.0
        var bestPhaseScore = -Float.infinity
        var phase = 0.0
        while phase < period {
            var s: Float = 0
            for k in 0..<beatsBack {
                let pos = Double(n - 1) - phase - Double(k) * period
                let i = Int(pos.rounded())
                guard i >= 1, i + 1 < n else { continue }
                // Take the local max so we're robust to a frame of jitter.
                let v = max(phaseEnv[i - 1], phaseEnv[i], phaseEnv[i + 1])
                s += v * Float(pow(0.85, Double(k)))
            }
            if s > bestPhaseScore {
                bestPhaseScore = s
                bestPhase = phase
            }
            phase += 0.5
        }
        let beatTime = lastFrameTime - bestPhase / fr

        var result = BeatEstimate(bpm: bestBPM, beatTime: beatTime, confidence: confidence)
        if let (barPhase, barConfidence) = findBarPhase(lastBeatFrame: Double(onsets.count - 1) - bestPhase, period: period) {
            result.downbeatTime = beatTime - Double(barPhase) * 60 / bestBPM
            result.downbeatConfidence = barConfidence
        }
        return result
    }

    /// Which of the last four beats started a bar, as beats back from the newest beat (0...3),
    /// judged over every whole bar in the buffer. Frame indices here are into the full buffer.
    private func findBarPhase(lastBeatFrame: Double, period: Double) -> (Int, Double)? {
        let total = onsets.count
        // Beat frames, newest first.
        var beats: [Int] = []
        var f = lastBeatFrame
        while f - period >= 2 {
            beats.append(Int(f.rounded()))
            f -= period
        }
        guard beats.count >= 12 else { return nil } // three bars minimum

        let low = Self.highPass(lowOnsets, smoothLen: max(3, Int(frameRate * 0.25)))

        func meanChroma(_ from: Int, _ to: Int) -> [Float] {
            var acc = [Float](repeating: 0, count: 12)
            for i in max(0, from)..<min(total, max(from + 1, to)) { acc = vDSP.add(acc, chroma[i]) }
            let norm = max(sqrt(vDSP.sumOfSquares(acc)), 1e-9)
            return vDSP.divide(acc, norm)
        }

        // Features for beats with a full beat on each side.
        var kick: [Float] = []
        var change: [Float] = []
        var index: [Int] = []
        for k in 1..<(beats.count - 1) {
            let b = beats[k]
            let window = low[max(0, b - 2)...min(total - 1, b + 2)]
            kick.append(window.max() ?? 0)
            let before = meanChroma(beats[k + 1], b)
            let after = meanChroma(b, beats[k - 1])
            change.append(1 - vDSP.dot(before, after))
            index.append(k)
        }

        func zscore(_ x: [Float]) -> [Float] {
            let mean = vDSP.mean(x)
            let centred = vDSP.add(-mean, x)
            let sd = max(sqrt(vDSP.meanSquare(centred)), 1e-6)
            return vDSP.divide(centred, sd)
        }
        let evidence = vDSP.add(zscore(kick), zscore(change))

        var scores = [Double](repeating: 0, count: 4)
        var counts = [Double](repeating: 0, count: 4)
        for (e, k) in zip(evidence, index) {
            scores[k % 4] += Double(e)
            counts[k % 4] += 1
        }
        for m in 0..<4 { scores[m] /= max(counts[m], 1) }
        let ranked = scores.enumerated().sorted { $0.element > $1.element }
        return (ranked[0].offset, ranked[0].element - ranked[1].element)
    }

    /// Subtract a trailing local mean, half-wave rectify, then remove the overall mean.
    private static func highPass(_ x: [Float], smoothLen: Int) -> [Float] {
        var out = [Float](repeating: 0, count: x.count)
        var runSum: Float = 0
        for i in 0..<x.count {
            runSum += x[i]
            if i >= smoothLen { runSum -= x[i - smoothLen] }
            out[i] = max(0, x[i] - runSum / Float(min(i + 1, smoothLen)))
        }
        return vDSP.add(-vDSP.mean(out), out)
    }
}
