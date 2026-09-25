import SwiftUI

/// Compact window-style MenuBarExtra panel: quick start/stop and the current
/// source, with a button that opens the full window for configuration.
struct MenuBarPanelView: View {
    @EnvironmentObject private var controller: RelayController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: controller.isStreaming
                    ? "dot.radiowaves.left.and.right"
                    : "hifispeaker.2")
                Text(controller.isStreaming ? "Streaming \(controller.selectedSource?.name ?? "")" : "Relay")
                    .fontWeight(.semibold)
                Spacer()
            }
            .font(.callout)

            Divider()

            if let source = controller.selectedSource {
                Text("Source: \(source.name)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No source selected — open the window to pick an app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(controller.enabledOutputSummary)
                .font(.caption)
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

            Button("Quit Relay") {
                NSApp.terminate(nil)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(4)
        .frame(width: 260)
    }
}
