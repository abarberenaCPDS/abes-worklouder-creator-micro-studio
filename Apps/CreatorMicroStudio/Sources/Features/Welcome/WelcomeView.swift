import AppKit
import CreatorMicroStudioKit
import ServiceManagement
import SwiftUI

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()

    private var window: NSWindow?

    static func showOnManualLaunchIfNeeded() {
        // Keep login-item launches quiet. The welcome window is always
        // available from the menu-bar panel when the user wants it.
        guard SMAppService.mainApp.status != .enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shared.show()
        }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(
            onOpenStudio: { [weak self] in
                self?.window?.close()
                StudioWindowController.shared.show(runtime: .shared)
            },
            onDismiss: { [weak self] in self?.window?.close() },
            onRequestInputMonitoring: {
                StudioRuntimeCoordinator.shared.requestStudioInputMonitoringAccess()
            },
            onShowInputMonitoringHelp: {
                StudioRuntimeCoordinator.shared.showInputMonitoringHelp()
            }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct WelcomeView: View {
    let onOpenStudio: () -> Void
    let onDismiss: () -> Void
    let onRequestInputMonitoring: () -> Void
    let onShowInputMonitoringHelp: () -> Void
    var checkAccess: () -> Bool = { WLDevice.hasInputMonitoringAccess }
    var isEmulating: Bool = BridgeSettings.emulate
    var version: String = AppIdentity.versionDescription
    var iconName: String = AppIdentity.splashIconName

    @State private var hasInputMonitoring = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(iconName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 156, height: 156)
                    .accessibilityLabel("\(AppIdentity.displayName) app icon")

                Spacer().frame(height: 26)

                Text("Abe's WorkLouder")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                Text("Creator Micro Studio")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 12)

                Text("A personal map for a remarkable little device.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 14)

                Text("Version \(version)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(36)
            .background(.regularMaterial)

            VStack(alignment: .leading, spacing: 20) {
                Text("Make the Micro yours.")
                    .font(.title2.weight(.semibold))
                Text("See your agents at a glance, tune the pad, and shape the way your work feels.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    (Text("All work & ") + Text("no").strikethrough() + Text(" play"))
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text("Human after all").font(.headline)
                        Text(verbatim: #"¯\_(ツ)_/¯"#)
                            .font(.title3)
                            .accessibilityLabel("shrug")
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Spacer(minLength: 4)

                if !isEmulating {
                    inputMonitoringCard
                }

                Label("Studio lives in your menu bar", systemImage: "menubar.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button(action: onOpenStudio) {
                    Label("Open Studio", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Continue to the menu bar", action: onDismiss)
                    .frame(maxWidth: .infinity)
                    .controlSize(.large)
            }
            .frame(minWidth: 310, idealWidth: 310, maxWidth: 310,
                   maxHeight: .infinity, alignment: .topLeading)
            .padding(30)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Launch has already asked macOS; this only reflects the result.
            hasInputMonitoring = checkAccess()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasInputMonitoring = checkAccess()
        }
    }

    private var inputMonitoringCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasInputMonitoring {
                Label("Input Monitoring is allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("Input Monitoring is needed", systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text("Studio reads the pad through macOS Input Monitoring. Request Access asks macOS; if nothing appears, Show me how… names this app, shows where it is, and walks you through System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Request Access", action: onRequestInputMonitoring)
                    Button("Show me how…", action: onShowInputMonitoringHelp)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview("Splash Window · 760×560") {
    WelcomeView(onOpenStudio: {}, onDismiss: {},
                onRequestInputMonitoring: {}, onShowInputMonitoringHelp: {},
                checkAccess: { true }, isEmulating: false, version: "0.3.1 (7)")
        .frame(width: 760, height: 560)
}

#Preview("Splash Window · Input Monitoring Needed") {
    WelcomeView(onOpenStudio: {}, onDismiss: {},
                onRequestInputMonitoring: {}, onShowInputMonitoringHelp: {},
                checkAccess: { false }, isEmulating: false, version: "0.3.1 (7)")
        .frame(width: 760, height: 560)
}
