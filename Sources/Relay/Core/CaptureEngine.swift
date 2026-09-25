import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import os.log
import SatelliteKit

/// Captures the tapped process's audio via a Core Audio process tap exposed
/// through a private aggregate device, and fans the interleaved stereo stream
/// out to one ring buffer per playback sink.
///
/// Lifecycle (two-phase so sinks can be built at the tap's sample rate):
///   1. `prepare(source:)` — creates the tap, returns its sample rate
///   2. `begin(rings:)`    — creates aggregate device, installs IO proc, starts
///   3. `stop()`           — tears everything down
final class CaptureEngine {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private let log = Logger(subsystem: "app.relay", category: "capture")

    private(set) var state: State = .idle
    private(set) var tapFormat: AVAudioFormat?
    private(set) var sourceName: String = ""
    /// Sample rate of the active/prepared tap (nil when not prepared).
    private(set) var currentSampleRate: Double?

    // Realtime state (touched from the IO thread, guarded here for UI reads).
    private let ioLock = NSLock()
    private var ioState = CaptureIOState()

    /// Monotonic producer position: total frames written across all taps
    /// since capture start. The shared clock every sink syncs against.
    private let positionLock = NSLock()
    private var totalFramesWritten: Int64 = 0

    // Core Audio object ownership.
    private var tapID: AudioObjectID = AudioObjectID.unknownObject
    private var tapUUIDString = ""
    private var aggregateID: AudioObjectID = AudioObjectID.unknownObject
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "app.relay.capture.io", qos: .userInitiated)

    // Scratch space for interleaving, owned by the IO thread.
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchCapacityFrames = 0
    private var sourceIsNonInterleaved = false

    // MARK: Public API

    /// Latest peak level (0…1) across captured audio.
    var level: Float {
        ioLock.lock()
        defer { ioLock.unlock() }
        return ioState.peakLevel
    }

    /// Current end of the capture timeline, in tap frames.
    /// Sinks read this from their pump threads to stay aligned.
    func producerFramePosition() -> Int64 {
        positionLock.lock()
        defer { positionLock.unlock() }
        return totalFramesWritten
    }

    func updateSinks(_ rings: [SPSCRing]) {
        ioLock.lock()
        ioState.sinkRings = rings
        ioLock.unlock()
    }

    /// Phase 1: create the process tap and learn its format.
    /// Returns the tap's sample rate (the rate sinks should be fed at).
    @discardableResult
    func prepare(source: AudioProcess, muteWhenTapped: Bool) throws -> Double {
        guard #available(macOS 14.2, *) else {
            throw RelayError.message("Relay needs macOS 14.4 or newer (Core Audio process taps are unavailable on this system).")
        }

        stop() // ensure clean slate
        sourceName = source.name
        ioLock.lock()
        ioState.peakLevel = 0
        ioLock.unlock()

        // Describe + create the process tap.
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [source.objectID])
        tapDescription.name = "Relay capture — \(source.name)"
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = muteWhenTapped ? .mutedWhenTapped : .unmuted

        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            tapID = .unknownObject
            throw RelayError.coreAudio(status, "creating process tap for \(source.name)")
        }
        log.info("Created process tap \(self.tapID, privacy: .public) for \(source.name, privacy: .public)")
        tapUUIDString = tapDescription.uuid.uuidString

        // Read the tap's stream format.
        let asbd: AudioStreamBasicDescription = try tapID.readProperty(
            kAudioTapPropertyFormat,
            defaultValue: AudioStreamBasicDescription()
        )
        sourceIsNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        currentSampleRate = asbd.mSampleRate
        tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: max(1, asbd.mChannelsPerFrame),
            interleaved: !sourceIsNonInterleaved
        )
        log.info("Tap format: \(asbd.mSampleRate, format: .fixed(precision: 0)) Hz, \(asbd.mChannelsPerFrame) ch, nonInterleaved=\(self.sourceIsNonInterleaved)")

        return asbd.mSampleRate
    }

    /// Phase 2: expose the tap through a private aggregate device and start
    /// pulling audio into the given sink rings.
    func begin(rings: [SPSCRing]) throws {
        guard tapID.isValidObject else {
            throw RelayError.message("Capture was not prepared before begin().")
        }

        ioLock.lock()
        ioState.sinkRings = rings
        ioLock.unlock()

        // Private aggregate device: clock = current default output, tap
        // attached as a sub-tap (Apple sample + AudioCap recipe).
        let systemOutputID = try AudioObjectID.defaultOutputDevice()
        let outputUID = try systemOutputID.readString(kAudioDevicePropertyDeviceUID)

        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Relay Capture",
            kAudioAggregateDeviceUIDKey: OutputDeviceScanner.ownAggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUIDString,
                ]
            ],
        ]

        var status = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &aggregateID)
        guard status == noErr else {
            aggregateID = .unknownObject
            teardown()
            throw RelayError.coreAudio(status, "creating capture aggregate device")
        }
        log.info("Created aggregate device \(self.aggregateID, privacy: .public)")

        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            self?.handleIO(input: inputData)
        }
        guard status == noErr else {
            teardown()
            throw RelayError.coreAudio(status, "creating IO proc")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            teardown()
            throw RelayError.coreAudio(status, "starting capture aggregate device")
        }

        state = .running
        log.info("Capture running for \(self.sourceName, privacy: .public)")
    }

    func stop() {
        let wasActive = state != .idle || tapID.isValidObject
        teardown()
        state = .idle
        if wasActive {
            log.info("Capture stopped")
        }
    }

    // MARK: IO

    private func handleIO(input: UnsafePointer<AudioBufferList>?) {
        guard let input else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))

        // Normalize whatever shape the tap delivers into interleaved stereo
        // in `scratch`: [L0, R0, L1, R1, …]
        let frameCount: Int
        if bufferList.count >= 2, bufferList[0].mNumberChannels <= 1, bufferList[1].mNumberChannels <= 1 {
            // One buffer per channel (deinterleaved).
            frameCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frameCount > 0, let left = bufferList[0].mData, let right = bufferList[1].mData else { return }
            ensureScratch(frames: frameCount)
            guard let scratch else { return }

            let leftPtr = left.bindMemory(to: Float.self, capacity: frameCount)
            let rightPtr = right.bindMemory(to: Float.self, capacity: frameCount)
            for frame in 0..<frameCount {
                scratch[frame * 2] = leftPtr[frame]
                scratch[frame * 2 + 1] = rightPtr[frame]
            }
        } else {
            // Single interleaved (or mono) buffer.
            let audioBuffer = bufferList[0]
            guard let data = audioBuffer.mData else { return }
            let channels = Int(max(1, audioBuffer.mNumberChannels))
            let bytesPerFrame = channels * MemoryLayout<Float>.size
            let count = Int(audioBuffer.mDataByteSize) / bytesPerFrame
            guard count > 0 else { return }
            frameCount = count
            ensureScratch(frames: frameCount)
            guard let scratch else { return }

            let floats = data.bindMemory(to: Float.self, capacity: frameCount * channels)
            if channels >= 2 {
                for frame in 0..<frameCount {
                    scratch[frame * 2] = floats[frame * channels]
                    scratch[frame * 2 + 1] = floats[frame * channels + 1]
                }
            } else {
                // Mono: duplicate into both channels.
                for frame in 0..<frameCount {
                    scratch[frame * 2] = floats[frame]
                    scratch[frame * 2 + 1] = floats[frame]
                }
            }
        }

        // Meter + fan out.
        guard let scratch else { return }
        var peak: Float = 0
        for i in 0..<(frameCount * 2) {
            let magnitude = abs(scratch[i])
            if magnitude > peak { peak = magnitude }
        }

        ioLock.lock()
        let sinkRingsCopy = ioState.sinkRings
        ioLock.unlock()
        for ring in sinkRingsCopy {
            _ = ring.write(scratch, frameCount: frameCount)
        }
        positionLock.lock()
        totalFramesWritten += Int64(frameCount)
        positionLock.unlock()
        ioLock.lock()
        ioState.peakLevel = min(1, peak)
        ioLock.unlock()
    }

    private func ensureScratch(frames: Int) {
        let needed = frames * 2
        if scratch == nil || scratchCapacityFrames < needed {
            scratch?.deallocate()
            let capacity = max(needed, 8192)
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            scratchCapacityFrames = capacity
        }
    }

    // MARK: Teardown

    private func teardown() {
        if aggregateID.isValidObject, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID.isValidObject {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = .unknownObject

        if tapID.isValidObject, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = .unknownObject
        tapUUIDString = ""

        scratch?.deallocate()
        scratch = nil
        scratchCapacityFrames = 0
        tapFormat = nil
        currentSampleRate = nil
        positionLock.lock()
        totalFramesWritten = 0
        positionLock.unlock()

        ioLock.lock()
        ioState.sinkRings = []
        ioState.peakLevel = 0
        ioLock.unlock()
    }

    deinit {
        teardown()
    }
}

/// IO-thread state bundle (kept in one lock-guarded struct for clarity).
private struct CaptureIOState {
    var sinkRings: [SPSCRing] = []
    var peakLevel: Float = 0
}
