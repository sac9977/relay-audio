import SwiftUI
import SatelliteKit

/// Full window UI.
struct RelayMainView: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderBar()
                TransportCard()
                SourceCard()
                OutputsCard()
                SettingsCard()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Re-renders (and thus re-reads AppFont.scale) when the scale changes.
        .id(controller.textScale)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 40)
                    .shadow(color: .teal.opacity(0.35), radius: 5, y: 2)
                Image(systemName: "hifispeaker.2.fill")
                    .font(AppFont.size(21, .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Relay")
                    .font(AppFont.size(26, .bold))
                Text("Any app → every speaker")
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(state: controller.transportState)
        }
    }
}

private struct StatusPill: View {
    let state: RelayController.TransportState

    private var text: String {
        switch state {
        case .stopped: return "Idle"
        case .starting: return "Starting…"
        case .streaming: return "Live"
        case .failed: return "Error"
        case .silenceStopped: return "Auto-stopped"
        }
    }

    private var color: Color {
        switch state {
        case .stopped: return .secondary
        case .starting: return .orange
        case .streaming: return .green
        case .failed: return .red
        case .silenceStopped: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(state == .streaming ? 0.75 : 1)
            Text(text)
                .font(AppFont.size(13, .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Transport

private struct TransportCard: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if controller.isStreaming {
                    controller.stopTransport()
                } else {
                    controller.startTransport()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: controller.isStreaming ? "stop.fill" : "play.fill")
                        .font(AppFont.size(19, .bold))
                    Text(controller.isStreaming ? "Stop" : "Start Streaming")
                        .font(AppFont.size(22, .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isStreaming ? Color.red : Color.teal)
            .disabled(controller.selectedSource == nil && !controller.isStreaming)

            if controller.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    Text("INPUT LEVEL")
                        .font(AppFont.size(11, .bold))
                        .foregroundStyle(.secondary)
                    LevelMeter(level: controller.level)
                        .frame(height: 8)
                }
                .frame(width: 150)
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("PAIRING CODE")
                        .font(AppFont.size(11, .bold))
                        .foregroundStyle(.secondary)
                    Text(controller.pairingCode)
                        .font(AppFont.size(19, .bold).monospacedDigit())
                        .foregroundStyle(.teal)
                        .tracking(3)
                    Text("enter on a sender to cast here")
                        .font(AppFont.size(10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                .help("Any Relay sender can pair with this code while you stream")
            }
        }
    }
}

// MARK: - Source picker (icon tiles)

private struct SourceCard: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "Source",
                subtitle: "The app whose audio gets streamed",
                systemImage: "square.stack.3d.up.fill"
            )

            if controller.processes.isEmpty {
                EmptyHint(text: "No audio apps detected. Play something in Music, Safari, or Spotify and it will appear here.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(controller.processes) { process in
                            ProcessTile(
                                process: process,
                                isSelected: process.objectID == controller.selectedSourceObjectID
                            ) {
                                controller.select(source: process)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 1)
                }
            }
        }
        .cardStyle()
    }
}

private struct ProcessTile: View {
    let process: AudioProcess
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let icon = process.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                        } else {
                            Image(systemName: "app.fill")
                                .font(AppFont.size(28))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 40, height: 40)

                    if process.isPlaying {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
                .frame(height: 42)

                Text(process.name)
                    .font(AppFont.size(12, isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 76)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.teal : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Outputs

private struct OutputsCard: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(
                    title: "Outputs",
                    subtitle: "Where the audio plays — enable as many as you like",
                    systemImage: "speaker.wave.2.fill"
                )
                Spacer()
                Text("\(controller.enabledDeviceCount + (controller.includeThisMac ? 1 : 0)) active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }

            OutputRow(
                uid: RelayController.thisMacUID,
                icon: "laptopcomputer.and.arrow.down",
                iconColors: [.gray, .gray.opacity(0.7)],
                title: controller.thisMacName
            )

            if controller.outputDevices.isEmpty {
                EmptyHint(text: "No other output devices found. Bluetooth and AirPlay speakers appear here automatically once they're set up in System Settings.")
            } else {
                ForEach(controller.outputDevices) { device in
                    OutputRow(
                        uid: device.uid,
                        icon: OutputRow.iconName(for: device.transportLabel),
                        iconColors: OutputRow.iconColors(for: device.transportLabel),
                        title: device.name,
                        badge: device.transportLabel.uppercased()
                    )
                }
            }

            if controller.isStreaming, controller.offsetHistoryByUID.count > 1 {
                Divider()
                SyncScope(
                    history: controller.offsetHistoryByUID,
                    names: outputNamesByUID(),
                    toleranceMs: controller.syncToleranceMs
                )
            }

            Divider()
            SatellitesCard()
        }
        .cardStyle()
    }

    private func outputNamesByUID() -> [String: String] {
        var names: [String: String] = [:]
        if controller.includeThisMac {
            names[RelayController.thisMacUID] = controller.thisMacName
        }
        for device in controller.outputDevices {
            names[device.uid] = device.name
        }
        return names
    }
}

/// Live chart of each output's sync offset vs the shared capture clock.
/// Flat lines near zero = phase-locked; diverging or saw-toothing lines =
/// drift the controller is fighting.
private struct SyncScope: View {
    @EnvironmentObject private var controller: RelayController
    let history: [String: [Double]]
    let names: [String: String]
    let toleranceMs: Double

    private static let palette: [Color] = [.teal, .orange, .mint, .pink, .cyan, .yellow]

    private var seriesKeys: [String] {
        history.keys.sorted()
    }

    private var colorFor: [String: Color] {
        Dictionary(uniqueKeysWithValues: seriesKeys.enumerated().map { index, uid in
            (uid, Self.palette[index % Self.palette.count])
        })
    }

    private var verticalScale: Double {
        // Generous fixed scale keeps the visual meaning stable over time.
        max(20, toleranceMs * 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(AppFont.size(13, .semibold))
                    .foregroundStyle(.secondary)
                Text("SYNC SCOPE")
                    .font(AppFont.size(12, .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(seriesKeys, id: \.self) { uid in
                    if let color = colorFor[uid] {
                        HStack(spacing: 3) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(shortName(names[uid] ?? uid))
                                .font(AppFont.size(11.5))
                                .foregroundStyle(.secondary)
                            if let latest = history[uid]?.last {
                                Text(String(format: "%+.1f ms", latest))
                                    .font(AppFont.size(11.5).monospacedDigit().weight(.medium))
                                    .foregroundStyle(abs(latest) > toleranceMs ? Color.orange : Color.primary.opacity(0.75))
                            }
                        }
                    }
                }
            }

            Canvas { context, size in
                let scale = size.height / (verticalScale * 2)
                let midY = size.height / 2

                // Zero line (perfect sync).
                var zeroPath = Path()
                zeroPath.move(to: CGPoint(x: 0, y: midY))
                zeroPath.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(zeroPath, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

                // Tolerance band.
                let bandHeight = toleranceMs * scale
                context.fill(
                    Path(CGRect(x: 0, y: midY - bandHeight, width: size.width, height: bandHeight * 2)),
                    with: .color(.green.opacity(0.07))
                )

                // One line per output.
                for uid in seriesKeys {
                    guard let samples = history[uid], samples.count > 1, let color = colorFor[uid] else { continue }
                    let count = samples.count
                    var path = Path()
                    for (index, sample) in samples.enumerated() {
                        let x = size.width * CGFloat(index) / CGFloat(maxHistorySamples - 1)
                        let clamped = max(-verticalScale, min(verticalScale, sample))
                        let y = midY - CGFloat(clamped / verticalScale) * (size.height / 2)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                    _ = count
                }
            }
            .frame(height: 64)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var maxHistorySamples: Int { 180 }

    private func shortName(_ name: String) -> String {
        name.count > 18 ? String(name.prefix(16)) + "…" : name
    }
}

/// One output row: transport icon, name, live health, mute, volume, switch.
private struct OutputRow: View {
    @EnvironmentObject private var controller: RelayController
    let uid: String
    let icon: String
    let iconColors: [Color]
    let title: String
    var badge: String? = nil
    @State private var showingTrimPopover = false
    @State private var trimHovering = false

    private var trimActive: Bool { controller.speakerDelayTrimMs(uid: uid) > 0 }

    private var isEnabled: Bool {
        uid == RelayController.thisMacUID ? controller.includeThisMac : controller.enabledOutputUIDs.contains(uid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(colors: iconColors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(AppFont.size(15, .semibold))
                        .foregroundStyle(.white)
                }

                HStack(spacing: 6) {
                    Text(title).font(AppFont.size(15))
                    if let badge {
                        Text(badge)
                            .font(AppFont.size(10, .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .lineLimit(1)

                Spacer()

                if isEnabled {
                    if controller.isStreaming, let health = controller.healthByUID[uid] {
                        HealthPill(health: health)
                    }

                    Button {
                        controller.setSpeakerMuted(uid: uid, !controller.speakerMuted(uid: uid))
                    } label: {
                        Image(systemName: controller.speakerMuted(uid: uid) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(AppFont.size(16))
                            .foregroundStyle(controller.speakerMuted(uid: uid) ? Color.red : Color.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(controller.speakerMuted(uid: uid) ? "Unmute this output" : "Mute this output")

                    Slider(value: Binding(
                        get: { controller.speakerVolume(uid: uid) },
                        set: { controller.setSpeakerVolume(uid: uid, $0) }
                    ), in: 0...1)
                    .frame(minWidth: 84, maxWidth: 100)

                    Button {
                        showingTrimPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(AppFont.size(12, .semibold))
                            Text(trimBadgeText)
                                .font(AppFont.size(12, .semibold).monospacedDigit())
                        }
                        .foregroundStyle(trimActive ? Color.teal : (trimHovering ? Color.primary : Color.secondary))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(trimActive
                                    ? Color.teal.opacity(trimHovering ? 0.22 : 0.14)
                                    : Color.secondary.opacity(trimHovering ? 0.16 : 0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    trimActive ? Color.teal.opacity(0.55)
                                               : Color.secondary.opacity(trimHovering ? 0.6 : 0.35),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { trimHovering = $0 }
                    .help("Delay trim — compensate this speaker's fixed transport latency")
                    .popover(isPresented: $showingTrimPopover, arrowEdge: .bottom) {
                        DelayTrimPopover(uid: uid, speakerName: title)
                            .frame(width: 260)
                    }
                }

                // Always visible — otherwise a disabled row has no way to
                // become enabled (the v1.5 selection bug).
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { _ in
                        if uid == RelayController.thisMacUID {
                            controller.toggleThisMac()
                        } else {
                            controller.toggleOutput(uid: uid)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            if isEnabled, controller.isStreaming, let health = controller.healthByUID[uid],
               health.underruns > 0 || health.driftNudges > 0 {
                Text("underruns \(health.underruns) · drift nudges \(health.driftNudges)")
                    .font(AppFont.size(11.5).monospacedDigit())
                    .foregroundStyle(health.underruns > 20 ? Color.red : Color.secondary)
                    .padding(.leading, 38)
            }
        }
        .padding(.vertical, 3)
    }

    private var trimBadgeText: String {
        let ms = controller.speakerDelayTrimMs(uid: uid)
        return ms > 0 ? "+\(Int(ms))ms" : "trim"
    }

    static func iconName(for transport: String) -> String {
        switch transport {
        case "Bluetooth": return "personalhotspot"
        case "AirPlay": return "appletv"
        case "Aggregate", "Virtual": return "square.stack.3d.up"
        default: return "hifispeaker"
        }
    }

    static func iconColors(for transport: String) -> [Color] {
        switch transport {
        case "Bluetooth": return [.blue, .cyan]
        case "AirPlay": return [.indigo, .purple]
        case "Aggregate", "Virtual": return [.orange, .yellow]
        default: return [.gray, .secondary.opacity(0.7)]
        }
    }
}

/// Relay Satellite network receivers: add by IP, live packet stats.
private struct SatellitesCard: View {
    @EnvironmentObject private var controller: RelayController
    @State private var newHost = ""
    @State private var showAddField = false
    @State private var codeField = ""
    @State private var codeResult = ""

    private func joinByCode() {
        let matched = controller.addReceiverByCode(codeField)
        codeResult = matched.isEmpty
            ? "no receiver showing that code"
            : "added \(matched.joined(separator: ", "))"
        if !matched.isEmpty { codeField = "" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(
                    title: "Satellite receivers",
                    subtitle: "Lossless raw-PCM streaming to Relay Satellite on other Macs",
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                Spacer()
                Button {
                    showAddField.toggle()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(AppFont.size(18))                                .foregroundStyle(.teal)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a receiver by IP address")
            }

            if showAddField {
                HStack {
                    TextField("Receiver IP, e.g. 192.168.1.42", text: $newHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            controller.addReceiver(host: newHost)
                            newHost = ""
                            showAddField = false
                        }
                    Button {
                        controller.addReceiver(host: newHost)
                        newHost = ""
                        showAddField = false
                    } label: {
                        Text("Add")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.teal)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if controller.receiverHosts.isEmpty {
                EmptyHint(text: "No receivers yet. Relay Satellite apps on your network appear below automatically — or add one by IP. Audio is sent as raw PCM — completely lossless.")
            } else {
                ForEach(controller.receiverHosts, id: \.self) { host in
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(AppFont.size(14, .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(LinearGradient(colors: [.teal, .green], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 6))
                        Text(host).font(AppFont.size(15))
                        if let stats = controller.networkStatsByUID["net:\(host)"] {
                            HStack(spacing: 4) {
                                Circle().fill(stats.connected ? Color.green : Color.red).frame(width: 6, height: 6)
                                Text("\(stats.sent) sent · \(stats.resent) resent")
                                    .font(AppFont.size(11.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            controller.removeReceiver(host: host)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(AppFont.size(16))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove this receiver")
                    }
                }
            }

            // Bonjour-discovered receivers that aren't saved yet: one click to add.
            let unsaved = controller.discoveredReceivers.filter { !controller.receiverHosts.contains($0.host) }
            if !unsaved.isEmpty {
                Text("Discovered on this network")
                    .font(AppFont.size(11.5, .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(unsaved) { receiver in
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(AppFont.size(12, .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.secondary.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                        Text(receiver.name).font(AppFont.size(15))
                        if let code = receiver.code {
                            Text("code \(code)")
                                .font(AppFont.size(12).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(receiver.host)
                            .font(AppFont.size(13).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            controller.addDiscoveredReceiver(receiver)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(AppFont.size(14))
                                .foregroundStyle(.teal)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Add this receiver")
                    }
                }
            }

            // Join by code: type the 4 digits shown on the receiver.
            HStack(spacing: 8) {
                Image(systemName: "number")
                    .font(AppFont.size(12, .semibold))
                    .foregroundStyle(.teal)
                TextField("Join by code — 4 digits", text: $codeField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { joinByCode() }
                Button {
                    joinByCode()
                } label: {
                    Text("Join")
                        .font(AppFont.size(13, .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(codeField.count < 4)
                if !codeResult.isEmpty {
                    Text(codeResult)
                        .font(AppFont.size(11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Per-speaker delay trim editor: 1 ms steps over 0–300 ms, plus presets.
/// A trim makes this sink sit that much further behind the shared clock,
/// compensating fixed Bluetooth/AirPlay transport latency so that what the
/// sync scope shows as "locked" also *sounds* locked.
private struct DelayTrimPopover: View {
    @EnvironmentObject private var controller: RelayController
    let uid: String
    let speakerName: String

    private var binding: Binding<Double> {
        Binding(
            get: { controller.speakerDelayTrimMs(uid: uid) },
            set: { controller.setSpeakerDelayTrim(uid: uid, milliseconds: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Delay trim")
                    .font(AppFont.size(15, .semibold))
                Text("Adds latency to \(speakerName) so it lines up with the slowest speaker. Use while listening to music with a sharp transient (drum hit).")
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("0")
                    .font(AppFont.size(11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: binding, in: 0...300, step: 1)
                    .tint(.teal)
                Text("300")
                    .font(AppFont.size(11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(String(format: "%d ms", Int(controller.speakerDelayTrimMs(uid: uid))))
                    .font(AppFont.size(17, .semibold).monospacedDigit())
                    .foregroundStyle(.teal)
                Spacer()
                ForEach([0.0, 50, 100, 150, 200], id: \.self) { preset in
                    Button {
                        controller.setSpeakerDelayTrim(uid: uid, milliseconds: preset)
                    } label: {
                        Text(preset == 0 ? "off" : "\(Int(preset))")
                            .font(AppFont.size(11.5, .medium).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                abs(controller.speakerDelayTrimMs(uid: uid) - preset) < 0.5
                                    ? Color.teal.opacity(0.18)
                                    : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}

private struct HealthPill: View {
    let health: SinkHealth

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(Int(health.latencyMs)) ms")
                .font(AppFont.size(11.5).monospacedDigit().weight(.medium))
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
        .help("Latency \(Int(health.latencyMs)) ms · sync offset \(health.syncOffsetFrames) frames · underruns \(health.underruns) · drift nudges \(health.driftNudges)")
    }

    private var color: Color {
        if health.underruns > 20 { return .red }
        if health.driftNudges > 30 || health.underruns > 0 { return .orange }
        return .green
    }
}

// MARK: - Settings

private struct SettingsCard: View {
    @EnvironmentObject private var controller: RelayController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "Settings",
                subtitle: "Master volume, mute behavior, and timing",
                systemImage: "slider.horizontal.3"
            )

            HStack(spacing: 12) {
                Image(systemName: "speaker.fill")
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { controller.masterVolume },
                    set: { controller.masterVolume = $0 }
                ), in: 0...1)
                .tint(.teal)
                Image(systemName: "speaker.wave.3.fill")
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
            }

            SettingToggle(
                title: "Mute source on this Mac",
                subtitle: "While streaming, mute the original app so only remote speakers play",
                isOn: Binding(
                    get: { controller.muteSourceLocally },
                    set: { controller.muteSourceLocally = $0 }
                ),
                disabled: controller.isStreaming
            )

            SettingToggle(
                title: "Low-latency mode",
                subtitle: "~60 ms path for video lip sync · tighter timing, less Bluetooth tolerance. Off = ~300 ms for whole-house music.",
                isOn: Binding(
                    get: { controller.lowLatencyMode },
                    set: { controller.lowLatencyMode = $0 }
                )
            )

            SettingToggle(
                title: "Silence Monitor",
                subtitle: "Stop streaming automatically when the source has been quiet for a while",
                isOn: Binding(
                    get: { controller.silenceMonitorEnabled },
                    set: { controller.silenceMonitorEnabled = $0 }
                )
            )

            SettingToggle(
                title: "Raise low-rate outputs to 48 kHz",
                subtitle: "Devices set to 16 kHz (or lower) sound muffled — Relay switches them to 48 kHz before streaming starts",
                isOn: Binding(
                    get: { controller.enforce48k },
                    set: { controller.enforce48k = $0 }
                )
            )

            if controller.silenceMonitorEnabled {
                HStack {
                    Text("Stop after")
                        .font(AppFont.size(15))
                        .foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { controller.silenceTimeoutSeconds },
                        set: { controller.silenceTimeoutSeconds = $0 }
                    )) {
                        Text("1 min").tag(60.0)
                        Text("5 min").tag(300.0)
                        Text("15 min").tag(900.0)
                        Text("30 min").tag(1800.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    Spacer()

                    if controller.isStreaming, controller.silenceSeconds >= 2 {
                        Text("quiet for \(controller.silenceSeconds)s…")
                            .font(AppFont.size(13).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 34)
            }

            HStack {
                Text("Text size")
                    .font(AppFont.size(15))
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { controller.textScale },
                    set: { controller.setTextScale($0) }
                )) {
                    ForEach(AppFont.Scale.allCases, id: \.self) { scale in
                        Text(scale.label).tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
            }
            .padding(.leading, 34)
        }
        .cardStyle()
    }
}

private struct SettingToggle: View {
    let title: String
    let subtitle: String
    let isOn: Binding<Bool>
    var disabled = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.size(15, .medium))
                Text(subtitle)
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(disabled)
        }
        .padding(.leading, 34)
    }
}

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(AppFont.size(14, .semibold))
                .foregroundStyle(.teal)
                .frame(width: 22, height: 22)
                .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(AppFont.size(15, .semibold))
                Text(subtitle)
                    .font(AppFont.size(13))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.size(15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                LinearGradient(colors: [.green, .orange, .red], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(6, geometry.size.width * CGFloat(level)))
                    .clipShape(Capsule())
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}
