import SwiftUI
import Combine
import AppKit
import ServiceManagement
import CreatorMicroStudioKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this keeps menu-bar behavior consistent in Xcode.
        NSApplication.shared.setActivationPolicy(.accessory)
        WelcomeWindowController.showOnManualLaunchIfNeeded()
        Task { @MainActor in
            // Ask on every launch until granted, whether or not the bridge is
            // on, then start driving the pad without waiting for the panel.
            // Quietly: a launch never opens the helper window by itself.
            InputMonitoringPrompt.request(showHelperIfSilent: false)
            await StudioRuntimeCoordinator.shared.startIfNeeded()
        }
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
            MenuBarLabel(bridge: runtime.bridge)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Watches only the icon's state, derived from the bridge. Observing the
/// bridge itself re-rendered the label — a fresh NSImage and an NSStatusItem
/// relayout — on every Herdr poll, even when the icon looked the same. (The
/// coordinator does not republish bridge changes, so reading it through
/// `runtime` would freeze the icon at launch.)
private struct MenuBarLabel: View {
    @StateObject private var status: MenuBarStatus

    init(bridge: BridgeController) {
        _status = StateObject(wrappedValue: MenuBarStatus(bridge: bridge))
    }

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: status.state))
            .accessibilityLabel(status.state.help)
    }
}

/// The menu-bar icon's state, republished only when it changes.
@MainActor
private final class MenuBarStatus: ObservableObject {
    @Published private(set) var state: MenuBarIcon.State
    private weak var bridge: BridgeController?
    private var subscription: AnyCancellable?

    init(bridge: BridgeController) {
        self.bridge = bridge
        state = MenuBarIcon.State.from(bridge)
        // objectWillChange fires before the value lands; look on the next
        // run-loop turn, when it has.
        subscription = bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.update() }
            }
    }

    private func update() {
        guard let bridge else { return }
        let next = MenuBarIcon.State.from(bridge)
        if next != state { state = next }
    }
}

/// Which install this is. Debug builds are the Dev app, with their own bundle
/// IDs, name and badged icon, so macOS keeps their Input Monitoring grant,
/// defaults and login item apart from the installed Stable (Release) app.
/// Values come from the `WL_*` build settings via Info.plist.
enum AppIdentity {
    private static func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var isDev: Bool { info("WLBuildChannel") == "Dev" }

    static var displayName: String {
        info("CFBundleDisplayName") ?? "Abe's WorkLouder Creator Micro Studio"
    }

    /// "0.3.1 (7)", plus "· Dev" for development builds.
    static var versionDescription: String {
        let short = info("CFBundleShortVersionString") ?? "—"
        let version = info("CFBundleVersion").map { "\(short) (\($0))" } ?? short
        return isDev ? "\(version) · Dev" : version
    }

    static var splashIconName: String { isDev ? "StudioAppIconDev" : "StudioAppIcon" }

    /// The standalone Inspector embedded in this build — Dev embeds the Dev one.
    static var inspectorBundleIdentifier: String {
        info("WLInspectorBundleIdentifier") ?? "dev.abeisonai.worklouder.inspector"
    }

    /// The embedded helper's own name, as macOS shows it in Input Monitoring.
    static var inspectorDisplayName: String {
        Bundle(url: inspectorAppURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "\(displayName) Inspector"
    }

    static var inspectorAppURL: URL {
        let name = info("WLInspectorProductName") ?? "AbesWorkLouderCreatorMicroStudioInspector"
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Library/\(name).app")
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
