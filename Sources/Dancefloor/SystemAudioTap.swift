import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(subsystem: "com.natesute.dancefloor", category: "audio")

/// Captures everything the Mac is playing using a Core Audio process tap (macOS 14.2+).
/// Nothing is recorded or stored; samples go straight to the callback.
final class SystemAudioTap {
    struct TapError: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (OSStatus \(status))" }
    }

    /// Called on the audio queue with mono samples, their sample rate, and the host time
    /// (seconds, same clock as `CACurrentMediaTime`) of the first sample.
    var onAudio: ((UnsafeBufferPointer<Float>, Double, Double) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000
    private var mono: [Float] = []
    private var loggedFormat = false
    private let queue = DispatchQueue(label: "dancefloor.audio-tap", qos: .userInteractive)

    var isRunning: Bool { procID != nil }

    func start() throws {
        stop()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Dancefloor"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check("Creating the audio tap", AudioHardwareCreateProcessTap(description, &tapID))

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            try check("Reading the tap format", AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format))
            sampleRate = format.mSampleRate
            log.notice("Tap format reports \(format.mSampleRate) Hz")

            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Dancefloor Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check("Creating the aggregate device",
                      AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

            // The tap's own format can claim 48 kHz while the device clock runs at 44.1 kHz;
            // the aggregate device's nominal rate is what samples actually arrive at.
            var nominalRate: Float64 = 0
            size = UInt32(MemoryLayout<Float64>.size)
            address.mSelector = kAudioDevicePropertyNominalSampleRate
            if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &nominalRate) == noErr, nominalRate > 0 {
                sampleRate = nominalRate
            }

            try check("Creating the IO proc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
                [weak self] _, input, inputTime, _, _ in
                self?.handle(input, time: inputTime)
            })
            try check("Starting capture", AudioDeviceStart(aggregateID, procID))
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    private func handle(_ input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mData != nil else { return }
        if !loggedFormat {
            loggedFormat = true
            log.notice("Tap delivering \(buffers.count) buffer(s), \(first.mNumberChannels) ch, \(self.sampleRate) Hz")
        }

        // Interleaved (one buffer, N channels) or planar (N buffers, one channel each).
        let interleavedChannels = buffers.count == 1 ? max(1, Int(first.mNumberChannels)) : 1
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / interleavedChannels
        guard frames > 0 else { return }
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }

        if buffers.count == 1 {
            let data = first.mData!.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(interleavedChannels)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<interleavedChannels { sum += data[i * interleavedChannels + c] }
                mono[i] = sum * scale
            }
        } else {
            let scale = 1 / Float(buffers.count)
            for i in 0..<frames { mono[i] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<frames { mono[i] += data[i] * scale }
            }
        }

        let hostTime = time.pointee.mFlags.contains(.hostTimeValid)
            ? Double(AudioConvertHostTimeToNanos(time.pointee.mHostTime)) / 1e9
            : Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())) / 1e9
        mono.withUnsafeBufferPointer { onAudio?($0, sampleRate, hostTime) }
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw TapError(step: step, status: status) }
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        if status != noErr { throw TapError(step: "Finding the output device", status: status) }

        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let uid else { throw TapError(step: "Reading the output device UID", status: status) }
        return uid.takeRetainedValue() as String
    }
}
