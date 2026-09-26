import SwiftUI
import AppKit

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = RelayController()

    var body: some Scene {
        WindowGroup(id: "main") {
            RelayMainView()
                .environmentObject(controller)
                .frame(minWidth: 500, minHeight: 600)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Relay", systemImage: "hifispeaker.2") {
            MenuBarPanelView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar even when the window is closed.
        false
    }
}
