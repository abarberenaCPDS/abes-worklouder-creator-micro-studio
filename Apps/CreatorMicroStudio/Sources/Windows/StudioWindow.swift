import AppKit
import SwiftUI
import CreatorMicroStudioKit

enum StudioDestination: String, Identifiable, Hashable {
    case studio = "Studio"
    case inspector = "Inspector"
    case inputMonitoring = "Input Monitoring"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .studio: return "keyboard"
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

    func openStudioInputMonitoringSettings() {
        guard !previewMode else { return }
        let granted = WLDevice.requestInputMonitoringAccessIfNeeded()
        if granted, BridgeSettings.enabled {
            Task { await startIfNeeded() }
        }
        openInputMonitoringPane()
    }

    func openStandaloneInspector() {
        guard !previewMode else { return }
        standaloneInspectorError = nil
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "dev.abeisonai.worklouder.inspector"
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

            let appURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/AbesWorkLouderCreatorMicroStudioInspector.app")
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
        guard shouldResume, BridgeSettings.enabled else { return }
        await bridge.useEmulator(BridgeSettings.emulate)
        await bridge.start()
    }

    private func openInputMonitoringPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
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
            inspectorRequiresHardware = false
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
            if shouldResume, BridgeSettings.enabled {
                await bridge.useEmulator(BridgeSettings.emulate)
                await bridge.start()
            }
            isTransitioning = false
        }
    }

    private func wireActions() {
        let bridge = self.bridge

        let stack = StackPanelController.shared
        stack.onVisibilityChange = { [weak bridge] open in
            Task { await bridge?.setStackPanelOpen(open) }
        }
        bridge.onStackKey = { stack.toggle() }

        let land = LandPanelController.shared
        land.onVisibilityChange = { [weak bridge] open in
            Task { await bridge?.setLandPanelOpen(open) }
        }
        bridge.onLandKey = { land.handleLandKey() }

        let voice = VoiceController.shared
        voice.onActiveChange = { [weak bridge] active in
            Task { await bridge?.setVoiceActive(active) }
        }
        voice.onError = { [weak bridge] message in bridge?.noteError(message) }
        bridge.onVoiceKey = { voice.handleVoiceKey() }

        let tune = TuneController.shared
        tune.onError = { [weak bridge] message in bridge?.noteError(message) }
        tune.bindings = { [weak bridge] in bridge?.keyBindings ?? KeyBindings() }
        bridge.onDial = { step in tune.handleDial(step) }
        bridge.onJoystick = { direction in tune.handleJoystick(direction) }
        bridge.onKeyIntercept = { index in
            guard index != Pad.landKeyID else { return false }
            return land.handleOtherKey()
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1740, height: 940),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Abe's WorkLouder Creator Micro Studio"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titleVisibility = .visible
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
            Group {
                switch navigation.selection ?? .studio {
                case .studio:
                    StudioDashboardView(bridge: bridge, runtime: runtime)
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
                    InputMonitoringSettingsView(runtime: runtime)
                }
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
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
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
    @State private var requestMessage: String?

    @State private var studioHasAccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input Monitoring")
                        .font(.largeTitle.weight(.bold))
                    Text("Permission is managed by macOS per app. Request access here, then review or change either app’s setting in System Settings.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                permissionCard(
                    title: "Abe’s WorkLouder Creator Micro Studio",
                    subtitle: "Studio and the Inspector sidebar run in this app and share this grant.",
                    isGranted: studioHasAccess,
                    buttonTitle: studioHasAccess ? "Open System Settings…" : "Request access and open Settings…",
                    symbol: "keyboard"
                ) {
                    requestMessage = nil
                    runtime.openStudioInputMonitoringSettings()
                    refreshStudioPermission()
                    requestMessage = studioHasAccess
                        ? "Studio Input Monitoring access is granted."
                        : "Approve the macOS request if shown, then enable Studio in the Input Monitoring list."
                }

                permissionCard(
                    title: "Abe’s WorkLouder Creator Micro Studio Inspector",
                    subtitle: "The standalone Inspector is a separate app and needs its own Input Monitoring grant. Launching it requests access from its own process.",
                    isGranted: nil,
                    buttonTitle: "Launch standalone Inspector to request access",
                    symbol: "waveform.path.ecg"
                ) {
                    requestMessage = nil
                    runtime.openStandaloneInspector()
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

    private func refreshStudioPermission() {
        studioHasAccess = WLDevice.hasInputMonitoringAccess
    }

    private func permissionCard(
        title: String,
        subtitle: String,
        isGranted: Bool?,
        buttonTitle: String,
        symbol: String,
        action: @escaping () -> Void
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
            Button(action: action) {
                Label(buttonTitle, systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
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
    @State private var editingKey = false

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
                            Text("Select a key to run its action. Edit values without writing to device flash.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit key values…") { editingKey = true }
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
        .sheet(isPresented: $editingKey) {
            KeyActionEditorView(bridge: bridge)
                .frame(width: 520, height: 430)
        }
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
            Label(runtime.isInspectorActive ? "Inspector active" : (bridge.permissionDenied ? "Permission needed" : (bridge.deviceConnected ? "Connected" : "Waiting")),
                  systemImage: runtime.isInspectorActive ? "waveform.path.ecg" : "circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(runtime.isInspectorActive ? Color.accentColor : (bridge.permissionDenied ? .orange : (bridge.deviceConnected ? .green : .secondary)))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
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
                ForEach(Array(bridge.agents.prefix(Pad.agentKeyIDs.count).enumerated()), id: \.offset) { slot, agent in
                    Button {
                        Task { await bridge.focusSlot(slot) }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(bridge.keyColors[Pad.agentKeyIDs[slot]] ?? Color.secondary.opacity(0.32))
                                .frame(width: 11, height: 11)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.shortName).lineLimit(1)
                                Text(agent.status).font(.caption).foregroundStyle(.secondary)
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
                    if slot < min(bridge.agents.count, Pad.agentKeyIDs.count) - 1 { Divider() }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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

private struct KeyActionEditorView: View {
    @ObservedObject var bridge: BridgeController
    @Environment(\.dismiss) private var dismiss
    @State private var key = 6
    @State private var selectedAction: KeyAction = .defaultAction
    @State private var macroText = ""
    @State private var saveError: String?

    private var canChooseAction: Bool { Pad.configurableActionKeyIDs.contains(key) }
    private var effectiveAction: KeyAction {
        canChooseAction && selectedAction != .defaultAction
            ? selectedAction
            : KeyAction.defaultAction(for: key)
    }
    private var editsPrompt: Bool {
        effectiveAction == .macro || effectiveAction == .voice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key values")
                        .font(.title2.weight(.semibold))
                    Text("Change what the Studio sends when a physical key is pressed.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Form {
                Picker("Physical key", selection: $key) {
                    ForEach(Pad.configurableActionKeyIDs, id: \.self) { id in
                        Text("Key \(id)").tag(id)
                    }
                }

                if canChooseAction {
                    Picker("Action", selection: $selectedAction) {
                        Text("Default · \(KeyAction.defaultAction(for: key).title)")
                            .tag(KeyAction.defaultAction)
                        ForEach(KeyAction.configurable.filter { $0 != .defaultAction }) { action in
                            Text(action.title).tag(action)
                        }
                    }
                } else {
                    LabeledContent("Action", value: effectiveAction.title)
                }

                if editsPrompt {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(effectiveAction == .voice ? "Optional prompt override" : "Prompt text")
                            .font(.callout.weight(.medium))
                        TextEditor(text: $macroText)
                            .font(.body)
                            .frame(minHeight: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        Text("This text is inserted into the focused agent’s prompt without submitting it. Leave blank to use the built-in action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if effectiveAction == .focusAgent, Pad.agentSlot(for: key) == nil {
                    Text("This key returns focus to the agent already selected in Herdr. Keys 0–5 focus their corresponding agent slot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
            }

            HStack {
                Text("Saved to config.json. No device keymap or flash write is made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save value") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .onAppear(perform: loadSelection)
        .onChange(of: key) { _ in loadSelection() }
    }

    private func loadSelection() {
        let bindings = bridge.keyBindings
        selectedAction = canChooseAction
            ? (bindings.actionOverride(for: key) ?? .defaultAction)
            : KeyAction.defaultAction(for: key)
        macroText = bindings.text(for: key) ?? ""
        saveError = nil
    }

    private func save() {
        do {
            if canChooseAction {
                try KeyBindings.setAction(selectedAction, for: key)
            }
            if editsPrompt {
                try KeyBindings.setText(macroText, for: key)
            }
            bridge.reloadKeyBindings()
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
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
                Button { bridge.handleKeyPress(Pad.dialUpID) } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.plain)
            .disabled(!bridge.isRunning)
        }
        .frame(width: keyWidth, height: keyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rotary dial")
        .help("Turn the dial to adjust reasoning effort")
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
        .help("Move the joystick to choose a model")
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
        .help("Joystick direction")
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
        if action == .focusAgent,
           let slot = Pad.agentSlot(for: key), slot < bridge.agents.count {
            let agent = bridge.agents[slot]
            return "Key \(key), \(agent.shortName), \(agent.status)"
        }
        switch action {
        case .defaultAction, .none:
            return "Key \(key), no action"
        case .focusAgent:
            return Pad.agentSlot(for: key) == nil
                ? "Key \(key), return focus to the currently selected Herdr agent"
                : "Key \(key), focus its assigned agent"
        case .stack:
            return "Key \(key), GitButler stack"
        case .cycleTabs:
            return "Key \(key), cycle tabs"
        case .land:
            return "Key \(key), land branches"
        case .macro:
            return "Key \(key), macro: \(bridge.keyBindings.text(for: key) ?? "not configured")"
        case .voice:
            return bridge.keyBindings.text(for: key).map { "Key \(key), macro: \($0)" }
                ?? "Key \(key), Superwhisper voice control"
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

#Preview("Edit Key Values") {
    KeyActionEditorView(bridge: .previewFixture())
        .frame(width: 560, height: 460)
        .allowsHitTesting(false)
}
