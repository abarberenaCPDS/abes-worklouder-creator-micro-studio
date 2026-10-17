import SwiftUI
import AppKit
import CreatorMicroStudioKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Inspector is a foreground utility app and should activate when
        // launched directly from Xcode or from the embedded app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WLInspectorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Abe’s WorkLouder Creator Micro Studio Inspector") {
            ContentView()
                .environmentObject(model)
                .onAppear { model.connect() }
        }
        .defaultSize(width: 1480, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Device") {
                Button("Reconnect") { model.connect() }.keyboardShortcut("r")
                Button("Refresh status") { model.refreshStatus() }.keyboardShortcut("i")
                Divider()
                Button("All lights off") { model.allOff() }.keyboardShortcut("0")
                Button("Walk keys 0→12") { model.runWalk() }
                Divider()
                Button("Clear log") { model.clearLog() }.keyboardShortcut("k")
            }
        }
    }
}
