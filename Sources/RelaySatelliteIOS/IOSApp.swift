import SwiftUI
import AVFoundation
import Network
import os
import SatelliteKit

/// iOS Satellite receiver. Same wire protocol and playback strategy as the
/// macOS receiver: raw interleaved stereo Float32 PCM over UDP, in-sequence
/// drain into AVAudioPCMBuffer, NACK resends, silence concealment.
final class IOSReceiverEngine {
    private let log = Logger(subsystem: "app.relay.satellite.ios", category: "engine")

    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let pumpQueue = DispatchQueue(label: "app.relay.satellite.ios.pump", qos: .userInitiated)

    private var stopped = true
    private var senderDescription: String?
    private var lastSenderEndpoint: NWEndpoint?
    private var nackConnection: NWConnection?

    private let packetLock = NSLock()
    private var packetsBySequence: [UInt64: (producerFrame: UInt64, payload: Data)] = [:]
    private var expectedSequence: UInt64?
    private var missingSince: [UInt64: DispatchTime] = [:]

    private var receivedPackets = 0
    private var concealedFrames = 0
    private var resendRequests = 0
    private var bufferedMs: Double = 0

    private let samplesPerPacket = SatelliteProtocol.samplesPerPacket
    private let concealAfterMs = 90.0
    private(set) var sampleRate: Double = SatelliteProtocol.samplesPerSecond

    struct Snapshot {
        var listening = false
        var receiving = false
        var sender: String?
        var received = 0
        var concealed = 0
        var resends = 0
        var bufferedMs: Double = 0
        var sampleRate: Double = 0
    }

    private let snapshotLock = NSLock()
    private var listening = false
    private func publish() {
        snapshotLock.lock()
        snapshot = Snapshot(
            listening: listening,
            receiving: bufferedMs > 0,
            sender: senderDescription,
            received: receivedPackets,
            concealed: concealedFrames,
            resends: resendRequests,
            bufferedMs: bufferedMs,
            sampleRate: sampleRate
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

        // iOS: audio must be playback-activated before the engine runs,
        // otherwise scheduleBuffer completion handlers stall silently.
        #if canImport(UIKit)
        Task {
            _ = try? await AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            _ = try? await AVAudioSession.sharedInstance().setActive(true)
        }
        #endif

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
            listener.service = NWListener.Service(
                name: Self.advertisedName(),
                type: SatelliteProtocol.bonjourServiceType
            )
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            log.info("iOS Satellite listening on UDP \(SatelliteProtocol.defaultPort)")
        } catch {
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }

        startPlaybackEngine()
        pumpQueue.async { [weak self] in self?.pump() }
        publish()
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
        log.info("iOS Satellite stopped")
    }

    static func advertisedName() -> String {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        if !name.isEmpty { return name }
        #endif
        return "iPhone"
    }

    private func accept(_ connection: NWConnection) {
        senderDescription = connection.endpoint.debugDescription
        lastSenderEndpoint = connection.endpoint
        publish()
        receiveLoop(on: connection)
    }

    private func ensurePlaybackRate(_ newRate: Double) {
        guard abs(newRate - sampleRate) > 1 else { return }
        sampleRate = newRate
        packetLock.lock()
        packetsBySequence.removeAll()
        missingSince.removeAll()
        expectedSequence = nil
        packetLock.unlock()
        startPlaybackEngine()
        pumpQueue.async { [weak self] in self?.pump() }
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, let header = SatelliteProtocol.decodeDataPacket(data) {
                let payload = data.subdata(in: header.payloadRange)
                if abs(header.sampleRate - self.sampleRate) > 1 {
                    self.ensurePlaybackRate(header.sampleRate)
                }
                self.packetLock.lock()
                if self.expectedSequence == nil { self.expectedSequence = header.sequence }
                self.packetsBySequence[header.sequence] = (header.producerFrame, payload)
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
        playerNode?.stop()
        engine?.stop()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            log.error("Engine failed at \(Int(self.sampleRate), privacy: .public) Hz: \(error.localizedDescription, privacy: .public)")
            return
        }
        node.play()
        self.engine = engine
        self.playerNode = node
    }

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

// MARK: - MainActor facade

@MainActor
final class IOSReceiver: ObservableObject {
    @Published private(set) var snap = IOSReceiverEngine.Snapshot()

    private let engine = IOSReceiverEngine()
    private var pollTimer: Timer?

    func start() {
        engine.start()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snap = self.engine.currentSnapshot
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        engine.stop()
    }
}

// MARK: - UI

struct IOSReceiverView: View {
    @StateObject private var receiver = IOSReceiver()
    @State private var autoStarted = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                    .shadow(color: .teal.opacity(0.4), radius: 8, y: 3)
                Image(systemName: receiver.snap.receiving ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Relay Satellite")
                .font(.system(size: 26, weight: .bold))
            Text(receiver.snap.listening
                 ? "Discoverable as “\(IOSReceiverEngine.advertisedName())”"
                 : "Stopped")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let sender = receiver.snap.sender {
                Label(sender, systemImage: "personalhotspot")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 20) {
                stat("packets", "\(receiver.snap.received)")
                stat("concealed", "\(receiver.snap.concealed)")
                stat("resends", "\(receiver.snap.resends)")
                stat("buffer", String(format: "%.0f ms", receiver.snap.bufferedMs))
            }
            .padding(.vertical, 10)

            Button {
                if receiver.snap.listening {
                    receiver.stop()
                } else {
                    receiver.start()
                }
            } label: {
                Text(receiver.snap.listening ? "Stop Receiving" : "Start Receiving")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.snap.listening ? .red : .teal)
            .padding(.horizontal, 24)

            Spacer()

            Text("Raw Float32 PCM over UDP · bit-exact · joins Relay's sync group")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
        }
        .onAppear {
            // A receiver should be ready to receive: start listening on
            // launch so Relay discovers the phone immediately.
            if !autoStarted {
                autoStarted = true
                receiver.start()
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

@main
struct IOSReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            IOSReceiverView()
                .preferredColorScheme(.dark)
        }
    }
}
