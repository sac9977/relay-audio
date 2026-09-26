// macOS receiver app. The iOS receiver lives in Sources/RelaySatelliteIOS.
#if os(macOS)
import SwiftUI
import AVFoundation
import Network
import Darwin
import os.log
import SatelliteKit

@main
struct SatelliteApp: App {
    @StateObject private var receiver = SatelliteReceiver()

    init() {
        AppFont.activate(defaultsKey: "app.relay.satellite.textScale")
    }

    var body: some Scene {
        WindowGroup("Relay Satellite") {
            ReceiverView()
                .environmentObject(receiver)
                .frame(minWidth: 440, minHeight: 320)
                // Re-renders (and thus re-reads AppFont.scale) on scale change.
                .id(receiver.textScale)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra(
            "Relay Satellite",
            systemImage: receiver.isReceiving
                ? "dot.radiowaves.left.and.right"
                : "antenna.radiowaves.left.and.right"
        ) {
            MenuBarStatusView()
                .environmentObject(receiver)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Local address lookup

/// Best local IPv4 address for display (prefers en* interfaces, skips loopback).
func localIPAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var best: (priority: Int, ip: String)? = nil
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        let entry = p.pointee
        ptr = entry.ifa_next
        guard let sockaddr = entry.ifa_addr,
              sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let sin = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var sinAddr = sin.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let ip = String(cString: buffer)
        guard ip != "127.0.0.1" else { continue }

        let name = String(cString: entry.ifa_name)
        let priority: Int
        if name.hasPrefix("en") { priority = 2 }        // Wi-Fi / Ethernet
        else if name.hasPrefix("utun") { priority = 0 } // VPN tunnels
        else { priority = 1 }
        if best == nil || priority > best!.priority {
            best = (priority, ip)
        }
    }
    return best?.ip
}

// MARK: - Menu bar monitor

struct MenuBarStatusView: View {
    @EnvironmentObject private var receiver: SatelliteReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Relay Satellite").font(AppFont.size(14, .semibold))
                    Text(receiver.isReceiving ? "Receiving audio" : (receiver.isListening ? "Listening" : "Stopped"))
                        .font(AppFont.size(11.5))
                        .foregroundStyle(receiver.isReceiving ? Color.green : Color.secondary)
                }
                Spacer()
                Circle()
                    .fill(receiver.isReceiving ? Color.green : (receiver.isListening ? Color.teal : Color.secondary.opacity(0.4)))
                    .frame(width: 8, height: 8)
            }

            Divider()

            row("On the network as", SatelliteEngine.serviceName)
            row("Address", "\(localIPAddress() ?? "unknown") · port \(SatelliteProtocol.defaultPort)")
            if let sender = receiver.senderDescription {
                row("Sender", sender)
            }

            Divider()

            HStack(spacing: 14) {
                stat("packets", "\(receiver.receivedPackets)")
                stat("concealed", "\(receiver.concealedFrames)")
                stat("resend reqs", "\(receiver.resendRequests)")
                stat("buffer", String(format: "%.0f ms", receiver.bufferedMs))
            }

            if receiver.sampleRateHz > 0 {
                Text(String(format: "Playing at %.1f kHz", receiver.sampleRateHz / 1000))
                    .font(AppFont.size(11.5))
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button {
                if receiver.isListening {
                    receiver.stopListening()
                } else {
                    receiver.startListening()
                }
            } label: {
                Label(receiver.isListening ? "Stop Listening" : "Start Listening",
                      systemImage: receiver.isListening ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.isListening ? .red : .teal)

            Button("Quit Relay Satellite") {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(4)
        .frame(width: 280)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(AppFont.size(11.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(AppFont.size(12))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(AppFont.size(14, .semibold).monospacedDigit())
            Text(label)
                .font(AppFont.size(10.5))
                .foregroundStyle(.secondary)
        }
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
    private var currentVolume: Float = 1

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

    /// Stable Bonjour name for this receiver (the Mac's name). One service per
    /// host: Bonjour auto-uniquifies duplicates ("name (2)") if needed.
    static var serviceName: String {
        Host.current().localizedName ?? "Relay Satellite"
    }

    private static func advertisedName() -> String {
        let name = serviceName
        return name.isEmpty ? "Relay Satellite" : name
    }
    /// Playback rate; tracks the sample rate declared by incoming packets so
    /// a sender capturing at 44.1 kHz plays at 44.1 kHz (not pitch-shifted).
    private(set) var sampleRate: Double = SatelliteProtocol.samplesPerSecond

    struct Snapshot {
        var listening = false
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

            // Advertise on the local network so Relay can discover this
            // receiver without the user typing an IP address.
            listener.service = NWListener.Service(
                name: Self.advertisedName(),
                type: SatelliteProtocol.bonjourServiceType
            )

            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
            log.info("Satellite listening on UDP \(SatelliteProtocol.defaultPort), advertised as \"\(Self.serviceName, privacy: .public)\"")
        } catch {
            log.error("Listener failed: \(error.localizedDescription, privacy: .public)")
        }

        startPlaybackEngine()
        pumpQueue.async { [weak self] in self?.pump() }
        publish()
    }

    func setVolume(_ value: Float) {
        currentVolume = max(0, min(1, value))
        playerNode?.volume = currentVolume
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

    /// Switches playback to a new declared rate (first packet, or a sender
    /// whose capture device changed rates). Flushes queued packets — their
    /// samples belong to the old clock.
    private func ensurePlaybackRate(_ newRate: Double) {
        guard abs(newRate - sampleRate) > 1 else { return }
        let oldRate = Int(sampleRate)
        let newRateInt = Int(newRate)
        log.info("Sender sample rate \(oldRate, privacy: .public) → \(newRateInt, privacy: .public) Hz; rebuilding playback engine")
        sampleRate = newRate
        playerNode?.stop()
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
        // Tear down any previous graph first — an AVAudioEngine must be fully
        // stopped before its nodes can be reused in a new configuration.
        playerNode?.stop()
        engine?.stop()

        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            log.error("Could not create \(Int(self.sampleRate), privacy: .public) Hz playback format")
            return
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        node.volume = currentVolume
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
    @Published private(set) var sampleRateHz: Double = 0
    @Published private(set) var textScale: AppFont.Scale = .comfortable
    @Published var volume: Float = 1 { didSet { engine.setVolume(volume) } }

    /// True while audio is actually flowing (buffer being drained), which is
    /// what the menu-bar glyph keys off.
    var isReceiving: Bool { bufferedMs > 0 }

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

    func setTextScale(_ newScale: AppFont.Scale) {
        textScale = newScale
        AppFont.persist(newScale, defaultsKey: "app.relay.satellite.textScale")
    }

    private func refreshFromEngine() {
        let snap = engine.currentSnapshot
        isListening = snap.listening
        senderDescription = snap.sender
        receivedPackets = snap.received
        concealedFrames = snap.concealed
        resendRequests = snap.resends
        bufferedMs = snap.bufferedMs
        sampleRateHz = snap.sampleRate
    }
}

// MARK: - UI

struct ReceiverView: View {
    @EnvironmentObject private var receiver: SatelliteReceiver
    @State private var autoStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(AppFont.size(19, .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading) {
                    Text("Relay Satellite").font(AppFont.size(22, .semibold))
                    Text(receiver.isListening
                         ? "Listening on UDP \(SatelliteProtocol.defaultPort)" + (receiver.sampleRateHz > 0 ? " · " + String(format: "%.1f kHz", receiver.sampleRateHz / 1000) : "")
                         : "Idle")
                        .font(AppFont.size(13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(receiver.isListening ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
            }

            Button {
                if receiver.isListening {
                    receiver.stopListening()
                } else {
                    receiver.startListening()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: receiver.isListening ? "stop.fill" : "play.fill")
                        .font(AppFont.size(16, .bold))
                    Text(receiver.isListening ? "Stop Listening" : "Start Listening")
                        .font(AppFont.size(15, .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(receiver.isListening ? .red : .teal)

            if let sender = receiver.senderDescription {
                Label(sender, systemImage: "personalhotspot")
                    .font(AppFont.size(15))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 18) {
                StatView(label: "packets", value: "\(receiver.receivedPackets)")
                Spacer(minLength: 8)
                StatView(label: "concealed", value: "\(receiver.concealedFrames)")
                Spacer(minLength: 8)
                StatView(label: "resend reqs", value: "\(receiver.resendRequests)")
                Spacer(minLength: 8)
                StatView(label: "buffer", value: String(format: "%.0f ms", receiver.bufferedMs))
            }

            HStack {
                Image(systemName: "speaker.fill").font(AppFont.size(13)).foregroundStyle(.secondary)
                Slider(value: $receiver.volume, in: 0...1).tint(.teal)
                Image(systemName: "speaker.wave.3.fill").font(AppFont.size(13)).foregroundStyle(.secondary)
            }

            HStack {
                Text("Text size")
                    .font(AppFont.size(15))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { receiver.textScale },
                    set: { receiver.setTextScale($0) }
                )) {
                    ForEach(AppFont.Scale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            Spacer()

            Text("Raw Float32 PCM over UDP — no codec, bit-exact. Relay discovers this receiver automatically; it also appears as \"\(SatelliteEngine.serviceName)\" on the network.")
                .font(AppFont.size(13))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .onAppear {
            // A receiver should be ready to receive: start listening on
            // launch (this also registers the Bonjour advertisement).
            if !autoStarted {
                autoStarted = true
                receiver.startListening()
            }
        }
    }
}

private struct StatView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(AppFont.size(18, .semibold).monospacedDigit())
            Text(label).font(AppFont.size(11.5)).foregroundStyle(.secondary)
        }
    }
}

#endif // os(macOS)
