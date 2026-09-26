import SwiftUI
import SatelliteKit

/// Compact window-style MenuBarExtra panel: quick start/stop and the current
/// source, with a button that opens the full window for configuration.
struct MenuBarPanelView: View {
    @EnvironmentObject private var controller: RelayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        panelBody
            .font(AppFont.size(15))
            // Re-reads AppFont.scale when the setting changes.
            .id(controller.textScale)
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: controller.isStreaming
                    ? "dot.radiowaves.left.and.right"
                    : "hifispeaker.2")
                Text(controller.isStreaming ? "Streaming \(controller.selectedSource?.name ?? "")" : "Relay")
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(AppFont.size(15))

            Divider()

            if let source = controller.selectedSource {
                Text("Source: \(source.name)")
                    .font(AppFont.size(15))
                    .foregroundStyle(.secondary)
            } else {
                Text("No source selected — open the window to pick an app.")
                    .font(AppFont.size(15))
                    .foregroundStyle(.secondary)
            }

            Text(controller.enabledOutputSummary)
                .font(AppFont.size(13))
                .foregroundStyle(.secondary)

            Button {
                if controller.isStreaming {
                    controller.stopTransport()
                } else {
                    controller.startTransport()
                }
            } label: {
                Label(controller.isStreaming ? "Stop" : "Start", systemImage: controller.isStreaming ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                openWindow(id: "main")
            } label: {
                Label("Open Relay…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Divider()

            Picker("Text size", selection: Binding(
                get: { controller.textScale },
                set: { controller.setTextScale($0) }
            )) {
                ForEach(AppFont.Scale.allCases, id: \.self) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .font(AppFont.size(13))

            Divider()

            Button("Quit Relay") {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(4)
        .frame(width: 280)
    }
}
