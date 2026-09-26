import Foundation
import Network
import os.log
import SatelliteKit

/// Sends the shared ring's audio to one Satellite receiver over UDP as raw
/// Float32 PCM (lossless by construction), honoring NACK resends.
final class NetworkSinkEngine {
    private let log = Logger(subsystem: "app.relay", category: "netsink")
    let uid: String
    let host: String
    let ring: SPSCRing
    private var producerPosition: () -> Int64

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "app.relay.netsink", qos: .userInitiated)
    private let pumpQueue = DispatchQueue(label: "app.relay.netsink.pump", qos: .userInitiated)
    private var stopped = true
    private(set) var isRunning = false

    /// Capture rate this sink runs at; also declared in every data packet
    /// header so the receiver paces playback correctly.
    private(set) var sampleRate: Double = SatelliteProtocol.samplesPerSecond

    private let streamID: UInt32
    private var nextSequence: UInt64 = 0
    private var readPosition: Int64 = 0
    private var prerolled = false

    private let chunkPackets = SatelliteProtocol.maxPacketsPerChunk
    private var unacked: [UInt64: Data] = [:]
    private var maxUnacked = 512
    private var resentPackets = 0
    private var sentPackets = 0

    struct Stats: Equatable {
        var sent: Int = 0
        var resent: Int = 0
        var connected: Bool = false
        /// Receiver-reported link quality (0 when no stats beacon yet).
        var lossPermille: Int = 0
        var jitterDepthPackets: Int = 0
        var receiverBufferedMs: Int = 0
    }
    private let statsLock = NSLock()
    private var currentStats = Stats()

    var stats: Stats {
        statsLock.lock()
        defer { statsLock.unlock() }
        return currentStats
    }

    var displayName: String { "Satellite \(host)" }

    init(uid: String, host: String, sampleRate: Double = SatelliteProtocol.samplesPerSecond, producerPosition: @escaping () -> Int64) {
        self.uid = uid
        self.host = host
        self.sampleRate = sampleRate
        self.producerPosition = producerPosition
        self.ring = SPSCRing(capacityFrames: 32768)
        self.streamID = UInt32(arc4random())
    }

    func start() {
        guard !isRunning else { return }
        stopped = false
        nextSequence = 0
        readPosition = producerPosition()
        prerolled = false
        ring.reset()
        sentPackets = 0
        resentPackets = 0
        unacked.removeAll()

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: SatelliteProtocol.defaultPort)!,
            using: .udp
        )
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            let connected: Bool
            switch state {
            case .ready: connected = true
            case .failed, .cancelled: connected = false
            default: return
            }
            self.statsLock.lock()
            self.currentStats.connected = connected
            self.statsLock.unlock()
            if case .failed = state {
                self.log.warning("Satellite connection to \(self.host, privacy: .public) failed")
            }
        }
        connection.start(queue: queue)
        self.connection = connection

        receiveLoop()
        pumpQueue.async { [weak self] in
            self?.pumpChunk()
        }
        isRunning = true
        log.info("Network sink started → \(self.host, privacy: .public):\(SatelliteProtocol.defaultPort)")
    }

    func stop() {
        guard isRunning else { return }
        stopped = true
        connection?.cancel()
        connection = nil
        isRunning = false
        let s = stats
        log.info("Network sink stopped: \(self.host, privacy: .public) (sent \(s.sent), resent \(s.resent)) @ \(Int(self.sampleRate)) Hz")
    }

    private func receiveLoop() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data {
                if let nack = SatelliteProtocol.decodeNack(data) {
                    self.handleNack(nack)
                } else if let stats = SatelliteProtocol.decodeStats(data), stats.streamID == self.streamID {
                    self.statsLock.lock()
                    self.currentStats.lossPermille = Int(stats.stats.lossPermille)
                    self.currentStats.jitterDepthPackets = Int(stats.stats.jitterDepthPackets)
                    self.currentStats.receiverBufferedMs = Int(stats.stats.bufferedMs)
                    self.statsLock.unlock()
                }
            }
            if error == nil {
                self.receiveLoop()
            }
        }
    }

    private func handleNack(_ nack: (streamID: UInt32, missingSequence: UInt64, count: UInt16)) {
        guard nack.streamID == streamID else { return }
        for seq in nack.missingSequence..<(nack.missingSequence + UInt64(nack.count)) {
            if let packet = unacked[seq] {
                send(packet)
                resentPackets += 1
            }
        }
    }

    /// Sends one chunk of `chunkPackets` packets, paced to real time.
    private func pumpChunk() {
        guard !stopped else { return }

        // Pre-roll target in frames, scaled to this sink's rate (~171 ms).
        let target = Int(8192.0 * sampleRate / SatelliteProtocol.samplesPerSecond)
        if !prerolled {
            guard ring.bufferedFrames >= target else {
                pumpQueue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.pumpChunk()
                }
                return
            }
            prerolled = true
        }

        var packetsThisChunk = 0
        while packetsThisChunk < chunkPackets {
            var payload: [Float] = .init(repeating: 0, count: SatelliteProtocol.samplesPerPacket * 2)
            let got = payload.withUnsafeMutableBufferPointer { buffer in
                ring.read(into: buffer.baseAddress!, frameCount: SatelliteProtocol.samplesPerPacket)
            }
            if got == 0 { break } // producer momentarily behind; NACKs cover it
            readPosition += Int64(got)

            let packet = got == SatelliteProtocol.samplesPerPacket
                ? payload.withUnsafeBufferPointer { buffer in
                    SatelliteProtocol.encodeDataPacket(
                        streamID: streamID,
                        sequence: nextSequence,
                        producerFrame: UInt64(readPosition - Int64(got)),
                        payload: UnsafeRawBufferPointer(buffer),
                        sampleRate: sampleRate
                    )
                }
                : Data() // partial tail packet: not expected in steady state
            if !packet.isEmpty {
                let seq = nextSequence
                unacked[seq] = packet
                if unacked.count > maxUnacked {
                    // Drop oldest acked-by-age entries (receiver is long past).
                    let oldest = unacked.keys.min()!
                    unacked.removeValue(forKey: oldest)
                }
                send(packet)
                nextSequence += 1
                sentPackets += 1
            }
            packetsThisChunk += 1
        }

        statsLock.lock()
        currentStats.sent = sentPackets
        currentStats.resent = resentPackets
        statsLock.unlock()

        // Pace: chunk = 16 × 1024 frames ≈ 21.3 ms @ 48 kHz, scaled to the
        // capture rate so the sender runs exactly at real time.
        let chunkInterval = Double(chunkPackets * SatelliteProtocol.samplesPerPacket) / sampleRate
        pumpQueue.asyncAfter(deadline: .now() + chunkInterval) { [weak self] in
            guard let self, !self.stopped else { return }
            self.pumpChunk()
        }
    }

    private func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { _ in })
    }
}
