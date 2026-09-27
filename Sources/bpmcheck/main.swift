import AVFoundation
import DancefloorCore

// Offline check for the beat tracker.
//   bpmcheck <audio file>      run a file through the tracker and print estimates
//   bpmcheck --click <bpm>     run a synthetic click track

let args = CommandLine.arguments.dropFirst()
var samples: [Float] = []
var sampleRate = 48_000.0
var label = ""

if args.first == "--click", let bpm = args.dropFirst().first.flatMap(Double.init) {
    samples = ClickTrack.make(bpm: bpm, seconds: 20)
    label = "click @ \(bpm)"
} else if let path = args.first {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(standardFormatWithSampleRate: file.fileFormat.sampleRate, channels: file.fileFormat.channelCount)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    sampleRate = format.sampleRate
    let channels = Int(format.channelCount)
    samples = [Float](repeating: 0, count: Int(buffer.frameLength))
    for c in 0..<channels {
        let data = buffer.floatChannelData![c]
        for i in 0..<samples.count { samples[i] += data[i] / Float(channels) }
    }
    label = (path as NSString).lastPathComponent
} else {
    print("usage: bpmcheck <file> | --click <bpm>")
    exit(1)
}

let tracker = BeatTracker(sampleRate: sampleRate)
let chunk = 512
var i = 0
var lastPrint = -10.0
var firstDownbeat: Double?
var barCalls: [String: Int] = [:]
print(label)
while i < samples.count {
    let n = min(chunk, samples.count - i)
    let t = Double(i) / sampleRate
    samples.withUnsafeBufferPointer { p in
        tracker.process(UnsafeBufferPointer(rebasing: p[i..<(i + n)]), time: t)
    }
    if t - lastPrint >= 2, let e = tracker.estimate {
        lastPrint = t
        // Which beat of the bar (0-3, relative to the first downbeat seen) is called beat 1.
        var bar = "-"
        if let d = e.downbeatTime {
            if firstDownbeat == nil { firstDownbeat = d }
            let beats = ((d - firstDownbeat!) / e.period).rounded()
            bar = String(Int(((beats.truncatingRemainder(dividingBy: 4)) + 4).truncatingRemainder(dividingBy: 4)))
            barCalls[bar, default: 0] += 1
        }
        print(String(format: "t=%6.1fs  bpm=%6.2f  beat@%7.3fs  conf=%.2f  bar=%@ (%.2f)",
                     t, e.bpm, e.beatTime, e.confidence, bar, e.downbeatConfidence))
    }
    i += n
}
print("bar calls:", barCalls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
