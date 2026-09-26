import Foundation
import Network
import AVFoundation
import os.log
import SatelliteKit

/// Relay's bridge: accepts 4-digit-code pairing requests on UDP :51511, then
/// receives the paired source's raw PCM data packets on the standard receiver
/// port (:51510, filtered by stream ID).
///
/// Fan-out mode (default): every drained packet is written into one
/// `BridgeFanOutRing` per registered sink, so the casted source plays on
/// every enabled output through the normal SinkEngine path — same pre-roll,
/// drift handling, and health stats as capture-driven audio.
/// Local monitor (own AVAudioEngine on this Mac) is available but off unless
/// explicitly enabled via `wantsLocalMonitor`.
final class BridgeAudioSource {
    private let log = Logger(subsystem: "app.relay", category: "bridge")

    struct SourceInfo: Equatable {
        var deviceName: String = ""
        var host: String = ""
        var streamID: UInt32 = 0
        var receivedPackets: Int = 0
        var sentNacks: Int = 0
        var bufferedMs: Double = 0
    }

    private var listener: NWListener?
    private var receiver: NWListener?
    private var dataConnection: NWConnection?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let queue = DispatchQueue(label: "app.relay.bridge", qos: .userInitiated)
    private let pumpQueue = DispatchQueue(label: "app.relay.bridge.pump", qos: .userInitiated)

    private let lock = NSLock()
    private var acceptedCode: String?
    private var info = SourceInfo()
    private var publishedInfo = SourceInfo()
    private var expectedSequence: UInt64?
    private var packetsBySequence: [UInt64: Data] = [:]
    private var missingSince: [UInt64: DispatchTime] = [:]
    private var sampleRate: Double = SatelliteProtocol.samplesPerSecond
    private var lastDataAt: DispatchTime?

    // Fan-out consumers, registered by the controller.
    private var fanOutRings: [BridgeFanOutRing] = []
    /// Play the casted source on this Mac's own output too (off by default —
    /// Relay's speakers usually belong to the capture source).
    var wantsLocalMonitor = false

    /// Called when a source pairs (controller re-registers fan-out rings).
    var onSourcePaired: (() -> Void)? = nil

    var isActive: Bool { listener != nil }

    var currentInfo: SourceInfo {
        lock.lock()
        defer { lock.unlock() }
        return info
    }

    /// Snapshot the UI poll reads; only changes when content changes.
    var publishedSnapshot: SourceInfo {
        lock.lock()
        defer { lock.unlock() }
        return publishedInfo
    }

    /// Controller registers one ring per sink that should receive the cast.
    func registerFanOutRings(_ rings: [BridgeFanOutRing]) {
        lock.lock()
        fanOutRings = rings
        lock.unlock()
    }

    func start(code: String) {
        stop()
        lock.lock()
        acceptedCode = code
        lock.unlock()

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: SatelliteProtocol.bridgePort)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptPairing(on: connection)
            }
            // Senders find this Mac by browsing _relay-bridge._udp and match
            // on the pairing code shown in Relay's UI.
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Relay",
                type: "_relay-bridge._udp",
                txtRecord: PairingCode.txtRecord(code)
            )
            listener.start(queue: queue)
            self.listener = listener
            log.info("Bridge pairing listener on UDP \(SatelliteProtocol.bridgePort), code \(code, privacy: .public)")
        } catch {
            log.error("Bridge listener failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Data path: paired sources stream to the standard receiver port.
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let receiver = try NWListener(using: params, on: NWEndpoint.Port(rawValue: SatelliteProtocol.defaultPort)!)
            receiver.newConnectionHandler = { [weak self] connection in
                self?.acceptData(on: connection)
            }
            receiver.start(queue: queue)
            self.receiver = receiver
            log.info("Bridge data listener on UDP \(SatelliteProtocol.defaultPort)")
        } catch {
            log.error("Bridge data listener failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        pumpQueue.async { [weak self] in self?.drainPackets() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        receiver?.cancel()
        receiver = nil
        dataConnection?.cancel()
        dataConnection = nil
        lock.lock()
        acceptedCode = nil
        expectedSequence = nil
        packetsBySequence.removeAll()
        missingSince.removeAll()
        fanOutRings = []
        info = SourceInfo()
        lastDataAt = nil
        lock.unlock()
        pumpQueue.async { [weak self] in
            self?.playerNode?.stop()
            self?.engine?.stop()
            self?.engine = nil
            self?.playerNode = nil
        }
        log.info("Bridge stopped")
    }

    // MARK: Pairing

    private func acceptPairing(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, let request = SatelliteProtocol.decodePairRequest(data) else {
                if error == nil { self.acceptPairing(on: connection) }
                return
            }
            self.lock.lock()
            let code = self.acceptedCode
            self.lock.unlock()
            guard let code, request.code == code else {
                // Wrong code: drop silently (no signal for brute-force probes).
                connection.cancel()
                self.log.warning("Bridge pairing rejected (wrong code)")
                return
            }

            let streamID = UInt32(arc4random())
            let ok = SatelliteProtocol.encodePairOK(streamID: streamID)
            connection.send(content: ok, completion: .contentProcessed { _ in
                connection.cancel() // pairing complete; data arrives separately
            })

            let host = Self.hostString(from: connection.endpoint) ?? "unknown"
            self.lock.lock()
            self.info = SourceInfo(deviceName: request.deviceName, host: host, streamID: streamID)
            self.expectedSequence = nil
            self.packetsBySequence.removeAll()
            self.missingSince.removeAll()
            self.lastDataAt = nil
            self.lock.unlock()
            self.onSourcePaired?()
            self.log.info("Bridge paired: \"\(request.deviceName, privacy: .public)\" → stream \(streamID)")
        }
    }

    // MARK: Data path

    private func acceptData(on connection: NWConnection) {
        // CRITICAL: accepted connections must be started (see receivers), and
        // NACKs ride this very connection so replies share the :51510 source
        // port the sender's connected socket filters on.
        connection.start(queue: queue)
        lock.lock()
        dataConnection = connection
        lock.unlock()

        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            defer {
                if error == nil { self.acceptData(on: connection) }
            }
            guard error == nil else { return }
            guard let data, let header = SatelliteProtocol.decodeDataPacket(data) else { return }

            self.lock.lock()
            let sid = self.info.streamID
            self.lock.unlock()
            guard header.streamID == sid else { return } // not our paired source

            if abs(header.sampleRate - self.sampleRate) > 1 {
                self.sampleRate = header.sampleRate
                self.lock.lock()
                self.expectedSequence = nil
                self.packetsBySequence.removeAll()
                self.missingSince.removeAll()
                self.lock.unlock()
                self.rebuildEngine()
            }

            self.lock.lock()
            self.lastDataAt = DispatchTime.now()
            if self.expectedSequence == nil { self.expectedSequence = header.sequence }
            self.packetsBySequence[header.sequence] = data.subdata(in: header.payloadRange)
            self.lock.unlock()

            self.lock.lock()
            self.info.receivedPackets += 1
            self.lock.unlock()
        }
    }

    // MARK: Drain → fan-out (+ optional local monitor)

    /// Drains in-sequence packets, NACKs gaps (with backoff), and writes each
    /// packet into every registered fan-out ring. Runs on pumpQueue; the only
    /// producer touching fan-out rings.
    private func drainPackets() {
        var ran = false
        defer {
            pumpQueue.asyncAfter(deadline: .now() + (ran ? 0.005 : 0.02)) { [weak self] in
                self?.drainPackets()
            }
        }

        lock.lock()
        guard let expected = expectedSequence else {
            lock.unlock()
            return
        }
        var seq = expected
        var packets: [Data] = []
        while packets.count < 8, let chunk = packetsBySequence.removeValue(forKey: seq) {
            packets.append(chunk)
            missingSince.removeValue(forKey: seq)
            seq += 1
        }

        // Gap: NACK the run of missing packets with backoff so we don't
        // carpet-bomb a sender that is itself recovering.
        if packets.isEmpty {
            let gapSeq: UInt64 = seq
            if missingSince[gapSeq] == nil { missingSince[gapSeq] = DispatchTime.now() }
            let since = missingSince[gapSeq]!
            let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6
            let attempts = info.sentNacks
            let backoffMs = min(160.0, 20.0 * pow(2.0, Double(min(attempts, 4))))
            if waitedMs >= backoffMs {
                let nack = SatelliteProtocol.encodeNack(streamID: info.streamID, missingSequence: gapSeq, count: 8)
                dataConnection?.send(content: nack, completion: .contentProcessed { _ in })
                info.sentNacks += 1
                missingSince[gapSeq] = DispatchTime.now()
            }
        }

        let buffered = packets.count * SatelliteProtocol.samplesPerPacket
        info.bufferedMs = Double(packetsBySequence.count * SatelliteProtocol.samplesPerPacket) / sampleRate * 1000
        if info != publishedInfo { publishedInfo = info }
        expectedSequence = seq
        lock.unlock()

        guard !packets.isEmpty else { return }
        ran = true

        // Fan out: each registered sink ring gets the packet bytes.
        lock.lock()
        let rings = fanOutRings
        lock.unlock()
        for packet in packets {
            packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
                let frames = packet.count / SatelliteProtocol.pcmBytesPerFrame
                for ring in rings {
                    _ = ring.write(base, frameCount: frames)
                }
            }
        }

        // Optional local monitor: mirror into the monitor player via the
        // engine's scheduled buffers.
        if wantsLocalMonitor, let node = playerNode,
           let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) {
            for packet in packets {
                let frames = packet.count / SatelliteProtocol.pcmBytesPerFrame
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channelData = buffer.floatChannelData else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    let floats = raw.bindMemory(to: Float.self)
                    for f in 0..<frames {
                        channelData[0][f] = floats[f * 2]
                        channelData[1][f] = floats[f * 2 + 1]
                    }
                }
                node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            }
        }
        _ = buffered
    }

    // MARK: Local monitor engine (optional)

    private func rebuildEngine() {
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            log.error("Bridge could not create \(Int(self.sampleRate), privacy: .public) Hz format")
            return
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            log.error("Bridge engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        node.play()
        self.engine = engine
        self.playerNode = node
        log.info("Bridge local monitor playing at \(Int(self.sampleRate), privacy: .public) Hz")
    }

    static func hostString(from endpoint: NWEndpoint) -> String? {
        if case let .hostPort(host, _) = endpoint {
            switch host {
            case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init) ?? "\(a)"
            case .ipv6(let a): return "\(a)"
            case .name(let n, _): return n
            @unknown default: return "\(host)"
            }
        }
        return nil
    }
}
