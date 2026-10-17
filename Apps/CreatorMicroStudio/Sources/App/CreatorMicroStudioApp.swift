import SwiftUI
import AppKit
import ServiceManagement
import CreatorMicroStudioKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this keeps menu-bar behavior consistent in Xcode.
        NSApplication.shared.setActivationPolicy(.accessory)
        WelcomeWindowController.showOnManualLaunchIfNeeded()
    }
}

@main
struct CreatorMicroStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var runtime = StudioRuntimeCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(runtime.bridge)
                .environmentObject(runtime)
                .task { await runtime.startIfNeeded() }
        } label: {
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.State.from(runtime.bridge)))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is useful when testing from Xcode without a device.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }
}
