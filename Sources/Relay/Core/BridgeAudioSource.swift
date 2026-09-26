import Foundation
import Network
import AVFoundation
import os.log
import SatelliteKit

/// Relay's bridge: accepts 4-digit-code pairing requests on UDP :51511, then
/// receives the paired source's raw PCM data packets on the standard receiver
/// port (:51510, filtered by stream ID) and plays them on this Mac's output
/// through its own AVAudioEngine.
///
/// Scope note: bridge audio is an independent player, not mixed into the
/// sync-group fan-out — the sink rings are fed exclusively by the process-tap
/// producer, and a second producer would interleave two clocks into one ring.
/// Casting an external source OUT to the group can build on the fan-out side
/// later; v1 brings outside audio INTO this Mac's speakers.
final class BridgeAudioSource {
    private let log = Logger(subsystem: "app.relay", category: "bridge")

    struct SourceInfo: Equatable {
        var deviceName: String = ""
        var host: String = ""
        var streamID: UInt32 = 0
        var receivedPackets: Int = 0
        var bufferedMs: Double = 0
    }

    private var listener: NWListener?
    private var receiver: NWListener?
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
    private var sampleRate: Double = SatelliteProtocol.samplesPerSecond
    private var pendingFormats: [Data] = []

    /// Called when a source pairs or its stats change (main-thread consumer
    /// polls `publishedSnapshot` instead; kept for future push use).
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
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        receiver?.cancel()
        receiver = nil
        lock.lock()
        acceptedCode = nil
        expectedSequence = nil
        packetsBySequence.removeAll()
        info = SourceInfo()
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
            self.lock.unlock()
            self.onSourcePaired?()
            self.log.info("Bridge paired: \"\(request.deviceName, privacy: .public)\" → stream \(streamID)")
        }
    }

    // MARK: Data path

    private func acceptData(on connection: NWConnection) {
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
                self.lock.unlock()
                self.rebuildEngine()
            }

            self.lock.lock()
            if self.expectedSequence == nil { self.expectedSequence = header.sequence }
            self.packetsBySequence[header.sequence] = data.subdata(in: header.payloadRange)
            self.lock.unlock()

            self.lock.lock()
            self.info.receivedPackets += 1
            self.lock.unlock()
        }
    }

    // MARK: Playback

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
        log.info("Bridge playing at \(Int(self.sampleRate), privacy: .public) Hz")
        pumpQueue.async { [weak self] in self?.pump() }
    }

    private func pump() {
        guard let node = playerNode, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            pumpQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pump() }
            return
        }

        lock.lock()
        guard let expected = expectedSequence else {
            lock.unlock()
            pumpQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pump() }
            return
        }
        let bufferFrames = SatelliteProtocol.samplesPerPacket * 4
        var payloadChunks: [Data] = []
        var filled = 0
        var seq = expected
        while filled + SatelliteProtocol.samplesPerPacket <= bufferFrames,
              let chunk = packetsBySequence.removeValue(forKey: seq) {
            payloadChunks.append(chunk)
            filled += SatelliteProtocol.samplesPerPacket
            seq += 1
        }
        expectedSequence = seq
        let buffered = filled
        info.bufferedMs = Double(filled) / sampleRate * 1000
        if info != publishedInfo { publishedInfo = info }
        lock.unlock()

        if filled > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferFrames)) {
            buffer.frameLength = AVAudioFrameCount(filled)
            if let channelData = buffer.floatChannelData {
                var frameOffset = 0
                for chunk in payloadChunks {
                    chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        let floats = raw.bindMemory(to: Float.self)
                        for frame in 0..<(chunk.count / SatelliteProtocol.pcmBytesPerFrame) {
                            channelData[0][frameOffset + frame] = floats[frame * 2]
                            channelData[1][frameOffset + frame] = floats[frame * 2 + 1]
                        }
                    }
                    frameOffset += chunk.count / SatelliteProtocol.pcmBytesPerFrame
                }
            }
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                self?.pumpQueue.async { self?.pump() }
            })
        } else {
            pumpQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pump() }
        }
        _ = buffered
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
