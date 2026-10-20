import AppKit
import SwiftUI
import CreatorMicroStudioKit

enum StudioDestination: String, Identifiable, Hashable {
    case studio = "Studio"
    case controls = "Controls"
    case lighting = "Lighting"
    case herdr = "Herdr"
    case inspector = "Inspector"
    case inputMonitoring = "Input Monitoring"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .studio: return "keyboard"
        case .controls: return "slider.horizontal.below.square.and.square.filled"
        case .lighting: return "lightbulb.led"
        case .herdr: return "point.3.connected.trianglepath.dotted"
        case .inspector: return "waveform.path.ecg"
        case .inputMonitoring: return "hand.raised"
        }
    }
}

@MainActor
final class StudioNavigationState: ObservableObject {
    @Published var selection: StudioDestination? = .studio
}

/// Owns one Studio bridge and one Inspector session. Inspector takes the HID
/// connection while its sidebar page is selected, then Studio resumes if it was
/// running before the handoff and the user still has it enabled.
@MainActor
final class StudioRuntimeCoordinator: ObservableObject {
    static let shared = StudioRuntimeCoordinator(previewMode: false)

    let bridge: BridgeController
    let inspectorModel: AppModel

    @Published private(set) var isInspectorActive = false
    @Published private(set) var inspectorReady = false
    @Published private(set) var inspectorRequiresHardware = false
    @Published private(set) var isTransitioning = false
    @Published private(set) var standaloneInspectorError: String?

    private var resumeStudioAfterInspector = false
    private var resumeStudioAfterStandaloneInspector = false
    private var standaloneInspectorPID: pid_t?
    private var transitionTask: Task<Void, Never>?
    private var workspaceTerminationObserver: NSObjectProtocol?
    private let previewMode: Bool

    private init(
        previewMode: Bool,
        bridge: BridgeController? = nil,
        inspectorModel: AppModel? = nil
    ) {
        self.previewMode = previewMode
        self.bridge = bridge ?? BridgeController()
        self.inspectorModel = inspectorModel ?? AppModel()
        guard !previewMode else { return }
        wireActions()
        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, app.processIdentifier == self.standaloneInspectorPID else { return }
                self.standaloneInspectorPID = nil
                let shouldResume = self.resumeStudioAfterStandaloneInspector
                self.resumeStudioAfterStandaloneInspector = false
                // The standalone Inspector may have saved looks to Studio's
                // config file; pick them up even if the bridge stays off.
                self.bridge.reloadConfiguration()
                guard shouldResume, BridgeSettings.enabled else { return }
                await self.bridge.useEmulator(BridgeSettings.emulate)
                await self.bridge.start()
            }
        }
    }

    static func preview(bridge: BridgeController? = nil) -> StudioRuntimeCoordinator {
        StudioRuntimeCoordinator(
            previewMode: true,
            bridge: bridge ?? BridgeController.previewFixture(),
            inspectorModel: AppModel()
        )
    }

    func startIfNeeded() async {
        guard !previewMode else { return }
        guard !isInspectorActive, !isTransitioning else { return }
        await bridge.useEmulator(BridgeSettings.emulate)
        guard !isInspectorActive, BridgeSettings.enabled, !bridge.isRunning else { return }
        await bridge.start()
    }

    func setStudioEnabled(_ enabled: Bool) async {
        guard !previewMode else { return }
        BridgeSettings.enabled = enabled
        if isInspectorActive || isTransitioning {
            resumeStudioAfterInspector = enabled
            return
        }
        await bridge.useEmulator(BridgeSettings.emulate)
        if enabled {
            if !bridge.isRunning { await bridge.start() }
        } else if bridge.isRunning {
            await bridge.stop()
        }
    }

    func setEmulation(_ enabled: Bool) async {
        guard !previewMode else { return }
        BridgeSettings.emulate = enabled
        guard !isInspectorActive, !isTransitioning else { return }
        await bridge.useEmulator(enabled)
    }

    /// Raise the macOS Input Monitoring request for Studio and start the
    /// bridge, which keeps retrying the pad until the grant takes effect.
    /// When macOS shows nothing, the request opens the helper window.
    func requestStudioInputMonitoringAccess() {
        guard !previewMode else { return }
        if processNeedsRelaunchForInputMonitoring {
            // macOS already reports the grant, so it will show no request,
            // but this process keeps its cached denial until it relaunches.
            // The helper says so and offers Quit & Reopen.
            PermissionHelperWindowController.shared.show(.inputMonitoring)
        } else {
            InputMonitoringPrompt.request()
        }
        if BridgeSettings.enabled {
            Task { await startIfNeeded() }
        }
    }

    /// Input Monitoring is allowed in System Settings, yet this process still
    /// cannot open the pad: only a relaunch picks the grant up.
    var processNeedsRelaunchForInputMonitoring: Bool {
        bridge.permissionDenied && WLDevice.hasInputMonitoringAccess
    }

    /// The step-by-step helper: which app to allow, where it is, and the
    /// buttons to get there.
    func showInputMonitoringHelp() {
        guard !previewMode else { return }
        PermissionHelperWindowController.shared.show(.inputMonitoring)
    }

    func openStandaloneInspector() {
        guard !previewMode else { return }
        standaloneInspectorError = nil
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == AppIdentity.inspectorBundleIdentifier
        }
        let shouldResume = bridge.isRunning && BridgeSettings.enabled

        Task { @MainActor [self] in
            if bridge.isRunning { await bridge.stop() }
            resumeStudioAfterStandaloneInspector = shouldResume

            if let running {
                standaloneInspectorPID = running.processIdentifier
                running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                return
            }

            let appURL = AppIdentity.inspectorAppURL
            guard FileManager.default.fileExists(atPath: appURL.path) else {
                standaloneInspectorError = "The standalone Inspector helper is missing from this app bundle. Rebuild the CreatorMicroStudio scheme and try again."
                await resumeStudioAfterStandaloneInspectorIfNeeded()
                return
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] app, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let app {
                        self.standaloneInspectorPID = app.processIdentifier
                    } else {
                        self.standaloneInspectorError = error?.localizedDescription ?? "Inspector could not be opened."
                        await self.resumeStudioAfterStandaloneInspectorIfNeeded()
                    }
                }
            }
        }
    }

    private func resumeStudioAfterStandaloneInspectorIfNeeded() async {
        let shouldResume = resumeStudioAfterStandaloneInspector
        resumeStudioAfterStandaloneInspector = false
        bridge.reloadConfiguration()
        guard shouldResume, BridgeSettings.enabled else { return }
        await bridge.useEmulator(BridgeSettings.emulate)
        await bridge.start()
    }

    func enterInspector() {
        guard !isInspectorActive, !isTransitioning else { return }
        if previewMode {
            inspectorRequiresHardware = false
            isInspectorActive = true
            inspectorReady = true
            return
        }
        guard bridge.emulator == nil else {
            inspectorRequiresHardware = true
            inspectorReady = false
            return
        }
        inspectorRequiresHardware = false
        isInspectorActive = true
        isTransitioning = true
        inspectorReady = false
        resumeStudioAfterInspector = bridge.isRunning && BridgeSettings.enabled

        let previousTransition = transitionTask
        transitionTask = Task { @MainActor in
            await previousTransition?.value
            if bridge.isRunning { await bridge.stop() }
            guard isInspectorActive else {
                isTransitioning = false
                return
            }
            inspectorReady = true
            isTransitioning = false
        }
    }

    func connectInspectorIfNeeded() {
        guard !previewMode else { return }
        guard isInspectorActive, inspectorReady else { return }
        inspectorModel.connect()
    }

    func leaveInspector() {
        if previewMode {
            isInspectorActive = false
            inspectorReady = false
            inspectorRequiresHardware = false
            return
        }
        guard isInspectorActive else {
            // Runs on every page change: assign only on a change, so moving
            // between ordinary pages publishes nothing.
            if inspectorRequiresHardware { inspectorRequiresHardware = false }
            return
        }
        isInspectorActive = false
        inspectorReady = false
        inspectorRequiresHardware = false
        isTransitioning = true

        let previousTransition = transitionTask
        let shouldResume = resumeStudioAfterInspector
        resumeStudioAfterInspector = false
        transitionTask = Task { @MainActor in
            await previousTransition?.value
            inspectorModel.disconnect()
            // Inspector edits are temporary; anything it saved to Studio is
            // in config.json, so reload before Studio repaints the pad.
            bridge.reloadConfiguration()
            if shouldResume, BridgeSettings.enabled {
                await bridge.useEmulator(BridgeSettings.emulate)
                await bridge.start()
            }
            isTransitioning = false
        }
    }

    private func wireActions() {
        let bridge = self.bridge

        let voice = VoiceController.shared
        voice.onActiveChange = { [weak bridge] active in
            Task { await bridge?.setVoiceActive(active) }
        }
        voice.onError = { [weak bridge] message in bridge?.noteError(message) }
        bridge.onVoiceKey = { voice.handleVoiceKey() }

        let tune = TuneController.shared
        tune.onError = { [weak bridge] message in bridge?.noteError(message) }
        tune.bindings = { [weak bridge] in bridge?.keyBindings ?? KeyBindings() }
        bridge.onTune = { command in tune.handle(command) }

        // A Herdr command's {ask:…} placeholders type into a small floating
        // panel; nil cancels the action.
        bridge.onAsk = { prompt, defaultText in
            await HerdrAskPanel.shared.ask(prompt: prompt, defaultText: defaultText)
        }
    }
}

@MainActor
final class StudioWindowController: NSObject, NSWindowDelegate {
    static let shared = StudioWindowController()

    private var window: NSWindow?
    private var navigation: StudioNavigationState?
    private var runtime: StudioRuntimeCoordinator?

    func show(
        runtime: StudioRuntimeCoordinator,
        destination: StudioDestination = .studio
    ) {
        if let window, let navigation {
            navigation.selection = destination
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let navigation = StudioNavigationState()
        navigation.selection = destination
        // Open at 940 pt tall where there is room, but never taller than the
        // screen below the menu bar (minus titlebar and toolbar), so the
        // bottom of every page stays reachable on a 13" or 14" MacBook.
        let visibleHeight = (NSScreen.main?.visibleFrame.height ?? 940) - 90
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1740, height: max(780, min(940, visibleHeight))),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titleVisibility = .visible
        // Matches the SwiftUI minimum height; every page scrolls below it.
        window.contentMinSize = NSSize(width: 1400, height: 780)
        let hostingController = NSHostingController(rootView: StudioWindowView(
            runtime: runtime,
            bridge: runtime.bridge,
            navigation: navigation
        ))
        // NavigationSplitView installs a window toolbar and can extend its
        // hosting view into the titlebar. Keep an AppKit-owned content boundary:
        // the workspace starts below the actual titlebar/toolbar, even after
        // toolbar changes or resizing. Do not compensate with fixed padding.
        let contentController = NSViewController()
        contentController.view = NSView()
        contentController.addChild(hostingController)
        window.contentViewController = contentController
        let workspace = hostingController.view
        workspace.translatesAutoresizingMaskIntoConstraints = false
        contentController.view.addSubview(workspace)
        // AppKit exposes this documented NSLayoutGuide as Any for ObjC compatibility.
        let contentGuide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            workspace.topAnchor.constraint(equalTo: contentGuide.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: contentGuide.bottomAnchor),
            workspace.leadingAnchor.constraint(equalTo: contentGuide.leadingAnchor),
            workspace.trailingAnchor.constraint(equalTo: contentGuide.trailingAnchor),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.navigation = navigation
        self.runtime = runtime
        self.window = window
        Task { await runtime.startIfNeeded() }
    }

    func windowWillClose(_ notification: Notification) {
        runtime?.leaveInspector()
        window = nil
        navigation = nil
        runtime = nil
    }
}

@MainActor
private struct StudioWindowView: View {
    @ObservedObject var runtime: StudioRuntimeCoordinator
    @ObservedObject var bridge: BridgeController
    @ObservedObject var navigation: StudioNavigationState
    @State private var studioPermissionGranted = WLDevice.hasInputMonitoringAccess

    var body: some View {
        NavigationSplitView {
            List {
                Section("Workspace") {
                    workspaceRow(.studio)
                    workspaceRow(.controls)
                    workspaceRow(.lighting)
                    workspaceRow(.herdr)
                    workspaceRow(.inspector)
                }
                Section("Settings") {
                    workspaceRow(.inputMonitoring)
                }
                Section("Device") {
                    Label(
                        runtime.isInspectorActive ? "Inspector owns the pad" : deviceStatus,
                        systemImage: runtime.isInspectorActive ? "waveform.path.ecg" : "keyboard"
                    )
                    .foregroundStyle(.secondary)
                }
                Section("About") {
                    Label("Version \(appVersion)", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .disabled(runtime.isTransitioning)
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 310)
        } detail: {
            // Pin each page to exactly the size the column offers. Left to
            // itself the detail column sizes a page by its ideal height, and a
            // List's ideal height is all of its rows: the page then grows
            // taller than the window and AppKit centres it, which pushes the
            // header, the sidebar and the top of the list out of view (a
            // blank, "stuck" window).
            GeometryReader { proxy in
            Group {
                switch navigation.selection ?? .studio {
                case .studio:
                    StudioDashboardView(bridge: bridge, runtime: runtime, navigation: navigation)
                case .controls:
                    ControlsView(bridge: bridge)
                case .lighting:
                    LightingView(bridge: bridge)
                case .herdr:
                    HerdrView(bridge: bridge)
                case .inspector:
                    if runtime.inspectorRequiresHardware {
                        InspectorHardwareNotice()
                    } else if runtime.inspectorReady {
                        ContentView()
                            .environmentObject(runtime.inspectorModel)
                            .onAppear { runtime.connectInspectorIfNeeded() }
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Handing the pad to Inspector…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .inputMonitoring:
                    InputMonitoringSettingsView(runtime: runtime, bridge: runtime.bridge)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .frame(minWidth: 1200, minHeight: 780)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            studioPermissionGranted = WLDevice.hasInputMonitoringAccess
        }
        .onChange(of: navigation.selection) { selection in
            if selection == .inspector { runtime.enterInspector() }
            else { runtime.leaveInspector() }
        }
        .onChange(of: bridge.emulator != nil) { isEmulating in
            if navigation.selection == .inspector,
               runtime.inspectorRequiresHardware,
               !isEmulating {
                runtime.enterInspector()
            }
        }
        .onAppear {
            if navigation.selection == .inspector { runtime.enterInspector() }
        }
        .onDisappear { runtime.leaveInspector() }
    }

    private func workspaceRow(_ destination: StudioDestination) -> some View {
        Button {
            guard !runtime.isTransitioning else { return }
            navigation.selection = destination
        } label: {
            HStack(spacing: 8) {
                Label(destination.rawValue, systemImage: destination.symbol)
                Spacer(minLength: 0)
                if destination == .inputMonitoring, !studioPermissionGranted {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Permission needs review")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            navigation.selection == destination
                ? Color.accentColor.opacity(0.17)
                : Color.clear
        )
        .accessibilityAddTraits(navigation.selection == destination ? .isSelected : [])
    }

    private var deviceStatus: String {
        guard bridge.isRunning else { return "Studio is off" }
        return bridge.deviceConnected ? bridge.deviceName : "Looking for the pad"
    }

    private var appVersion: String {
        AppIdentity.versionDescription
    }
}

private struct InspectorHardwareNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Inspector needs the physical pad")
                .font(.title2.weight(.semibold))
            Text("Turn off Emulate the pad in the menu-bar panel, then choose Inspector again. The preview emulator stays isolated from the Inspector and never touches hardware.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(36)
        .frame(maxWidth: 620, maxHeight: .infinity, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InputMonitoringSettingsView: View {
    @ObservedObject var runtime: StudioRuntimeCoordinator
    @ObservedObject var bridge: BridgeController
    @State private var requestMessage: String?

    @State private var studioHasAccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input Monitoring")
                        .font(.largeTitle.weight(.bold))
                    Text("Permission is managed by macOS per app. Request access here; if macOS shows nothing, Show me how… walks you through allowing it in System Settings.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                studioCard

                permissionCard(
                    title: AppIdentity.inspectorDisplayName,
                    subtitle: "The standalone Inspector is a separate app and needs its own Input Monitoring grant. Launching it requests access from its own process.",
                    isGranted: nil,
                    symbol: "waveform.path.ecg"
                ) {
                    Button {
                        requestMessage = nil
                        runtime.openStandaloneInspector()
                    } label: {
                        Label("Launch standalone Inspector to request access", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }

                if let error = runtime.standaloneInspectorError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let requestMessage {
                    Label(requestMessage, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshStudioPermission)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStudioPermission()
        }
    }

    private var studioCard: some View {
        permissionCard(
            title: AppIdentity.displayName,
            subtitle: "Studio and the Inspector sidebar run in this app and share this grant.",
            isGranted: studioHasAccess,
            symbol: "keyboard"
        ) {
            AppIdentityCard()
            if studioHasAccess, bridge.permissionDenied {
                Label("Allowed in System Settings, but \(AppIdentity.shortName) still can't open the pad. Quit & Reopen so the grant takes effect.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if studioHasAccess, bridge.permissionDenied {
                    Button("Quit & Reopen") { PermissionHelperWindowController.quitAndReopen() }
                        .buttonStyle(.borderedProminent)
                    Button("Show me how…") { runtime.showInputMonitoringHelp() }
                        .buttonStyle(.bordered)
                } else if studioHasAccess {
                    Button {
                        InputMonitoringPrompt.openSettings()
                    } label: {
                        Label("Open System Settings…", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Request Access") {
                        requestMessage = nil
                        runtime.requestStudioInputMonitoringAccess()
                        refreshStudioPermission()
                        if !studioHasAccess {
                            requestMessage = "If macOS shows its request, choose Open System Settings and turn \(AppIdentity.shortName) on. If it shows nothing, the helper opens with the steps."
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Show me how…") { runtime.showInputMonitoringHelp() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func refreshStudioPermission() {
        studioHasAccess = WLDevice.hasInputMonitoringAccess
    }

    private func permissionCard<Actions: View>(
        title: String,
        subtitle: String,
        isGranted: Bool?,
        symbol: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let isGranted {
                    Label(isGranted ? "Allowed" : "Review needed", systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isGranted ? Color.green : Color.orange)
                        .fixedSize()
                } else {
                    Text("Separate app")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            actions()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct StudioDashboardView: View {
    @ObservedObject var bridge: BridgeController
    @ObservedObject var runtime: StudioRuntimeCoordinator
    @ObservedObject var navigation: StudioNavigationState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let error = bridge.lastError, !bridge.permissionDenied {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Creator Micro 2")
                                    .font(.title2.weight(.semibold))
                                Text(bridge.deviceConnected ? "Physical layout and live key state" : "Waiting for the pad")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await runtime.setStudioEnabled(!BridgeSettings.enabled) }
                            } label: {
                                Label(BridgeSettings.enabled ? "Turn off" : "Turn on",
                                      systemImage: BridgeSettings.enabled ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                        StudioPadMapView(bridge: bridge)
                        HStack {
                            Text("Select a key, the dial or the joystick to run its action. Actions are Studio settings and never write to device flash.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit controls…") { navigation.selection = .controls }
                                .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

                    VStack(spacing: 14) {
                        deviceCard
                        agentsCard
                        statusLegend
                    }
                    .frame(width: 340)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your Studio")
                    .font(.largeTitle.weight(.bold))
                Text("A clear view of the pad, the agents, and what needs your attention.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            headerStatus
        }
    }

    /// A status with a fix is a button; a passive one is plain text with a
    /// coloured dot, so it never looks clickable (HIG).
    @ViewBuilder
    private var headerStatus: some View {
        if runtime.isInspectorActive {
            passiveStatus("Inspector active", color: .accentColor, symbol: "waveform.path.ecg")
        } else if bridge.permissionDenied {
            Button {
                navigation.selection = .inputMonitoring
                runtime.requestStudioInputMonitoringAccess()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("Permission needed")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.callout.weight(.medium))
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.large)
            .help("Fix Input Monitoring…")
            .accessibilityLabel("Input Monitoring permission needed")
            .accessibilityHint("Opens the Input Monitoring page and asks macOS for access")
        } else if bridge.deviceConnected {
            passiveStatus("Connected", color: .green)
        } else {
            passiveStatus("Waiting for the pad", color: .secondary)
        }
    }

    private func passiveStatus(_ title: String, color: Color, symbol: String? = nil) -> some View {
        HStack(spacing: 7) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(color)
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
            Text(title).foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(title)")
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DEVICE")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(1)
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bridge.deviceConnected ? bridge.deviceName : "Creator Micro 2")
                        .font(.headline)
                    Text(bridge.deviceConnected ? "Bluetooth connected" : "Not connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()
            LabeledContent("Firmware", value: bridge.firmware)
            LabeledContent("Battery", value: bridge.battery ?? "—")
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var agentsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AGENTS")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                Spacer()
                Text("\(bridge.agents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if bridge.agents.isEmpty {
                Text("No agents running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(bridge.agents.enumerated()), id: \.offset) { slot, agent in
                            Button {
                                Task { await bridge.focusSlot(slot) }
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(agentStatusKeyColor(for: slot) ?? Color.secondary.opacity(0.32))
                                        .frame(width: 11, height: 11)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(agent.shortName).lineLimit(1)
                                        Text("\(agent.status) · \(agentStatusKeyLabel(for: slot))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .disabled(!bridge.isRunning)
                            if slot < bridge.agents.count - 1 { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func agentStatusKey(for slot: Int) -> Int? {
        guard bridge.agentKeyIDs.indices.contains(slot) else { return nil }
        let key = bridge.agentKeyIDs[slot]
        return bridge.action(for: key) == .focusAgent ? key : nil
    }

    private func agentStatusKeyColor(for slot: Int) -> Color? {
        agentStatusKey(for: slot).flatMap { bridge.keyColors[$0] }
    }

    private func agentStatusKeyLabel(for slot: Int) -> String {
        guard bridge.agentKeyIDs.indices.contains(slot) else { return "no status key" }
        let key = bridge.agentKeyIDs[slot]
        return bridge.action(for: key) == .focusAgent ? "key \(key) · status" : "key \(key) · action"
    }

    private var statusLegend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STATUS KEY")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .tracking(1)
            HStack(spacing: 14) {
                statusDot("Idle", .green)
                statusDot("Done", .blue)
                statusDot("Working", .orange)
                statusDot("Needs you", .red)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statusDot(_ title: String, _ color: Color) -> some View {
        Label {
            Text(title).font(.caption)
        } icon: {
            Circle().fill(color).frame(width: 9, height: 9)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }
}

private struct StudioPadMapView: View {
    @ObservedObject var bridge: BridgeController
    private let keyWidth: CGFloat = 120
    private let keyHeight: CGFloat = 100
    private let gap: CGFloat = 12

    var body: some View {
        VStack(spacing: gap) {
            ForEach(Array(Pad.physicalDisplayRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(row) { cell in cellView(cell) }
                }
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Creator Micro 2 physical key map")
    }

    @ViewBuilder
    private func cellView(_ cell: Pad.DisplayCell) -> some View {
        switch cell {
        case .key(let key): keyButton(key)
        case .dial: dialControl
        case .joystick: joystickControl
        case .caseMark: caseMark
        }
    }

    private func keyButton(_ key: Int) -> some View {
        let color = bridge.keyColors[key]
        let action = bridge.keyBindings.action(for: key)
        let slot = bridge.agentSlot(for: key)
        let isAgentStatus = slot != nil && action == .focusAgent
        let colorRoleLabel = isAgentStatus ? slot.map { "STATUS S\($0 + 1)" } ?? "ACTION" : "ACTION"
        let description = keyDescription(key)
        return Button {
            bridge.handleKeyPress(key)
        } label: {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color ?? Color.white.opacity(Pad.boundKeyIDs.contains(key) ? 0.13 : 0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(color == nil ? 0.15 : 0.45), lineWidth: 1)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(key)")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(color == nil ? .white.opacity(0.5) : .black.opacity(0.62))
                        .padding(8)
                }
                .overlay(alignment: .topLeading) {
                    Text(colorRoleLabel)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(isAgentStatus ? Color.black.opacity(0.48) : Color.orange.opacity(0.82),
                                    in: Capsule())
                        .padding(6)
                }
                .frame(width: keyWidth, height: keyHeight)
        }
        .buttonStyle(.plain)
        .disabled(!bridge.isRunning)
        .accessibilityLabel(description)
        .help(description)
    }

    private var dialControl: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .frame(width: 68, height: 68)
            Capsule().fill(Color.white.opacity(0.8))
                .frame(width: 5, height: 15)
                .offset(y: -24)
            HStack(spacing: 9) {
                Button { bridge.handleKeyPress(Pad.dialDownID) } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help(inputDescription(Pad.dialDownID))
                Button { bridge.handleKeyPress(Pad.dialPushID) } label: {
                    Image(systemName: "smallcircle.filled.circle")
                }
                .help(inputDescription(Pad.dialPushID))
                Button { bridge.handleKeyPress(Pad.dialUpID) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(inputDescription(Pad.dialUpID))
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.plain)
            .disabled(!bridge.isRunning)
        }
        .frame(width: keyWidth, height: keyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rotary dial")
    }

    private var joystickControl: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.12))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .frame(width: 68, height: 68)
            Circle().fill(Color.white.opacity(0.3)).frame(width: 11, height: 11)
            arrowButton("chevron.up", Pad.joyNorthID).offset(y: -25)
            arrowButton("chevron.left", Pad.joyWestID).offset(x: -25)
            arrowButton("chevron.right", Pad.joyEastID).offset(x: 25)
            arrowButton("chevron.down", Pad.joySouthID).offset(y: 25)
        }
        .frame(width: keyWidth, height: keyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Four-way joystick")
    }

    private func arrowButton(_ symbol: String, _ key: Int) -> some View {
        Button { bridge.handleKeyPress(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!bridge.isRunning)
        .help(inputDescription(key))
    }

    private var caseMark: some View {
        Circle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 34, height: 34)
            .frame(width: keyWidth, height: keyHeight)
            .accessibilityLabel("Circular case mark, not a key")
    }

    private func keyDescription(_ key: Int) -> String {
        let action = bridge.keyBindings.action(for: key)
        if let slot = bridge.agentSlot(for: key) {
            if action == .focusAgent, slot < bridge.agents.count {
                let agent = bridge.agents[slot]
                return "Key \(key), agent status for slot \(slot + 1): \(agent.displayName), \(agent.status)"
            }
            if action == .focusAgent {
                return "Key \(key), agent status for slot \(slot + 1); no current agent in this slot."
            }
            return "Key \(key), layout slot \(slot + 1), action color: \(action.summary); this action takes precedence over agent status."
        }
        return inputDescription(key)
    }

    private func inputDescription(_ input: Int) -> String {
        let name = Pad.input(input)?.name ?? "Input \(input)"
        let action = bridge.keyBindings.action(for: input)
        switch action {
        case .none:
            return "\(name), no action"
        case .focusAgent:
            return bridge.agentSlot(for: input) == nil
                ? "\(name), return focus to the currently selected Herdr agent"
                : "\(name), focus its assigned agent"
        default:
            return "\(name), \(action.summary)"
        }
    }
}

#Preview("Studio · Device First") {
    let runtime = StudioRuntimeCoordinator.preview()
    let navigation = StudioNavigationState()
    return StudioWindowView(runtime: runtime, bridge: runtime.bridge, navigation: navigation)
        .frame(width: 1460, height: 940)
        .allowsHitTesting(false)
}

#Preview("Studio · Inspector") {
    let runtime = StudioRuntimeCoordinator.preview()
    let navigation = StudioNavigationState()
    navigation.selection = .inspector
    return StudioWindowView(runtime: runtime, bridge: runtime.bridge, navigation: navigation)
        .frame(width: 1460, height: 940)
        .allowsHitTesting(false)
}

#Preview("Studio · Input Monitoring") {
    let runtime = StudioRuntimeCoordinator.preview()
    let navigation = StudioNavigationState()
    navigation.selection = .inputMonitoring
    return StudioWindowView(runtime: runtime, bridge: runtime.bridge, navigation: navigation)
        .frame(width: 1460, height: 940)
        .allowsHitTesting(false)
}

#Preview("Studio · Permission Needed") {
    let bridge = BridgeController.previewFixture(permissionDenied: true)
    let runtime = StudioRuntimeCoordinator.preview(bridge: bridge)
    let navigation = StudioNavigationState()
    return StudioWindowView(runtime: runtime, bridge: bridge, navigation: navigation)
        .frame(width: 1460, height: 940)
        .allowsHitTesting(false)
}
