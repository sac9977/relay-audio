import Foundation
import CoreAudio
import AudioToolbox
import AudioUnit
import AVFoundation
import os.log
import SatelliteKit

/// Live health snapshot for one output, read by the UI.
struct SinkHealth: Equatable {
    var ringDepth: Int = 0
    var latencyMs: Double = 0
    var underruns: Int = 0
    var driftNudges: Int = 0
    /// Frames this sink is ahead (+) or behind (−) the shared capture clock.
    var syncOffsetFrames: Int = 0
    /// Same offset expressed in milliseconds.
    var syncOffsetMs: Double = 0
}

/// Plays the audio arriving in its ring buffer on one specific output device
/// via an AVAudioEngine. One instance per enabled output = the fan-out.
///
/// Quality design:
///   • Pre-rolls several buffers so Bluetooth/scheduler jitter never starves
///     the output (single-buffer chains click on every jitter).
///   • Sync-group alignment: every sink knows its read position relative to
///     the shared capture timeline (`producerFramePosition`). On start it
///     pre-rolls to the same target latency; while running, a PI-style
///     controller nudges chunk sizes ±0.9% (inaudible) to hold that offset.
///     This is what keeps multiple speakers phase-coherent instead of each
///     drifting on its own crystal.
///   • Partial reads only count as underruns when the ring actually ran dry;
///     short-but-nonzero reads are just scheduling, not dropouts.
final class SinkEngine {
    enum Kind {
        case device(AudioOutputDevice)
        case thisMac(deviceName: String)
    }

    private let log = Logger(subsystem: "app.relay", category: "sink")
    let kind: Kind
    let uid: String
    let lowLatency: Bool
    let ring: SPSCRing
    /// Set when this sink fans out BRIDGE audio (a casted source) instead of
    /// capture. The bridge ring has its own producer clock; when present it
    /// takes priority in pump() and `producerPosition` is ignored.
    private(set) var bridgeRing: BridgeFanOutRing?
    /// Bridge active/idle tracking: when the cast ends (ring dry for 2 s),
    /// the sink falls back to capture pumping automatically.
    private var bridgeActive = false
    private var bridgeIdleSince: DispatchTime?
    private var bridgePrerolled = false

    /// Shared capture timeline — set by the controller before start.
    var producerPosition: () -> Int64 = { 0 }

    /// Feeds this sink from a bridge fan-out ring (casted-source mode).
    func attachBridgeRing(_ bridgeRing: BridgeFanOutRing) {
        self.bridgeRing = bridgeRing
    }

    /// Returns to capture-driven pumping.
    func detachBridgeRing() {
        bridgeRing = nil
    }

    private(set) var isRunning = false
    private var realUnderrunCount = 0
    private var driftNudges = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private let pumpQueue = DispatchQueue(label: "app.relay.sink.pump", qos: .userInitiated)
    private var playFormat: AVAudioFormat?
    private var stopped = true

    // Tuning profile (low latency trades jitter headroom for lip sync).
    private var pumpFrames: Int { lowLatency ? 1024 : 4096 }        // chunk size
    private var prerollBuffers: Int { lowLatency ? 2 : 3 }          // queued ahead
    private var driftStep: Int { lowLatency ? 256 : 512 }           // shed/gain step
    private var targetLatencyFrames: Int {
        lowLatency ? 2 * 1024 + 512 : 3 * 4096 + 2048               // ~53 ms / ~300 ms
    }
    private var maxChunkFrames: Int { pumpFrames + driftStep * 2 }

    private var pumpStaging: [Float] = []
    private var scheduledBuffers = 0
    private var cyclesSinceStatsLog = 0
    private var activeSampleRate: Double = 48000

    // Sink-local read position on the capture timeline (only touched on the
    // pump queue).
    private var readPosition: Int64 = 0
    private var prerolled = false
    private var prerollLogged = false

    // Per-speaker mix.
    private var userVolume: Float = 1
    private var isMuted = false

    /// Delay trim: extra latency (frames) this sink intentionally sits behind
    /// the shared clock, compensating fixed per-device Bluetooth transport
    /// skew. Folded into the sync target so the drift controller converges
    /// here on its own — no restart needed.
    private var delayTrimFrames: Int = 0

    func setDelayTrim(frames: Int) {
        statsLock.lock()
        delayTrimFrames = max(0, frames)
        let trimmed = delayTrimFrames
        statsLock.unlock()
        if trimmed > 0 {
            log.info("Sink \(self.displayName, privacy: .public) delay trim set to \(trimmed) frames")
        }
    }

    private var effectiveTargetLatencyFrames: Int {
        statsLock.lock()
        let trim = delayTrimFrames
        statsLock.unlock()
        return targetLatencyFrames + trim
    }

    // Health stats guarded for cross-thread reads.
    private let statsLock = NSLock()
    private var currentHealth = SinkHealth()

    var displayName: String {
        switch kind {
        case let .device(device): return device.name
        case let .thisMac(deviceName): return deviceName
        }
    }

    init(kind: Kind, uid: String, lowLatency: Bool = false) {
        self.kind = kind
        self.uid = uid
        self.lowLatency = lowLatency
        self.ring = SPSCRing(capacityFrames: lowLatency ? 16384 : 32768)
    }

    // MARK: Lifecycle

    func start(volume masterVolume: Float, sampleRate requestedRate: Double = 0) throws {
        guard !isRunning else { return }
        stopped = false
        realUnderrunCount = 0
        driftNudges = 0
        scheduledBuffers = 0
        cyclesSinceStatsLog = 0
        prerolled = false
        prerollLogged = false
        ring.reset()
        pumpStaging = [Float](repeating: 0, count: maxChunkFrames * 2)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        // Route first, so the graph is built against the target hardware.
        if case let .device(device) = kind {
            do {
                try Self.route(outputNode: engine.outputNode, toDeviceWithUID: device.uid)
            } catch {
                log.warning("Could not route to \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public). Using default output instead.")
            }
        }

        // Feed the player at the CAPTURE rate; the engine's mixer resamples
        // to whatever the output device runs at. Connecting at the device
        // rate instead would pitch-shift the audio.
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = requestedRate > 0 ? requestedRate : (hardwareRate > 0 ? hardwareRate : 48000)
        activeSampleRate = sampleRate
        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            throw RelayError.message("Could not create playback format")
        }
        playFormat = stereoFormat

        engine.connect(player, to: engine.mainMixerNode, format: stereoFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.mainMixerNode.outputVolume = max(0, min(1, masterVolume))

        try engine.start()
        player.play()
        applyUserGain()

        self.engine = engine
        self.player = player
        isRunning = true

        // Start consuming from "now": the pre-roll gate below lets the ring
        // FILL to the target latency before playback begins. (Starting the
        // read pointer *behind* the producer can never catch up — production
        // and consumption both run at 1×, so the sink would starve forever.)
        readPosition = producerPosition()

        pumpQueue.async { [weak self] in
            self?.refillQueue()
        }
        log.info("Sink started: \(self.displayName, privacy: .public) @ \(Int(sampleRate)) Hz (preroll \(self.prerollBuffers) × \(self.pumpFrames), target latency \(self.effectiveTargetLatencyFrames) frames incl. trim, lowLatency=\(self.lowLatency))")
    }

    func stop() {
        guard isRunning else { return }
        stopped = true
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        scheduledBuffers = 0
        isRunning = false
        log.info("Sink stopped: \(self.displayName, privacy: .public) (true underruns: \(self.realUnderrunCount), drift nudges: \(self.driftNudges))")
    }

    // MARK: Mixing

    /// Master volume (applied at the mixer so it scales everything).
    func setMasterVolume(_ value: Float) {
        engine?.mainMixerNode.outputVolume = max(0, min(1, value))
    }

    /// Per-speaker gain (applied at the player node).
    func setUserVolume(_ value: Float) {
        userVolume = max(0, min(1, value))
        applyUserGain()
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyUserGain()
    }

    private func applyUserGain() {
        player?.volume = isMuted ? 0 : userVolume
    }

    // MARK: Health

    var healthStats: SinkHealth {
        statsLock.lock()
        defer { statsLock.unlock() }
        return currentHealth
    }

    // MARK: Pumping

    /// Keeps `prerollBuffers` buffers queued at all times. Completion handlers
    /// release slots back and trigger a refill, so the output always has
    /// hundreds of milliseconds of audio queued ahead of playback.
    private func refillQueue() {
        guard !stopped, let player else { return }

        while scheduledBuffers < prerollBuffers {
            guard let buffer = makeNextBuffer() else {
                // Pre-roll gate not yet satisfied: poll until the ring fills.
                pumpQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.refillQueue()
                }
                return
            }
            scheduledBuffers += 1
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                guard let self else { return }
                self.pumpQueue.async {
                    self.scheduledBuffers -= 1
                    self.refillQueue()
                }
            })
        }
    }

    /// Fills one PCM buffer from the ring, holding sync with the shared
    /// capture timeline via gentle chunk-size modulation.
    private func makeNextBuffer() -> AVAudioPCMBuffer? {
        guard let format = playFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunkFrames)) else { return nil }

        // Bridge fan-out mode: this sink plays a casted source while the
        // bridge ring has audio; when it runs dry for 2 s the sink falls
        // back to capture pumping (independent pre-roll states on both paths).
        if let bridgeRing {
            let bridgeDepth = bridgeRing.bufferedFrames
            if bridgeDepth > 0 {
                bridgeActive = true
                bridgeIdleSince = nil
            } else if bridgeActive {
                if bridgeIdleSince == nil { bridgeIdleSince = DispatchTime.now() }
                if let since = bridgeIdleSince,
                   DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds > 2_000_000_000 {
                    bridgeActive = false
                    bridgeIdleSince = nil
                    bridgePrerolled = false
                    log.info("Sink \(self.displayName, privacy: .public): cast ended — returning to capture")
                }
            }
            if bridgeActive {
                return makeBridgeBuffer(bridgeRing, format: format, buffer: buffer)
            }
            // else: fall through to capture path below
        }

        let depth = ring.bufferedFrames
        let producerNow = producerPosition()
        let scheduledFrames = scheduledBuffers * pumpFrames
        let totalLatency = depth + scheduledFrames
        let target = Int64(effectiveTargetLatencyFrames)

        // Pre-roll gate: wait until the ring holds a full target latency of
        // audio before playing anything. ~300 ms of startup silence buys a
        // permanently full buffer afterwards — the difference between clean
        // audio and endless dropouts.
        if !prerolled {
            guard depth >= target else {
                if !prerollLogged, cyclesSinceStatsLog == 0 {
                    prerollLogged = true
                    log.info("Sink \(self.displayName, privacy: .public) pre-rolling: \(depth)/\(target) frames")
                }
                return nil
            }
            prerolled = true
            log.info("Sink \(self.displayName, privacy: .public) pre-roll complete (\(depth) frames) — starting playback")
        }

        // Sync error: how far the playback point sits from the anchor
        // (target latency + delay trim behind the producer).
        let offset = Int64(totalLatency) - target

        // Decide how much to play this cycle.
        var chunk = pumpFrames
        if depth > ring.capacityFrames - maxChunkFrames {
            // Catastrophic backlog (controller failure safety net).
            ring.resync(targetLatencyFrames: effectiveTargetLatencyFrames)
            readPosition = producerNow - Int64(effectiveTargetLatencyFrames)
            log.warning("Ring overflow on \(self.displayName, privacy: .public); resynced")
        } else if offset > Int64(pumpFrames) / 2 {
            // We're running long (ring deeper than anchor): shed with a
            // longer chunk — the surplus is real buffered audio.
            chunk = pumpFrames + driftStep
            driftNudges += 1
        } else if offset < -Int64(pumpFrames) / 2 && depth >= pumpFrames - driftStep {
            // We're running short: gain ground with a shorter chunk. The
            // producer refills the gap because it keeps writing at 1×.
            chunk = pumpFrames - driftStep
            driftNudges += 1
        } else if depth < 512 {
            // Genuinely starving: play a short buffer of real silence (counted
            // as an underrun) instead of spinning on zero-length buffers.
            chunk = pumpFrames / 4
        }

        var framesRead = 0
        pumpStaging.withUnsafeMutableBufferPointer { staging in
            guard let channelData = buffer.floatChannelData else { return }
            let got = ring.read(into: staging.baseAddress!, frameCount: chunk)
            let left = channelData[0]
            let right = channelData[1]
            for frame in 0..<got {
                left[frame] = staging[frame * 2]
                right[frame] = staging[frame * 2 + 1]
            }
            if got == 0 {
                // Explicit silence so the buffer occupies real playback time.
                for frame in 0..<chunk {
                    left[frame] = 0
                    right[frame] = 0
                }
                buffer.frameLength = AVAudioFrameCount(chunk)
            } else {
                buffer.frameLength = AVAudioFrameCount(got)
            }
            framesRead = got
        }

        readPosition += Int64(framesRead)

        // Underruns are real only when the ring was dry (nothing delivered).
        if framesRead == 0 {
            realUnderrunCount += 1
        }

        cyclesSinceStatsLog += 1
        if cyclesSinceStatsLog >= 60 { // roughly every 5 seconds
            cyclesSinceStatsLog = 0
            log.info("Sink \(self.displayName, privacy: .public): ringDepth=\(depth) totalLatency=\(totalLatency) chunk=\(chunk) offset=\(Int(offset)) underruns=\(self.realUnderrunCount)")
        }

        statsLock.lock()
        currentHealth = SinkHealth(
            ringDepth: depth,
            latencyMs: Double(totalLatency) / activeSampleRate * 1000,
            underruns: realUnderrunCount,
            driftNudges: driftNudges,
            syncOffsetFrames: Int(offset),
            syncOffsetMs: Double(offset) / activeSampleRate * 1000
        )
        statsLock.unlock()

        return buffer
    }

    // MARK: Bridge fan-out pumping

    /// Depth-based pump for casted sources. Pre-rolls like capture mode, then
    /// keeps the bridge ring near the target depth via chunk modulation.
    private func makeBridgeBuffer(
        _ bridgeRing: BridgeFanOutRing,
        format: AVAudioFormat,
        buffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        let depth = bridgeRing.bufferedFrames
        let scheduledFrames = scheduledBuffers * pumpFrames
        let totalLatency = depth + scheduledFrames
        let target = Int64(effectiveTargetLatencyFrames)

        if !bridgePrerolled {
            guard depth >= target else {
                if !prerollLogged, cyclesSinceStatsLog == 0 {
                    prerollLogged = true
                    log.info("Bridge sink \(self.displayName, privacy: .public) pre-rolling: \(depth)/\(target) frames")
                }
                return nil
            }
            bridgePrerolled = true
            log.info("Bridge sink \(self.displayName, privacy: .public) pre-roll complete (\(depth) frames)")
        }

        let offset = Int64(totalLatency) - target
        var chunk = pumpFrames
        if depth > bridgeRing.capacityFrames - maxChunkFrames {
            bridgeRing.reset() // packet backlog; drop instead of drifting late
            log.warning("Bridge ring overflow on \(self.displayName, privacy: .public); dropped backlog")
            return nil
        } else if offset > Int64(pumpFrames) / 2 {
            chunk = pumpFrames + driftStep
            driftNudges += 1
        } else if offset < -Int64(pumpFrames) / 2 && depth >= pumpFrames - driftStep {
            chunk = pumpFrames - driftStep
            driftNudges += 1
        } else if depth < 512 {
            chunk = pumpFrames / 4
        }

        var framesRead = 0
        pumpStaging.withUnsafeMutableBufferPointer { staging in
            guard let channelData = buffer.floatChannelData else { return }
            let got = bridgeRing.read(into: staging.baseAddress!, frameCount: chunk)
            let left = channelData[0]
            let right = channelData[1]
            for frame in 0..<got {
                left[frame] = staging[frame * 2]
                right[frame] = staging[frame * 2 + 1]
            }
            if got == 0 {
                for frame in 0..<chunk {
                    left[frame] = 0
                    right[frame] = 0
                }
                buffer.frameLength = AVAudioFrameCount(chunk)
                realUnderrunCount += 1
            } else {
                buffer.frameLength = AVAudioFrameCount(got)
            }
            framesRead = got
        }

        cyclesSinceStatsLog += 1
        if cyclesSinceStatsLog >= 60 {
            cyclesSinceStatsLog = 0
            log.info("Bridge sink \(self.displayName, privacy: .public): depth=\(depth) chunk=\(chunk) underruns=\(self.realUnderrunCount)")
        }
        statsLock.lock()
        currentHealth = SinkHealth(
            ringDepth: depth,
            latencyMs: Double(totalLatency) / activeSampleRate * 1000,
            underruns: realUnderrunCount,
            driftNudges: driftNudges,
            syncOffsetFrames: Int(offset),
            syncOffsetMs: Double(offset) / activeSampleRate * 1000
        )
        statsLock.unlock()

        return buffer
    }

    // MARK: Device routing

    /// Points the engine's output unit at a specific output device.
    private static func route(outputNode: AVAudioOutputNode, toDeviceWithUID uid: String) throws {
        guard let audioUnit = outputNode.audioUnit else {
            throw RelayError.message("Output node has no audio unit to route.")
        }
        let deviceID = try AudioObjectID.device(forUID: uid)
        var device = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw RelayError.coreAudio(status, "routing output to device \(uid)")
        }
    }
}
