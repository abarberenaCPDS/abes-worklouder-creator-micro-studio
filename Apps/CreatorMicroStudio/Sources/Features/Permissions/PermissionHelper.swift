import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import CreatorMicroStudioKit
import SwiftUI

/// Gets macOS to show its own "Keystroke Receiving" request for Studio, and
/// falls back to the Input Monitoring helper when it does not.
///
/// macOS only shows its sheet while no decision is recorded for the bundle
/// ID, and a running process often keeps its cached decision after its record
/// is removed in System Settings — then nothing appears until a relaunch.
/// So a request (1) clears this app's own record when it is a Deny, (2) asks
/// through IOHID and CoreGraphics, (3) briefly creates a listen-only key
/// event tap — the Input Monitoring equivalent of posting a test event, which
/// makes tccd evaluate the app and list it in Settings — and (4) watches for
/// about two seconds. When neither a grant nor the system sheet (the app
/// resigning active) shows up, the helper window explains what to do by hand.
@MainActor
enum InputMonitoringPrompt {
    private static var watchTask: Task<Void, Never>?
    private static var resignedDuringWatch = false
    private static var resignObserver: NSObjectProtocol?

    /// - Parameter showHelperIfSilent: open the helper window when macOS
    ///   shows nothing. Launch passes false so a login item stays quiet.
    ///   An explicit request (true) runs even while emulating: the grant is
    ///   still needed once emulation is turned off.
    static func request(showHelperIfSilent: Bool = true) {
        if !showHelperIfSilent, BridgeSettings.emulate { return }
        guard !WLDevice.hasInputMonitoringAccess else { return }
        if WLDevice.inputMonitoringAccess == .denied {
            _ = resetRecord()
        }
        WLDevice.requestInputMonitoringAccessIfNeeded()
        probeListenEventTap()
        guard showHelperIfSilent else { return }
        watchForSystemPrompt()
    }

    static func openSettings() {
        NSWorkspace.shared.open(PermissionKind.inputMonitoring.settingsURL)
    }

    /// Creates a listen-only key-down tap and throws it away at once. It is
    /// never enabled or added to a run loop, so no event is ever seen; the
    /// attempt alone is what gets tccd to evaluate (and list) the app.
    private static func probeListenEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        ) else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    private static func watchForSystemPrompt() {
        watchTask?.cancel()
        resignedDuringWatch = false
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in InputMonitoringPrompt.resignedDuringWatch = true }
            }
        }
        watchTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                if WLDevice.hasInputMonitoringAccess || resignedDuringWatch { return }
            }
            guard !Task.isCancelled, !WLDevice.hasInputMonitoringAccess else { return }
            PermissionHelperWindowController.shared.show(.inputMonitoring, requestWentUnanswered: true)
        }
    }

    /// Clears only this app's own Input Monitoring record.
    private static func resetRecord() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ListenEvent", bundleID]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// The two privacy permissions the Studio can need, as the helper explains them.
enum PermissionKind: String, Identifiable {
    case inputMonitoring
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    /// How the pane reads in System Settings, both names where they differ.
    var settingsName: String {
        switch self {
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility (called “Device Control and Data Access” on newer macOS)"
        }
    }

    var symbol: String {
        switch self {
        case .inputMonitoring: return "hand.raised"
        case .accessibility: return "hand.point.up.left"
        }
    }

    var purpose: String {
        switch self {
        case .inputMonitoring:
            return "Studio reads the pad's keys, dial and joystick through macOS Input Monitoring. Without it the pad stays dark."
        case .accessibility:
            return "System actions — scroll, keyboard shortcuts, media keys, voice and typing — post events, which macOS only allows with Accessibility. Every other action works without it."
        }
    }

    var settingsURL: URL {
        switch self {
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .accessibility:
            return SystemActions.accessibilitySettingsURL
        }
    }

    @MainActor
    var isGranted: Bool {
        switch self {
        case .inputMonitoring: return WLDevice.hasInputMonitoringAccess
        case .accessibility: return SystemActions.isAccessibilityTrusted
        }
    }

    /// Whether the grant only takes effect in a fresh process.
    var needsRelaunch: Bool { self == .inputMonitoring }
}

// MARK: - Window

@MainActor
final class PermissionHelperWindowController: NSObject, NSWindowDelegate {
    static let shared = PermissionHelperWindowController()

    private var windows: [PermissionKind: NSWindow] = [:]

    /// - Parameter requestWentUnanswered: the window opens because a request
    ///   produced no system sheet, so it says so.
    func show(_ kind: PermissionKind, requestWentUnanswered: Bool = false) {
        if let window = windows[kind] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Allow \(kind.title)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = NSHostingView(rootView: PermissionHelperView(
            kind: kind,
            requestWentUnanswered: requestWentUnanswered,
            onClose: { [weak window] in window?.close() }
        ))
        window.contentView = hosting
        // Fit the window to the steps rather than guessing a height.
        window.setContentSize(hosting.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[kind] = window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }

    /// Relaunches this same bundle: a detached shell waits for this process
    /// to exit, then opens the bundle path again.
    static func quitAndReopen() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Views

/// The step-by-step helper for one permission: which app to allow, where it
/// lives, and the buttons for each step.
struct PermissionHelperView: View {
    let kind: PermissionKind
    var requestWentUnanswered = false
    var onClose: () -> Void = {}
    /// Injectable for previews.
    var checkAccess: (() -> Bool)?

    @State private var granted = false

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.symbol)
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow \(kind.title) for \(AppIdentity.shortName)")
                        .font(.title2.weight(.semibold))
                    Text(intro)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            AppIdentityCard()

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Open System Settings → Privacy & Security → \(kind.settingsName).")
                step(2, "If \(AppIdentity.displayName) is listed, turn it on. Otherwise click +, and choose the app above — or drag it in from the Finder window Reveal in Finder opens.")
                step(3, kind.needsRelaunch
                     ? "Quit & Reopen, so the new grant takes effect."
                     : "If an action still fails, Quit & Reopen.")
            }

            statusLine

            HStack {
                Button {
                    NSWorkspace.shared.open(kind.settingsURL)
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                Button("Reveal in Finder", action: AppIdentity.revealInFinder)
                Button("Quit & Reopen") { PermissionHelperWindowController.quitAndReopen() }
                    .help("Quit and relaunch \(AppIdentity.fileName)")
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            Text("Dev builds signed ad hoc (“Sign to Run Locally”) can lose this grant after a rebuild, because macOS ties it to the code signature. Choose a development Team in Signing & Capabilities to keep it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 640, alignment: .leading)
        .onAppear(perform: refresh)
        .onReceive(poll) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var intro: String {
        let lead = requestWentUnanswered
            ? "macOS didn't show its request this time. That happens when the app was removed from the list, or a decision is remembered."
            : "You can allow it yourself in System Settings."
        return "\(lead) \(kind.purpose)"
    }

    @ViewBuilder
    private var statusLine: some View {
        if granted {
            Label(kind.needsRelaunch
                  ? "\(kind.title) is allowed. If the pad stays dark, Quit & Reopen."
                  : "\(kind.title) is allowed.",
                  systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Label("Not allowed yet — this updates as soon as macOS reports the change.",
                  systemImage: "exclamationmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refresh() {
        granted = checkAccess?() ?? kind.isGranted
    }
}

/// Which app macOS should be told about: icon, name, channel, file name,
/// folder and bundle ID, with Reveal in Finder and Copy Path.
struct AppIdentityCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: AppIdentity.bundleIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(AppIdentity.displayName)
                        .font(.headline)
                    Text(AppIdentity.channelName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppIdentity.isDev ? Color.orange : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background((AppIdentity.isDev ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("File").foregroundStyle(.secondary)
                        Text(AppIdentity.fileName)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        Text(AppIdentity.folderPath)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(AppIdentity.folderPath)
                    }
                    GridRow {
                        Text("Bundle ID").foregroundStyle(.secondary)
                        Text(Bundle.main.bundleIdentifier ?? "—")
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                HStack {
                    Button("Reveal in Finder", action: AppIdentity.revealInFinder)
                    Button("Copy Path", action: AppIdentity.copyPath)
                        .help("Copy \(Bundle.main.bundlePath)")
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The app to allow")
    }
}

extension AppIdentity {
    /// "Studio" or "Studio Dev", for short headlines.
    static var shortName: String { isDev ? "Studio Dev" : "Studio" }

    static var channelName: String { isDev ? "Dev" : "Stable" }

    /// The bundle's file name, e.g. AbesWorkLouderCreatorMicroStudioDev.app.
    static var fileName: String { Bundle.main.bundleURL.lastPathComponent }

    static var folderPath: String { Bundle.main.bundleURL.deletingLastPathComponent().path }

    static var bundleIcon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
    }
}

#Preview("Input Monitoring Helper") {
    PermissionHelperView(kind: .inputMonitoring, requestWentUnanswered: true, checkAccess: { false })
}

#Preview("Accessibility Helper · Allowed") {
    PermissionHelperView(kind: .accessibility, checkAccess: { true })
}
