import SwiftUI
import AVFoundation
import Network
import os.log
import SatelliteKit

@main
struct SatelliteApp: App {
    @StateObject private var receiver = SatelliteReceiver()

    var body: some Scene {
        WindowGroup("Relay Satellite") {
            ReceiverView()
                .environmentObject(receiver)
                .frame(minWidth: 400, minHeight: 280)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Engine (not actor-isolated; owns sockets, packets, and audio)

/// Receives raw PCM packets from Relay over UDP, requests resends for losses,
/// conceals unrecoverable gaps, and plays through the default output.
final class SatelliteEngine {
    private let log = Logger(subsystem: "app.relay.satellite", category: "engine")

    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let pumpQueue = DispatchQueue(label: "app.relay.satellite.pump", qos: .userInitiated)

    private var stopped = true
    private var listening = false
    private var senderDescription: String?
    private var lastSenderEndpoint: NWEndpoint?
    private var nackConnection: NWConnection?

    private let packetLock = NSLock()
    private var packetsBySequence: [UInt64: (producerFrame: UInt64, payload: Data)] = [:]
    private var expectedSequence: UInt64?
    private var latestProducerFrame: UInt64 = 0
    private var missingSince: [UInt64: DispatchTime] = [:]

    private var receivedPackets = 0
    private var concealedFrames = 0
    private var resendRequests = 0
    private var bufferedMs: Double = 0

    private let samplesPerPacket = SatelliteProtocol.samplesPerPacket
    private let concealAfterMs = 90.0
    private let sampleRate: Double = 48000

    struct Snapshot {
        var listening = false
        var sender: String?
        var received = 0
        var concealed = 0
        var resends = 0
        var bufferedMs: Double = 0
    }

    private let snapshotLock = NSLock()
    private func publish() {
        snapshotLock.lock()
        snapshot = Snapshot(
            listening: listening,
            sender: senderDescription,
            received: receivedPackets,
            concealed: concealedFrames,
            resends: resendRequests,
            bufferedMs: bufferedMs
        )
        snapshotLock.unlock()
    }
    private var snapshot = Snapshot()

    var currentSnapshot: Snapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    func start() {
        guard stopped else { return }
        stopped = false

        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: SatelliteProtocol.defaultPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.listening = (state == .ready)
                self.publish()
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            log.info("Satellite listening on UDP \(SatelliteProtocol.defaultPort)")
        } catch {
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }

        startPlaybackEngine()
        pumpQueue.async { [weak self] in self?.pump() }
        publish()
    }

    func setVolume(_ value: Float) {
        playerNode?.volume = max(0, min(1, value))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        listener = nil
        nackConnection?.cancel()
        nackConnection = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        listening = false
        packetLock.lock()
        packetsBySequence.removeAll()
        packetLock.unlock()
        publish()
        log.info("Satellite stopped")
    }

    private func accept(_ connection: NWConnection) {
        senderDescription = connection.endpoint.debugDescription
        lastSenderEndpoint = connection.endpoint
        publish()
        receiveLoop(on: connection)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, let header = SatelliteProtocol.decodeDataPacket(data) {
                let payload = data.subdata(in: header.payloadRange)
                self.packetLock.lock()
                if self.expectedSequence == nil { self.expectedSequence = header.sequence }
                self.packetsBySequence[header.sequence] = (header.producerFrame, payload)
                self.latestProducerFrame = max(self.latestProducerFrame, header.producerFrame)
                self.packetLock.unlock()
                self.receivedPackets += 1
            }
            if error == nil {
                self.receiveLoop(on: connection)
            } else {
                self.publish()
            }
        }
    }

    private func startPlaybackEngine() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            log.error("Engine failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        node.play()
        self.engine = engine
        self.playerNode = node
    }

    /// Core pump: plays packets in sequence order, NACKs gaps, conceals
    /// unrecoverable loss after a grace period.
    private func pump() {
        guard !stopped, let node = playerNode, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        packetLock.lock()
        guard let expected = expectedSequence else {
            packetLock.unlock()
            pumpQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pump() }
            return
        }

        let bufferFrames = samplesPerPacket * 4
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(bufferFrames)) else {
            packetLock.unlock()
            return
        }
        var filled = 0

        // Drain in-sequence packets into the buffer.
        var seq = expected
        while filled + samplesPerPacket <= bufferFrames,
              let entry = packetsBySequence.removeValue(forKey: seq) {
            entry.payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let channelData = buffer.floatChannelData else { return }
                let floats = raw.bindMemory(to: Float.self)
                for frame in 0..<samplesPerPacket {
                    channelData[0][filled + frame] = floats[frame * 2]
                    channelData[1][filled + frame] = floats[frame * 2 + 1]
                }
            }
            filled += samplesPerPacket
            missingSince.removeValue(forKey: seq)
            seq += 1
        }

        // Gap handling: NACK promptly, conceal when too old.
        if filled < bufferFrames, packetsBySequence[seq] == nil {
            let now = DispatchTime.now()
            if missingSince[seq] == nil { missingSince[seq] = now }
            if let since = missingSince[seq] {
                let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e6
                if waitedMs > concealAfterMs {
                    let silenceFrames = min(bufferFrames - filled, samplesPerPacket)
                    if let channelData = buffer.floatChannelData {
                        for frame in filled..<(filled + silenceFrames) {
                            channelData[0][frame] = 0
                            channelData[1][frame] = 0
                        }
                    }
                    filled += silenceFrames
                    concealedFrames += silenceFrames
                    missingSince.removeValue(forKey: seq)
                    seq += 1
                } else {
                    let nack = SatelliteProtocol.encodeNack(streamID: 0, missingSequence: seq, count: 8)
                    sendNack(nack)
                    resendRequests += 1
                }
            }
        }

        expectedSequence = seq
        packetLock.unlock()

        if filled > 0 {
            buffer.frameLength = AVAudioFrameCount(filled)
            bufferedMs = Double(filled) / sampleRate * 1000
            node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: { [weak self] in
                self?.pumpQueue.async { self?.pump() }
            })
        } else {
            pumpQueue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pump() }
        }
        publish()
    }

    private func sendNack(_ data: Data) {
        if nackConnection == nil, let sender = lastSenderEndpoint {
            let conn = NWConnection(to: sender, using: .udp)
            conn.start(queue: .global(qos: .userInitiated))
            nackConnection = conn
        }
        nackConnection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - MainActor facade (stats polling, like RelayController)

@MainActor
final class SatelliteReceiver: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var senderDescription: String?
    @Published private(set) var receivedPackets = 0
    @Published private(set) var concealedFrames = 0
    @Published private(set) var resendRequests = 0
    @Published private(set) var bufferedMs: Double = 0
    @Published var volume: Float = 1 { didSet { engine.setVolume(volume) } }

    private let engine = SatelliteEngine()
    private var pollTimer: Timer?

    func startListening() {
        engine.start()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshFromEngine()
            }
        }
    }

    func stopListening() {
        pollTimer?.invalidate()
        pollTimer = nil
        engine.stop()
        refreshFromEngine()
    }

    private func refreshFromEngine() {
        let snap = engine.currentSnapshot
        isListening = snap.listening
        senderDescription = snap.sender
        receivedPackets = snap.received
        concealedFrames = snap.concealed
        resendRequests = snap.resends
        bufferedMs = snap.bufferedMs
    }
}

// MARK: - UI

struct ReceiverView: View {
    @EnvironmentObject private var receiver: SatelliteReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 36, height: 36)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading) {
                    Text("Relay Satellite").font(.title3.weight(.semibold))
                    Text(receiver.isListening ? "Listening on UDP \(SatelliteProtocol.defaultPort)" : "Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(receiver.isListening ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
            }

            Button(receiver.isListening ? "Stop" : "Start Listening") {
                if receiver.isListening {
                    receiver.stopListening()
                } else {
                    receiver.startListening()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.isListening ? .red : .teal)

            if let sender = receiver.senderDescription {
                Label(sender, systemImage: "personalhotspot")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 22) {
                StatView(label: "packets", value: "\(receiver.receivedPackets)")
                StatView(label: "concealed frames", value: "\(receiver.concealedFrames)")
                StatView(label: "resend reqs", value: "\(receiver.resendRequests)")
                StatView(label: "buffer", value: String(format: "%.0f ms", receiver.bufferedMs))
            }

            HStack {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $receiver.volume, in: 0...1).tint(.teal)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text("Raw Float32 PCM over UDP — no codec, bit-exact. Add this Mac's IP in Relay's Satellite receivers section.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct StatView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
