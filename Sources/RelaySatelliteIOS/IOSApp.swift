import SwiftUI
import AVFoundation
import Network
import os
import SatelliteKit

// MARK: - Sender mode (cast this iPhone's mic to a Relay Mac)

/// Casts microphone audio to a Relay Mac's bridge: browse _relay-bridge._udp,
/// pair with the 4-digit code shown in Relay, then send raw PCM data packets
/// (RLR1 v2) paced in real time from an AVAudioEngine input tap.
@MainActor
final class IOSSender: ObservableObject {
    enum Phase: Equatable {
        case idle
        case pairing
        case casting
        case failed(String)
    }

    struct BridgeCandidate: Identifiable, Equatable {
        let id: String          // service endpoint identity
        let name: String
        let code: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidates: [BridgeCandidate] = []
    @Published private(set) var sentPackets = 0
    @Published private(set) var level: Float = 0

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var engine: AVAudioEngine?
    private let queue = DispatchQueue(label: "app.relay.sender", qos: .userInitiated)
    private var streamID: UInt32 = 0
    private var sequence: UInt64 = 0
    private var producerFrame: UInt64 = 0
    private var pending: [Float] = []
    private let pendingLock = NSLock()

    func startBrowsing() {
        stopCasting()
        let browser = NWBrowser(
            for: .bonjour(type: "relay-bridge._udp", domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [BridgeCandidate] = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                let code: String?
                if case let .bonjour(txtRecord) = result.metadata {
                    code = PairingCode.code(fromTXT: txtRecord)
                } else {
                    code = nil
                }
                guard let code else { continue }
                let id = "\(name)@\(code)"
                found.append(BridgeCandidate(id: id, name: name, code: code))
            }
            found.sort { $0.name < $1.name }
            Task { @MainActor in self.candidates = found }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        candidates = []
    }

    /// Pair with the chosen bridge, then start casting mic audio.
    func cast(to candidate: BridgeCandidate) {
        phase = .pairing
        let client = PairingClient()
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = "iPhone"
        #endif
        client.pair(host: candidate.name, code: candidate.code, deviceName: deviceName) { [weak self] outcome in
            Task { @MainActor in
                guard let self else { return }
                switch outcome {
                case .paired(_, let streamID):
                    self.streamID = streamID
                    self.beginCasting(host: candidate.name)
                case .rejected, .timedOut:
                    self.phase = .failed("Pairing failed — check the code and try again")
                }
            }
        }
    }

    func stopCasting() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        connection?.cancel()
        connection = nil
        if phase == .casting { phase = .idle }
        level = 0
    }

    private func beginCasting(host: String) {
        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: SatelliteProtocol.defaultPort)!,
            using: .udp
        )
        conn.start(queue: queue)
        connection = conn

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            phase = .failed("No microphone available")
            return
        }
        // Convert everything to 48 kHz stereo float before packetizing.
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: SatelliteProtocol.samplesPerSecond, channels: 2)!
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            phase = .failed("Could not convert input format")
            return
        }

        input.installTap(onBus: 0, bufferSize: 4800, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // RMS level for the UI.
            if let channel = buffer.floatChannelData?[0] {
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { let s = channel[i]; sum += s * s }
                let rms = sqrt(sum / Float(max(n, 1)))
                Task { @MainActor in self.level = min(1, rms * 4) }
            }
            // Convert to 48k stereo into `pending`.
            let ratio = SatelliteProtocol.samplesPerSecond / inputFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { return }
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard error == nil, let src = outBuffer.floatChannelData else { return }
            let frames = Int(outBuffer.frameLength)
            var interleaved = [Float](repeating: 0, count: frames * 2)
            for f in 0..<frames {
                interleaved[f * 2] = src[0][f]
                interleaved[f * 2 + 1] = src[1][f]
            }
            self.pendingLock.lock()
            self.pending.append(contentsOf: interleaved)
            self.pendingLock.unlock()
            self.drainPackets()
        }

        do {
            try engine.start()
        } catch {
            phase = .failed("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        self.engine = engine
        phase = .casting
    }

    /// Packetize `pending` into 1024-frame RLR1 packets; the input tap
    /// delivers roughly real-time chunks, so pacing follows the mic clock.
    private func drainPackets() {
        pendingLock.lock()
        while pending.count >= SatelliteProtocol.samplesPerPacket * 2 {
            let chunk = Array(pending.prefix(SatelliteProtocol.samplesPerPacket * 2))
            pending.removeFirst(SatelliteProtocol.samplesPerPacket * 2)
            pendingLock.unlock()

            let packet = chunk.withUnsafeBufferPointer { buffer in
                SatelliteProtocol.encodeDataPacket(
                    streamID: streamID,
                    sequence: sequence,
                    producerFrame: producerFrame,
                    payload: UnsafeRawBufferPointer(buffer),
                    sampleRate: SatelliteProtocol.samplesPerSecond
                )
            }
            connection?.send(content: packet, completion: .contentProcessed { _ in })
            sequence += 1
            producerFrame += UInt64(SatelliteProtocol.samplesPerPacket)
            sentPackets += 1
            pendingLock.lock()
        }
        pendingLock.unlock()
    }
}

// MARK: - Receiver engine

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
    private var listening = false
    private var senderDescription: String?
    private var lastSenderEndpoint: NWEndpoint?
    /// The accepted data connection — NACKs ride it so replies share the
    /// listener's :51510 source port (senders filter by source).
    private var dataConnection: NWConnection?

    private let packetLock = NSLock()
    private var packetsBySequence: [UInt64: (producerFrame: UInt64, payload: Data)] = [:]
    private var expectedSequence: UInt64?
    private var missingSince: [UInt64: DispatchTime] = [:]
    /// Stream ID of the current sender — NACKs must echo it so the sender's
    /// filter accepts them (a streamID-0 NACK is dropped by every sender).
    private var activeStreamID: UInt32 = 0

    private var receivedPackets = 0
    private var concealedFrames = 0
    private var resendRequests = 0
    private var bufferedMs: Double = 0
    private var lastDataAt: DispatchTime?

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
                type: SatelliteProtocol.bonjourServiceType // "_relay-sat._udp"
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
        dataConnection?.cancel()
        dataConnection = nil
        playerNode?.stop()
        engine?.stop()
        engine = nil
        playerNode = nil
        listening = false
        packetLock.lock()
        packetsBySequence.removeAll()
        packetLock.unlock()
        lastDataAt = nil
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
        // New peer: reset stream state and swap the NACK path.
        dataConnection?.cancel()
        dataConnection = connection
        packetLock.lock()
        expectedSequence = nil
        packetsBySequence.removeAll()
        missingSince.removeAll()
        packetLock.unlock()
        publish()
        // CRITICAL: listener-accepted connections must be started before
        // receiveMessage delivers anything (same latent bug as macOS side).
        connection.start(queue: .global(qos: .userInitiated))
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
                self.lastDataAt = DispatchTime.now()
                self.packetLock.lock()
                self.activeStreamID = header.streamID
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

        // Stream idle watchdog (same rationale as the macOS receiver):
        // with no data for 2 s, stop concealing forward and await a sender.
        if let last = lastDataAt,
           DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds > 2_000_000_000,
           packetsBySequence.isEmpty {
            expectedSequence = nil
            missingSince.removeAll()
            lastDataAt = nil
            packetLock.unlock()
            pumpQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.pump() }
            return
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
                    let nack = SatelliteProtocol.encodeNack(streamID: activeStreamID, missingSequence: seq, count: 8)
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
        dataConnection?.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - MainActor receiver facade

@MainActor
final class IOSReceiver: ObservableObject {
    @Published private(set) var snap = IOSReceiverEngine.Snapshot()

    private let engine = IOSReceiverEngine()
    private var pollTimer: Timer?
    private var statsLogCounter = 0

    func start() {
        engine.start()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.snap = self.engine.currentSnapshot
                // 1 Hz stats breadcrumb: makes E2E verification possible in
                // the simulator, where NACK replies can't reach loopback.
                self.statsLogCounter += 1
                if self.statsLogCounter % 10 == 0 {
                    let s = self.snap
                    Logger(subsystem: "app.relay.satellite.ios", category: "stats").info("rx=\(s.received) concealed=\(s.concealed) resends=\(s.resends) buffer=\(Int(s.bufferedMs))ms rate=\(Int(s.sampleRate))Hz")
                }
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
    @StateObject private var sender = IOSSender()
    @State private var autoStarted = false
    @State private var mode = 0 // 0 = receive, 1 = cast to Mac

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $mode) {
                Text("Receive").tag(0)
                Text("Cast to Mac").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 12)

            if mode == 0 {
                receiverPane
            } else {
                SenderPane(sender: sender)
            }
        }
        .onAppear {
            if !autoStarted {
                autoStarted = true
                receiver.start()
                sender.startBrowsing()
            }
        }
        .onChange(of: mode) { newMode in
            if newMode == 1 { sender.startBrowsing() }
        }
    }

    private var receiverPane: some View {
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
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 17, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sender pane (cast mic to a Relay Mac)

private struct SenderPane: View {
    @ObservedObject var sender: IOSSender

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(LinearGradient(colors: sender.phase == .casting ? [.indigo, .purple] : [.teal, .green],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 88, height: 88)
                Image(systemName: sender.phase == .casting ? "mic.fill" : "mic")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .overlay(
                Circle().stroke(Color.green.opacity(Double(sender.level)), lineWidth: 4)
            )

            switch sender.phase {
            case .idle:
                Text("Pick the Mac you want to cast to")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            case .pairing:
                ProgressView("Pairing…")
            case .casting:
                VStack(spacing: 4) {
                    Text("Casting microphone").font(.system(size: 16, weight: .semibold))
                    Text("\(sender.sentPackets) packets sent")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13)).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            if sender.phase != .casting {
                if sender.candidates.isEmpty {
                    Text("No Relay Mac found streaming on this network.\nStart streaming in Relay first, then use the pairing code shown there.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    ForEach(sender.candidates) { candidate in
                        Button {
                            sender.cast(to: candidate)
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer.and.iphone")
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(candidate.name).font(.system(size: 15, weight: .semibold))
                                    Text("code \(candidate.code)")
                                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12))
                            }
                            .padding(14)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    }
                }
            } else {
                Button {
                    sender.stopCasting()
                } label: {
                    Text("Stop Casting")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 24)
            }

            Spacer()

            Text("Mic audio streams as raw 48 kHz PCM to Relay's bridge — the code must match the one shown in Relay.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
                .padding(.bottom, 12)
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
