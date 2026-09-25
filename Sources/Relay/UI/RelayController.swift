import Foundation
import CoreAudio
import AVFoundation
import os
import SatelliteKit

/// Top-level orchestrator: scans sources/outputs, owns the capture engine and
/// one sink engine per enabled output, persists preferences, and reacts live
/// to devices/apps appearing or disappearing.
@MainActor
final class RelayController: ObservableObject {
    enum TransportState: Equatable {
        case stopped
        case starting
        case streaming
        case failed(String)
        /// Stopped by the Silence Monitor after prolonged silence.
        case silenceStopped(seconds: Int)
    }

    // MARK: Published UI state

    @Published private(set) var transportState: TransportState = .stopped
    @Published private(set) var processes: [AudioProcess] = []
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var level: Float = 0
    @Published private(set) var thisMacName: String = Host.current().localizedName ?? "This Mac"
    /// Live per-output health, keyed by output UID ("__thisMac" for local).
    @Published private(set) var healthByUID: [String: SinkHealth] = [:]
    /// Rolling sync-offset history per output (milliseconds), oldest first.
    /// Drives the live sync-scope chart.
    @Published private(set) var offsetHistoryByUID: [String: [Double]] = [:]
    /// Capture rate — converts frames to ms for display.
    @Published private(set) var captureSampleRate: Double = 48000
    /// ±ms band inside which sinks count as phase-locked.
    var syncToleranceMs: Double { lowLatencyMode ? 3.0 : 6.0 }
    /// Incremented on every device/process change so views can animate.
    @Published private(set) var deviceListRevision = 0

    // MARK: Settings (persisted)

    @Published var selectedSourceObjectID: AudioObjectID? {
        didSet { persist() }
    }
    @Published var enabledOutputUIDs: Set<String> {
        didSet { persist() }
    }
    @Published var includeThisMac: Bool {
        didSet { persist() }
    }
    @Published var muteSourceLocally: Bool {
        didSet { persist() }
    }
    @Published var masterVolume: Float {
        didSet {
            for sink in sinks { sink.setMasterVolume(masterVolume) }
            persist()
        }
    }
    /// Low-latency profile: ~60 ms path for video lip sync, less jitter
    /// tolerance. Restarting the stream applies it.
    @Published var lowLatencyMode: Bool {
        didSet {
            persist()
            if isStreaming { restartTransport() }
        }
    }
    /// Silence Monitor: auto-stop the stream when the source stays below the
    /// silence threshold for `silenceTimeoutSeconds`.
    @Published var silenceMonitorEnabled: Bool {
        didSet { persist() }
    }
    @Published var silenceTimeoutSeconds: Double {
        didSet { persist() }
    }
    /// Seconds of continuous silence so far (for the live countdown UI).
    @Published private(set) var silenceSeconds: Int = 0
    /// Relay Satellite receiver hosts (IPs), persisted.
    @Published var receiverHosts: [String] {
        didSet { persist() }
    }
    /// Live network sink stats keyed by "net:<host>".
    @Published private(set) var networkStatsByUID: [String: NetworkSinkEngine.Stats] = [:]

    static let autoStartKey = "autoStartOnLaunch"
    static let thisMacUID = "__thisMac"

    var isAutoStartEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoStartKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoStartKey) }
    }

    // MARK: Engine ownership

    private let captureEngine = CaptureEngine()
    private var sinks: [SinkEngine] = []
    private var networkSinks: [NetworkSinkEngine] = []
    private var ringByUID: [String: SPSCRing] = [:]
    private var deviceByUID: [String: AudioOutputDevice] = [:]
    private var meterTimer: Timer?
    private let log = Logger(subsystem: "app.relay", category: "controller")

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let sourceObjectID = "sourceObjectID"
        static let enabledOutputs = "enabledOutputUIDs"
        static let includeThisMac = "includeThisMac"
        static let muteSourceLocally = "muteSourceLocally"
        static let masterVolume = "masterVolume"
        static let lowLatencyMode = "lowLatencyMode"
        static let silenceMonitorEnabled = "silenceMonitorEnabled"
        static let silenceTimeoutSeconds = "silenceTimeoutSeconds"
        static let receiverHosts = "receiverHosts"
    }

    // Silence Monitor state. Peaks below this are treated as silence (~-66 dB).
    private let silenceThreshold: Float = 0.0005
    private var silenceAccumulator: TimeInterval = 0

    // Live device/process tracking (Core Audio property listeners).
    private var listenersInstalled = false
    private var refreshDebounce: DispatchWorkItem?
    private var systemDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var systemProcessesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var processListenerBlock: AudioObjectPropertyListenerBlock?

    var isStreaming: Bool { transportState == .streaming }

    var selectedSource: AudioProcess? {
        processes.first { $0.objectID == selectedSourceObjectID }
    }

    var enabledDeviceCount: Int { enabledOutputUIDs.count }

    /// One-line summary of where audio will play, for the menu bar panel.
    var enabledOutputSummary: String {
        var names: [String] = []
        if includeThisMac { names.append(thisMacName) }
        names.append(contentsOf: enabledOutputUIDs.compactMap { deviceByUID[$0]?.name }.sorted())
        return names.isEmpty ? "No outputs selected" : names.joined(separator: ", ")
    }

    init() {
        let storedVolume = defaults.object(forKey: Keys.masterVolume) as? Float
        masterVolume = storedVolume ?? 1.0

        includeThisMac = defaults.object(forKey: Keys.includeThisMac) as? Bool ?? true
        muteSourceLocally = defaults.object(forKey: Keys.muteSourceLocally) as? Bool ?? false
        lowLatencyMode = defaults.object(forKey: Keys.lowLatencyMode) as? Bool ?? false
        silenceMonitorEnabled = defaults.object(forKey: Keys.silenceMonitorEnabled) as? Bool ?? false
        silenceTimeoutSeconds = defaults.object(forKey: Keys.silenceTimeoutSeconds) as? Double ?? 300
        enabledOutputUIDs = Set(defaults.stringArray(forKey: Keys.enabledOutputs) ?? [])
        selectedSourceObjectID = defaults.object(forKey: Keys.sourceObjectID) as? AudioObjectID
        receiverHosts = defaults.stringArray(forKey: Keys.receiverHosts) ?? []

        refreshDevices()
        installChangeListeners()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollRuntimeStats()
            }
        }
    }

    deinit {
        if listenersInstalled, let deviceBlock = deviceListenerBlock, let processBlock = processListenerBlock {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID.systemObject, &systemDevicesAddress, nil, deviceBlock)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID.systemObject, &systemProcessesAddress, nil, processBlock)
        }
    }

    // MARK: Live device & process tracking

    /// Listens for device/process changes at the HAL level and refreshes the
    /// lists live (Bluetooth speaker wakes, AirPlay receiver appears, app
    /// starts playing, …). Debounced: connect storms fire many callbacks.
    private func installChangeListeners() {
        deviceListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        processListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        guard let deviceBlock = deviceListenerBlock, let processBlock = processListenerBlock else { return }

        let status1 = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.systemObject, &systemDevicesAddress, nil, deviceBlock
        )
        let status2 = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.systemObject, &systemProcessesAddress, nil, processBlock
        )
        if status1 == noErr, status2 == noErr {
            listenersInstalled = true
            log.info("Live change listeners installed")
        } else {
            log.warning("Listener install failed: \(status1)/\(status2)")
        }
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        refreshDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)

        // While streaming, re-evaluate the sink set shortly after the lists
        // settle so newly arrived devices attach without a capture restart.
        if isStreaming {
            let rebuild = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.syncSinksWithCurrentDevices() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: rebuild)
        }
    }

    /// While streaming: attach sinks for newly enabled/available outputs and
    /// detach sinks whose device vanished. Avoids a full capture restart.
    private func syncSinksWithCurrentDevices() {
        guard isStreaming else { return }

        let activeUIDs = Set(sinks.map(\.uid))
        var wantedUIDs: Set<String> = []
        if includeThisMac { wantedUIDs.insert(Self.thisMacUID) }
        for uid in enabledOutputUIDs where deviceByUID[uid] != nil {
            wantedUIDs.insert(uid)
        }

        // Detach sinks whose device is gone.
        for sink in sinks where !wantedUIDs.contains(sink.uid) {
            sink.stop()
            log.info("Live detach: \(sink.displayName, privacy: .public)")
        }
        sinks.removeAll { !wantedUIDs.contains($0.uid) }
        ringByUID = Dictionary(uniqueKeysWithValues: sinks.map { ($0.uid, $0.ring) })

        // Attach sinks for wanted outputs that aren't streaming yet.
        for uid in wantedUIDs.sorted() where !activeUIDs.contains(uid) {
            let kind: SinkEngine.Kind
            if uid == Self.thisMacUID {
                kind = .thisMac(deviceName: thisMacName)
            } else if let device = deviceByUID[uid] {
                kind = .device(device)
            } else {
                continue
            }
            let sink = SinkEngine(kind: kind, uid: uid, lowLatency: lowLatencyMode)
            sink.producerPosition = { [captureEngine] in
                captureEngine.producerFramePosition()
            }
            do {
                try sink.start(volume: masterVolume, sampleRate: captureEngine.currentSampleRate ?? 48000)
                sink.setUserVolume(speakerVolume(uid: uid))
                sink.setMuted(speakerMuted(uid: uid))
                applyDelayTrimToSink(sink)
                sinks.append(sink)
                ringByUID[uid] = sink.ring
                log.info("Live attach: \(sink.displayName, privacy: .public)")
            } catch {
                log.warning("Live attach failed for \(sink.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        pushAllRingsToCapture()
        healthByUID = healthByUID.filter { wantedUIDs.contains($0.key) }
    }

    // MARK: Runtime stats polling

    private func pollRuntimeStats() {
        guard isStreaming else {
            if !healthByUID.isEmpty { healthByUID = [:] }
            if silenceSeconds != 0 { silenceSeconds = 0 }
            silenceAccumulator = 0
            return
        }
        level = captureEngine.level
        var health: [String: SinkHealth] = [:]
        for sink in sinks {
            health[sink.uid] = sink.healthStats
        }
        healthByUID = health

        var netStats: [String: NetworkSinkEngine.Stats] = [:]
        for net in networkSinks {
            netStats[net.uid] = net.stats
        }
        if networkStatsByUID != netStats { networkStatsByUID = netStats }

        // Append to the sync-scope history (trimmed ring per output).
        let maxHistory = 180 // ~12 s at the 15 Hz poll cadence
        for sink in sinks {
            let offsetMs = sink.healthStats.syncOffsetMs
            var history = offsetHistoryByUID[sink.uid] ?? []
            history.append(offsetMs)
            if history.count > maxHistory {
                history.removeFirst(history.count - maxHistory)
            }
            offsetHistoryByUID[sink.uid] = history
        }
        for staleUID in offsetHistoryByUID.keys where health[staleUID] == nil {
            offsetHistoryByUID.removeValue(forKey: staleUID)
        }

        // Silence Monitor: accumulate quiet time, stop the transport when the
        // configurable timeout is reached.
        guard silenceMonitorEnabled else {
            silenceAccumulator = 0
            if silenceSeconds != 0 { silenceSeconds = 0 }
            return
        }
        if level < silenceThreshold {
            silenceAccumulator += 1.0 / 15.0 // poll cadence
            let rounded = Int(silenceAccumulator)
            if rounded != silenceSeconds { silenceSeconds = rounded }
            if silenceAccumulator >= silenceTimeoutSeconds {
                log.info("Silence Monitor: source silent for \(Int(self.silenceAccumulator))s — stopping transport")
                stopTransport()
                transportState = .silenceStopped(seconds: Int(silenceTimeoutSeconds))
            }
        } else {
            silenceAccumulator = 0
            if silenceSeconds != 0 { silenceSeconds = 0 }
        }
    }

    // MARK: Per-speaker mix (persisted per UID)

    func speakerVolume(uid: String) -> Float {
        defaults.object(forKey: "speakerVolume.\(uid)") as? Float ?? 1.0
    }

    func speakerMuted(uid: String) -> Bool {
        defaults.bool(forKey: "speakerMuted.\(uid)")
    }

    func setSpeakerVolume(uid: String, _ value: Float) {
        defaults.set(value, forKey: "speakerVolume.\(uid)")
        sinks.first { $0.uid == uid }?.setUserVolume(value)
    }

    func setSpeakerMuted(uid: String, _ muted: Bool) {
        defaults.set(muted, forKey: "speakerMuted.\(uid)")
        sinks.first { $0.uid == uid }?.setMuted(muted)
    }

    /// Per-speaker delay trim in milliseconds (persisted per UID). Compensates
    /// fixed Bluetooth/AirPlay transport skew so both ears agree.
    func speakerDelayTrimMs(uid: String) -> Double {
        defaults.object(forKey: "speakerDelayTrimMs.\(uid)") as? Double ?? 0
    }

    func setSpeakerDelayTrim(uid: String, milliseconds: Double) {
        let clamped = max(0, min(500, milliseconds))
        defaults.set(clamped, forKey: "speakerDelayTrimMs.\(uid)")
        guard let sampleRate = sinks.first(where: { $0.uid == uid }).map({ _ in captureSampleRate }),
              sampleRate > 0 else { return }
        let frames = Int(clamped / 1000.0 * sampleRate)
        sinks.first { $0.uid == uid }?.setDelayTrim(frames: frames)
    }

    private func applyDelayTrimToSink(_ sink: SinkEngine) {
        let ms = speakerDelayTrimMs(uid: sink.uid)
        guard ms > 0, captureSampleRate > 0 else { return }
        sink.setDelayTrim(frames: Int(ms / 1000.0 * captureSampleRate))
    }

    // MARK: Network receivers (Relay Satellite)

    func addReceiver(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !receiverHosts.contains(trimmed) else { return }
        receiverHosts.append(trimmed)
        if isStreaming {
            startNetworkSink(host: trimmed)
            pushAllRingsToCapture()
        }
    }

    func removeReceiver(host: String) {
        receiverHosts.removeAll { $0 == host }
        if let sink = networkSinks.first(where: { $0.host == host }) {
            sink.stop()
            networkSinks.removeAll { $0.host == host }
            pushAllRingsToCapture()
        }
    }

    private func startNetworkSink(host: String) {
        let sink = NetworkSinkEngine(uid: "net:\(host)", host: host) { [captureEngine] in
            captureEngine.producerFramePosition()
        }
        sink.start()
        networkSinks.append(sink)
    }

    private func pushAllRingsToCapture() {
        captureEngine.updateSinks(sinks.map(\.ring) + networkSinks.map(\.ring))
    }

    // MARK: Scanning

    func refreshDevices() {
        processes = AudioProcessScanner.scan()
        outputDevices = OutputDeviceScanner.scan()
        deviceByUID = Dictionary(uniqueKeysWithValues: outputDevices.map { ($0.uid, $0) })
        deviceListRevision += 1

        // Drop enabled outputs that vanished (unplugged dongle, left network…).
        // Guard: an EMPTY scan is a failed probe, not the truth — never wipe
        // the user's selections because of a transient Core Audio hiccup.
        if !outputDevices.isEmpty {
            let availableUIDs = Set(outputDevices.map(\.uid))
            let stale = enabledOutputUIDs.subtracting(availableUIDs)
            if !stale.isEmpty {
                enabledOutputUIDs.subtract(stale)
            }
        }

        // Validate remembered source: the AudioObjectID is session-scoped, so
        // match on PID instead when possible.
        if let rememberedPID = defaults.object(forKey: "sourcePID") as? pid_t,
           let match = processes.first(where: { $0.pid == rememberedPID }) {
            selectedSourceObjectID = match.objectID
        } else if let selected = selectedSourceObjectID, !processes.contains(where: { $0.objectID == selected }) {
            selectedSourceObjectID = nil
        }
    }

    func select(source: AudioProcess) {
        selectedSourceObjectID = source.objectID
        defaults.set(source.pid, forKey: "sourcePID")
        if isStreaming {
            restartTransport()
        }
    }

    func toggleOutput(uid: String) {
        if enabledOutputUIDs.contains(uid) {
            enabledOutputUIDs.remove(uid)
        } else {
            enabledOutputUIDs.insert(uid)
        }
        if isStreaming {
            rebuildSinks()
        }
    }

    func toggleThisMac() {
        includeThisMac.toggle()
        if isStreaming {
            rebuildSinks()
        }
    }

    // MARK: Transport

    func startTransport() {
        guard !isStreaming else { return }
        do {
            try startInternal()
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            transportState = .failed(error.localizedDescription)
        }
    }

    func stopTransport() {
        captureEngine.stop()
        for sink in sinks { sink.stop() }
        sinks = []
        for net in networkSinks { net.stop() }
        networkSinks = []
        ringByUID = [:]
        level = 0
        healthByUID = [:]
        offsetHistoryByUID = [:]
        networkStatsByUID = [:]
        transportState = .stopped
    }

    func restartTransport() {
        stopTransport()
        startTransport()
    }

    private func startInternal() throws {
        guard let source = selectedSource else {
            throw RelayError.message("Pick an app to capture first.")
        }

        var sinkSpecs: [(uid: String, kind: SinkEngine.Kind)] = []
        if includeThisMac {
            sinkSpecs.append((Self.thisMacUID, .thisMac(deviceName: thisMacName)))
        }
        for uid in enabledOutputUIDs.sorted() {
            if let device = deviceByUID[uid] {
                sinkSpecs.append((uid, .device(device)))
            }
        }
        guard !sinkSpecs.isEmpty || !receiverHosts.isEmpty else {
            throw RelayError.message("Enable at least one output or add a Satellite receiver.")
        }

        transportState = .starting

        // Phase 1: create the tap first so sinks can be built at the
        // capture rate (feeding them at the device rate would pitch-shift).
        let captureRate = try captureEngine.prepare(source: source, muteWhenTapped: muteSourceLocally)
        captureSampleRate = captureRate
        offsetHistoryByUID = [:]
        log.info("Capture rate: \(Int(captureRate)) Hz, lowLatencyMode=\(self.lowLatencyMode)")

        // Phase 2: build sinks at that rate, then start pulling audio.
        sinks = []
        ringByUID = [:]
        for spec in sinkSpecs {
            let sink = SinkEngine(kind: spec.kind, uid: spec.uid, lowLatency: lowLatencyMode)
            sink.producerPosition = { [captureEngine] in
                captureEngine.producerFramePosition()
            }
            do {
                try sink.start(volume: masterVolume, sampleRate: captureRate)
                sink.setUserVolume(speakerVolume(uid: spec.uid))
                sink.setMuted(speakerMuted(uid: spec.uid))
                applyDelayTrimToSink(sink)
            } catch {
                log.warning("Sink \(sink.displayName, privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                continue
            }
            sinks.append(sink)
            ringByUID[spec.uid] = sink.ring
        }
        // Phase 3: network receivers get their own pre-rolling sinks.
        networkSinks = []
        for host in receiverHosts {
            startNetworkSink(host: host)
        }

        let allRings = sinks.map(\.ring) + networkSinks.map(\.ring)
        guard !allRings.isEmpty else {
            captureEngine.stop()
            throw RelayError.message("None of the enabled outputs could start.")
        }

        do {
            try captureEngine.begin(rings: allRings)
        } catch {
            for sink in sinks { sink.stop() }
            sinks = []
            for net in networkSinks { net.stop() }
            networkSinks = []
            throw error
        }

        transportState = .streaming
    }

    private func rebuildSinks() {
        guard isStreaming else { return }
        // Re-run start with the current selection; capture restarts too, which
        // is acceptable for v1 (sub-second hiccup) and keeps locking simple.
        restartTransport()
    }

    // MARK: Persistence

    private func persist() {
        defaults.set(receiverHosts, forKey: Keys.receiverHosts)
        defaults.set(enabledOutputUIDs.sorted(), forKey: Keys.enabledOutputs)
        defaults.set(includeThisMac, forKey: Keys.includeThisMac)
        defaults.set(muteSourceLocally, forKey: Keys.muteSourceLocally)
        defaults.set(masterVolume, forKey: Keys.masterVolume)
        defaults.set(lowLatencyMode, forKey: Keys.lowLatencyMode)
        defaults.set(silenceMonitorEnabled, forKey: Keys.silenceMonitorEnabled)
        defaults.set(silenceTimeoutSeconds, forKey: Keys.silenceTimeoutSeconds)
        if let id = selectedSourceObjectID {
            defaults.set(Int(id), forKey: Keys.sourceObjectID)
        }
    }
}
