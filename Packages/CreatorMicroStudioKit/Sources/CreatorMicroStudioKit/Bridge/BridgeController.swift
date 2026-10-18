import Foundation
import SwiftUI
import IOKit
import IOKit.hid

/// Drives the pad from Herdr agent status: each agent gets its own key, and the
/// underglow carries a worst-state-wins aggregate.
///
/// Liveness comes from three places, so a missed event can never leave the pad
/// showing something stale:
///   1. a lifecycle stream (panes appearing, disappearing, gaining agents)
///   2. one status stream per agent pane (instant transitions)
///   3. a slow poll of `agent.list` as a backstop
///
/// `agent.list` is always the source of truth; events only decide *when* to
/// look. This is a port of `bin/leds.js` — including the parts that were bug
/// fixes, which are called out where they matter.
@MainActor
public final class BridgeController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var deviceName = "—"
    @Published public private(set) var firmware = "—"
    @Published public private(set) var battery: String?
    /// Every agent Herdr reports, in its sidebar order. Slot N (0-based) is
    /// element N; agents past the sixth have no key.
    @Published public private(set) var agents: [HerdrAgent] = []
    /// The colour each lit key shows (keys that are off are absent).
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    /// 0...1 per lit key, so mirrors can dim a key the way the pad does.
    @Published public private(set) var keyBrightness: [Int: Double] = [:]
    /// The full thread painted on each key 0...12, lit or not.
    @Published public private(set) var keyThreads: [Int: OAI.Thread] = [:]
    /// What the underglow (ambient zone) is showing.
    @Published public private(set) var underglowZone = OAI.Zone.dark
    /// What the keys-plate (backlight) zone is showing.
    @Published public private(set) var backlightZone = OAI.Zone.dark
    @Published public private(set) var aggregateState: String?
    /// HID, permission and keymap problems. Herdr success never clears it.
    @Published public private(set) var deviceError: String?
    /// The last input action that failed — a Herdr call, a shell command, a
    /// missing permission — kept apart from device and Herdr errors so a
    /// healthy poll does not wipe it. Cleared when the next action starts.
    @Published public private(set) var lastActionError: String?
    /// The most recent action dispatched, for "it fired" feedback.
    @Published public private(set) var lastAction: ActionEvent?
    /// Connection, version, workspaces and tabs of the Herdr server.
    @Published public private(set) var herdr = HerdrStatus()
    /// Whether the Studio may post synthesised events (scroll, shortcuts,
    /// media keys, typing, voice). Refresh with `refreshAccessibilityStatus()`.
    @Published public private(set) var accessibilityTrusted = SystemActions.isAccessibilityTrusted
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// Whether a Claude voice take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false
    /// False once the pad is known to keep its own code (stock play/pause)
    /// on the dial push instead of AG19: the press then never reaches the
    /// Studio, so its host-side action cannot run.
    @Published public private(set) var dialPushAvailable = true
    /// Joystick inputs the pad's active profile has no sector for (it was set
    /// up with fewer directions); they never report. Not an error.
    @Published public private(set) var absentJoystickInputs: [Int] = []
    /// What the dial push has instead of AG19, when `dialPushAvailable` is
    /// false and the read-back said.
    @Published public private(set) var dialPushFirmwareCode: String?
    /// True while the keymap is being read, written or verified. Lighting
    /// writes wait for it, so nothing interleaves with a flash write.
    @Published public private(set) var keymapBusy = false
    /// The pad refused the core bindings and the Studio has stopped
    /// rewriting it; `retryKeymapBinding()` tries again.
    @Published public private(set) var keymapNeedsRetry = false

    /// One error line for places with room for one: device first, then the
    /// last failed action, then Herdr.
    public var lastError: String? {
        deviceError ?? lastActionError ?? herdr.errorMessage
    }

    public var config: BridgeConfig
    /// Where bindings and lighting are read from and saved to.
    public let store: StudioConfigStore
    /// Actions for every input, reloaded on every bridge start so a config
    /// edit only needs an off/on toggle, not a relaunch.
    @Published public private(set) var keyBindings: KeyBindings
    /// The saved lighting, or the unsaved preview while one is showing.
    @Published public private(set) var lighting: LightingPreferences
    /// True while `previewLighting(_:)` is showing something not on disk.
    @Published public private(set) var isPreviewingLighting = false
    /// The lighting as last read from `config.json`, never a preview. An
    /// editor rebases its draft on this and saves against it, so a save only
    /// writes what the editor changed.
    @Published public private(set) var savedLighting: LightingPreferences

    /// What the Herdr page lists: every input with the agent it reaches.
    public var inputMappings: [HerdrInputMapping] {
        HerdrInputMapping.mappings(bindings: keyBindings, agents: agents)
    }

    /// Agents no input reaches, by index into `agents`.
    public var unassignedAgentIndices: [Int] {
        HerdrInputMapping.unassignedAgentIndices(bindings: keyBindings, agents: agents)
    }

    /// Inputs whose action needs Accessibility and can actually fire: a dial
    /// push the pad does not report is left out.
    public var inputsRequiringAccessibility: [Int] {
        keyBindings.inputsRequiringAccessibility.filter { $0 != Pad.dialPushID || dialPushAvailable }
    }

    /// Whether any input is bound to an action that needs Accessibility.
    public var needsAccessibility: Bool { !inputsRequiringAccessibility.isEmpty }

    /// Called when a voice action fires. The bridge owns the key, the app
    /// owns the take, so this is where the two meet.
    public var onVoiceKey: (() -> Void)?
    /// Called for the model and effort actions. The app's tune controller
    /// owns the per-pane state those need.
    public var onTune: ((TuneCommand) -> Void)?

    /// Asks the user for text, for a Herdr command's `{ask:Prompt=Default}`:
    /// called with the prompt and the default (placeholders already filled
    /// in), answering the text or nil to cancel the action silently. Unset,
    /// a command that asks fails with a clear error instead.
    public var onAsk: HerdrCommand.Ask?

    /// For tests: Herdr's focus for command placeholders, instead of asking
    /// the server.
    var herdrContextProvider: ((Set<HerdrCommand.Placeholder>) async throws -> HerdrCommand.Context)?
    /// For tests: receives a Herdr command's final arguments instead of the
    /// `herdr` binary.
    var herdrCommandRunner: (([String]) async throws -> Void)?

    /// For tests: when set, actions the package would execute itself
    /// (Herdr, system, launch) are handed here instead, so routing can be
    /// checked without touching Herdr or the machine. App callbacks still run.
    var actionSink: ((InputAction, Int?) -> Void)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    private var lifecycle: HerdrEventStream?
    private var statusStreams: [String: HerdrEventStream] = [:]
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    /// The one keymap check/write in flight; a second caller waits for it.
    private var keymapTask: Task<Void, Never>?
    /// Set once this run knows the keymap outcome, so a Bluetooth reconnect
    /// does not read (or write) it again. Cleared by start() and Retry.
    private var keymapSettled = false
    /// Firmware debug lines seen during the current keymap operation.
    private var keymapLog: [String] = []
    /// The settled keymap problem, re-shown after a reconnect clears
    /// `deviceError` without checking again.
    private var keymapErrorMessage: String?
    /// Host-side memory of what each firmware refused.
    let keymapRecords: KeymapRecords
    /// For tests: how long a keymap read-back waits.
    var keymapTiming = KeymapManager.Timing.standard
    /// When the last refresh started, for spacing event-driven ones.
    private var lastRefreshStart: Date?
    /// Back-to-back event-driven refreshes start at least this far apart.
    static let minimumEventRefreshGap: TimeInterval = 0.5
    /// Lighting previews: one paint in flight, ≥150 ms apart, latest wins.
    private lazy var previewPainter = CoalescingRunner(interval: Self.previewPaintInterval) { [weak self] in
        guard let self, self.isRunning else { return }
        self.lastFingerprint = nil
        await self.paint(self.agents)
    }
    /// Minimum gap between the starts of two preview paints.
    static let previewPaintInterval: TimeInterval = 0.15
    /// Bumped by every start() and stop(), so a refresh that was awaiting
    /// Herdr across one drops its results instead of writing stale status.
    private var runGeneration = 0
    private var lastFingerprint: String?
    private var issuedIDs = Set<Int>()
    private var warnedPermission = false
    private var herdrMetadataAt: Date?
    private var herdrPingAt: Date?
    /// Workspace and tab labels change rarely; re-read them this often, or
    /// sooner when an agent shows up in a tab not seen yet.
    private static let herdrMetadataInterval: TimeInterval = 10
    private static let herdrPingInterval: TimeInterval = 60

    public init(
        config: BridgeConfig = BridgeConfig(),
        store: StudioConfigStore = .standard,
        keymapRecords: KeymapRecords = .standard
    ) {
        self.store = store
        self.keymapRecords = keymapRecords
        let lighting = LightingPreferences.load(from: store)
        var config = config
        config.apply(lighting)
        self.config = config
        self.lighting = lighting
        self.savedLighting = lighting
        self.keyBindings = KeyBindings.load(from: store)
        wire(device)
    }


    /// Stable, disconnected sample state for SwiftUI Canvas previews. It never
    /// opens HID, starts polling, or contacts Herdr.
    public static func previewFixture(permissionDenied: Bool = false) -> BridgeController {
        let bridge = BridgeController(
            store: StudioConfigStore(path: "/dev/null/preview-config.json"),
            keymapRecords: KeymapRecords(defaults: UserDefaults(suiteName: "dev.abeisonai.worklouder.preview") ?? .standard)
        )
        bridge.permissionDenied = permissionDenied
        bridge.isRunning = !permissionDenied
        bridge.deviceConnected = !permissionDenied
        bridge.keymapReady = true
        bridge.deviceName = permissionDenied ? "—" : "Creator Micro 2 · Preview"
        bridge.firmware = permissionDenied ? "—" : "2.4.1"
        bridge.battery = permissionDenied ? nil : "82%"
        bridge.agents = [
            HerdrAgent(agent: "claude", status: "working", paneID: "w1:p1", tabID: "w1:t1",
                       workspaceID: "w1", cwd: "/workspace/api", focused: true,
                       displayAgent: "Claude Code"),
            HerdrAgent(agent: "codex", status: "idle", paneID: "w1:p2", tabID: "w1:t1",
                       workspaceID: "w1", cwd: "/workspace/web", displayAgent: "Codex"),
            HerdrAgent(agent: "claude", status: "blocked", paneID: "w1:p3", tabID: "w1:t2",
                       workspaceID: "w1", cwd: "/workspace/worker", name: "worker"),
            HerdrAgent(agent: "codex", status: "done", paneID: "w2:p1", tabID: "w2:t1",
                       workspaceID: "w2", cwd: "/workspace/docs"),
        ]
        bridge.herdr = HerdrStatus(
            reachability: permissionDenied ? .unknown : .connected,
            version: "0.9.5",
            protocolVersion: 22,
            lastRefreshAt: Date(),
            lifecycleSubscribed: !permissionDenied,
            statusStreamCount: 4,
            workspaces: [
                HerdrWorkspace(workspaceID: "w1", number: 1, label: "abes-work-louder", focused: true),
                HerdrWorkspace(workspaceID: "w2", number: 2, label: "docs"),
            ],
            tabs: [
                HerdrTab(tabID: "w1:t1", workspaceID: "w1", number: 1, focused: true, label: "main"),
                HerdrTab(tabID: "w1:t2", workspaceID: "w1", number: 2, label: "worker"),
                HerdrTab(tabID: "w2:t1", workspaceID: "w2", number: 1, label: "notes"),
            ]
        )
        bridge.keyBindings = KeyBindings(actions: [
            7: .nextTab,
            9: .insertText("Open pull requests"),
            10: .voice,
            12: .submitPrompt("Run the test suite"),
        ])
        bridge.keyColors = [
            0: Color(packedRGB: 0xF2A541),
            1: Color(packedRGB: 0x43B883),
            2: Color(packedRGB: 0x4C9AFF),
            3: Color(packedRGB: 0x8B6CFF),
            4: Color(packedRGB: 0xF26D7D),
            5: Color(packedRGB: 0x32B8A6),
            6: Color(packedRGB: 0x7C4DFF),
            7: Color(packedRGB: 0x00BFA5),
            8: Color(packedRGB: 0xE91E63),
            9: Color(packedRGB: 0x90A4AE),
            10: Color(packedRGB: 0xECEFF1),
            11: Color(packedRGB: 0xECEFF1),
            12: Color(packedRGB: 0x90A4AE),
        ]
        bridge.keyBrightness = Dictionary(uniqueKeysWithValues: (0..<Pad.keyCount).map {
            ($0, $0 < 6 ? 1.0 : 0.3)
        })
        bridge.underglowZone = StatusMapper.ambientZone(for: "working", bridge.config)
        bridge.aggregateState = "working"
        return bridge
    }

    /// Swap the hardware for a virtual pad, or back. The device is rebuilt
    /// either way, so the bridge reconnects from scratch rather than trying to
    /// carry state across a transport it no longer has.
    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil) else { return }
        let wasRunning = isRunning
        if wasRunning { await stop() }
        let pad = on ? PadEmulator() : nil
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
        if wasRunning { await start() }
    }

    /// For tests: drive this emulator, without starting the bridge.
    func useEmulatorForTesting(_ pad: PadEmulator) {
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
    }

    /// For tests: (re)connect and run the keymap check exactly as a connect
    /// or Bluetooth reconnect does. Never touches Herdr.
    func openDeviceForTesting() async {
        await openDevice()
    }

    private func wire(_ device: WLDevice) {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false
            self.lastFingerprint = nil
            if self.isRunning { self.scheduleReopen() }
        }
        device.onTX = { [weak self] _, _, id in
            self?.issuedIDs.insert(id)
        }
        device.onResponse = { [weak self] id, _, _ in
            guard let self else { return }
            // A reply to an id we never sent came from another client.
            if self.issuedIDs.remove(id) == nil { self.contendingClient = true }
        }
        device.onDeviceLog = { [weak self] line in
            // Only kept while a keymap operation runs: it is the one place a
            // firmware explanation for a refused write can show up.
            guard let self, self.keymapBusy else { return }
            self.keymapLog.append(line)
            if self.keymapLog.count > 20 { self.keymapLog.removeFirst(self.keymapLog.count - 20) }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, method == OAI.notifyHID else { return }
            guard let dict = params as? [String: Any] else { return }
            guard (dict["act"] as? Int) == 1 else { return }   // press, not release
            guard let index = OAI.agIndex(dict["k"] as? String) else { return }
            self.handleKeyPress(index)
        }
    }

    // MARK: - Lifecycle

    public func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        runGeneration &+= 1
        deviceError = nil
        lastActionError = nil
        contendingClient = false
        keymapSettled = false
        loadConfiguration()
        refreshAccessibilityStatus()

        await openDevice()
        startLifecycleStream()
        await refresh()

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.config.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    public func stop() async {
        isRunning = false
        runGeneration &+= 1
        pollTask?.cancel(); pollTask = nil
        previewPainter.cancel()
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        lifecycle?.stop(); lifecycle = nil
        statusStreams.values.forEach { $0.stop() }
        statusStreams.removeAll()
        lastFingerprint = nil
        herdrMetadataAt = nil
        herdrPingAt = nil

        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there. Lights-off is
        // skipped while a keymap write is in flight rather than queued
        // behind it; the disconnect fails whatever is still waiting.
        if device.isConnected {
            if !keymapBusy { await allLightsOff() }
            device.disconnect(reason: nil)
        }
        deviceConnected = false
        setIfChanged(\.keyColors, [:])
        setIfChanged(\.keyEffects, [:])
        setIfChanged(\.keyBrightness, [:])
        setIfChanged(\.keyThreads, [:])
        setIfChanged(\.underglowZone, .dark)
        setIfChanged(\.backlightZone, .dark)
        setIfChanged(\.aggregateState, nil)
        setIfChanged(\.agents, [])
        setIfChanged(\.herdr, HerdrStatus(pollInterval: config.pollInterval))
    }

    // MARK: - Configuration

    private func loadConfiguration() {
        keyBindings = KeyBindings.load(from: store)
        let saved = LightingPreferences.load(from: store)
        savedLighting = saved
        lighting = saved
        isPreviewingLighting = false
        config.apply(saved)
    }

    /// Re-reads bindings and lighting from `config.json` and repaints — after
    /// a Studio edit, or when the standalone Inspector may have saved.
    public func reloadConfiguration() {
        loadConfiguration()
        lastFingerprint = nil
        if isRunning { Task { await refresh() } }
    }

    /// Apply host-side action edits immediately without a HID keymap write.
    public func reloadKeyBindings() {
        keyBindings = KeyBindings.load(from: store)
        lastFingerprint = nil
        if isRunning { Task { await refresh() } }
    }

    /// Re-reads only the lighting, dropping any unsaved preview.
    public func reloadLighting() {
        let saved = LightingPreferences.load(from: store)
        savedLighting = saved
        lighting = saved
        isPreviewingLighting = false
        config.apply(saved)
        lastFingerprint = nil
        if isRunning { Task { await refresh() } }
    }

    /// Paints `prefs` without saving, for a live editor. `reloadLighting()`
    /// or `saveLighting(_:)` ends the preview.
    ///
    /// A purely local change, so this repaints from the agents already
    /// fetched instead of asking Herdr again, and coalesces: a slider drag
    /// runs at most one paint at a time, at most one every 150 ms, and the
    /// trailing paint always shows the latest prefs.
    public func previewLighting(_ prefs: LightingPreferences) {
        lighting = prefs
        isPreviewingLighting = true
        config.apply(prefs)
        lastFingerprint = nil
        if isRunning { schedulePreviewPaint() }
    }

    private func schedulePreviewPaint() {
        previewPainter.request()
    }

    /// Saves an editor's draft to `config.json` and paints it. The save is a
    /// merge against what is on disk now: only fields where `prefs` differs
    /// from `baseline` (default: `savedLighting`, the prefs last loaded) are
    /// written, so changes another writer made meanwhile survive.
    public func saveLighting(_ prefs: LightingPreferences, baseline: LightingPreferences? = nil) throws {
        try LightingPreferences.save(prefs, baseline: baseline ?? savedLighting, to: store)
        reloadLighting()
    }

    /// Removes the saved lighting, back to the built-in look.
    public func restoreDefaultLighting() throws {
        try LightingPreferences.reset(in: store)
        reloadLighting()
    }

    /// Saves one input's action (`nil` resets it) and applies it.
    public func setAction(_ action: InputAction?, for input: Int) throws {
        try KeyBindings.setAction(action, for: input, store: store)
        reloadKeyBindings()
    }

    /// The same action for several inputs, in one write.
    public func setAction(_ action: InputAction?, for inputs: [Int]) throws {
        try KeyBindings.setAction(action, for: inputs, store: store)
        reloadKeyBindings()
    }

    /// Several different actions in one write; nil values reset.
    public func setActions(_ changes: [Int: InputAction?]) throws {
        try KeyBindings.setActions(changes, store: store)
        reloadKeyBindings()
    }

    /// Returns inputs to their default actions.
    public func resetActions(for inputs: [Int]) throws {
        try KeyBindings.resetActions(for: inputs, store: store)
        reloadKeyBindings()
    }

    /// The action an input runs right now.
    public func action(for input: Int) -> InputAction {
        keyBindings.action(for: input)
    }

    /// For tests and previews: use these bindings without reading the file.
    func useBindings(_ bindings: KeyBindings) {
        keyBindings = bindings
    }

    /// Re-checks the Accessibility grant, e.g. when the app becomes active.
    /// Publishes only on a change: this runs on every appearance and app
    /// activation, and each publish re-renders every view of the bridge.
    public func refreshAccessibilityStatus() {
        setIfChanged(\.accessibilityTrusted, SystemActions.isAccessibilityTrusted)
    }

    /// Raises the macOS Accessibility prompt when the grant is missing.
    public func requestAccessibility() {
        setIfChanged(\.accessibilityTrusted, SystemActions.requestAccessibility())
    }

    /// Assigns a published value only when it differs, so an unchanged poll
    /// result does not invalidate every view that observes the bridge.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<BridgeController, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    // MARK: - Device

    private func openDevice() async {
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission. The emulator needs no grant.
        if emulator == nil { WLDevice.requestInputMonitoringAccessIfNeeded() }

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            deviceName = device.info?.product ?? "Work Louder device"
            deviceError = nil
        } catch {
            deviceConnected = false
            let message = error.localizedDescription
            if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
                permissionDenied = true
                if !warnedPermission { warnedPermission = true; deviceError = message }
            } else {
                deviceError = message
            }
            scheduleReopen()
            return
        }

        if let version = try? await device.callAsync("sys.version"),
           let dict = version as? [String: Any],
           let text = dict["version"] as? String {
            firmware = text
        }
        if let status = try? await device.callAsync("device.status"),
           let dict = status as? [String: Any],
           let percent = dict["battery"] as? Int {
            let charging = (dict["is_charging"] as? Bool) == true
            battery = "\(percent)%\(charging ? " ⚡" : "")"
        }

        await ensureKeymap()
    }

    /// Per-key lighting only works on keys bound to `KV_OAI_AG*` on the active
    /// layer, and nothing reports a mismatch — `v.oai.thstatus` answers
    /// `{"ok":1}` for a key it cannot light. So check rather than assume.
    ///
    /// Flash is precious and the firmware may answer `{"ok":1}` to a write it
    /// throws away, so: one operation at a time; at most two writes per
    /// connection (see `KeymapManager.apply`); none at all on a reconnect
    /// once this run knows the outcome; and none on any launch once this
    /// firmware is on record as refusing them, until the user retries.
    private func ensureKeymap(force: Bool = false) async {
        if let running = keymapTask {
            await running.value
            guard force else { return }
        }
        guard force || !keymapSettled else {
            if let keymapErrorMessage { deviceError = keymapErrorMessage }
            return
        }
        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.checkKeymap(force: force)
        }
        keymapTask = task
        await task.value
        // A forced retry may have started its own task while this one ran.
        if keymapTask == task { keymapTask = nil }
    }

    /// Forgets what this firmware refused and checks (and if needed
    /// writes) the keymap again, then repaints.
    public func retryKeymapBinding() async {
        keymapRecords.clear(firmware: firmware)
        keymapSettled = false
        guard isRunning, deviceConnected else { return }
        await ensureKeymap(force: true)
        await forceRepaint()
    }

    private func checkKeymap(force: Bool) async {
        keymapBusy = true
        keymapLog = []
        defer {
            keymapBusy = false
            // Whatever was held back while busy paints on the next pass.
            lastFingerprint = nil
        }
        keymapErrorMessage = nil
        if firmware == "—",
           let version = try? await device.callAsync("sys.version"),
           let text = (version as? [String: Any])?["version"] as? String {
            firmware = text
        }
        let firmware = self.firmware
        // Records are per firmware version. Without the version, honour any
        // record at all rather than risk rewriting a pad that refused before.
        let versionKnown = firmware != "—"
        let notAccepted = versionKnown
            ? keymapRecords.notAccepted(firmware: firmware) : keymapRecords.anyNotAccepted()
        let pushRecorded = versionKnown
            ? keymapRecords.dialPushRejected(firmware: firmware) : keymapRecords.anyDialPushRejected()
        let mayWrite = config.manageKeymap && (force || !notAccepted)
        let pushRejected = !force && pushRecorded
        do {
            let outcome = try await KeymapManager.apply(
                device, dialPushRejected: pushRejected, mayWrite: mayWrite, timing: keymapTiming,
                inspect: { [weak self] config in
                    let absent = KeymapManager.absentJoystickInputs(config)
                    if self?.absentJoystickInputs != absent { self?.absentJoystickInputs = absent }
                }
            )
            keymapReady = true
            keymapSettled = true
            keymapNeedsRetry = false
            if config.manageKeymap { keymapRecords.setNotAccepted(false, firmware: firmware) }
            switch outcome {
            case .unchanged, .applied:
                dialPushAvailable = true
                dialPushFirmwareCode = nil
                keymapRecords.setDialPushRejected(false, firmware: firmware)
            case .dialPushUnavailable(let found):
                dialPushAvailable = false
                dialPushFirmwareCode = found
            case .appliedWithoutDialPush(let found):
                // Not an error: the pad keeps its own play/pause there.
                dialPushAvailable = false
                dialPushFirmwareCode = found
                keymapRecords.setDialPushRejected(true, firmware: firmware)
            }
            if deviceError?.hasPrefix("Keymap") == true { deviceError = nil }
        } catch let failure as KeymapManager.Failure {
            keymapReady = false
            switch failure {
            case .notAccepted(let missing):
                keymapSettled = true
                dialPushAvailable = !missing.contains(where: \.isDialPush)
                dialPushFirmwareCode = missing.first(where: \.isDialPush)?.found
                if config.manageKeymap {
                    keymapRecords.setNotAccepted(true, firmware: firmware)
                    keymapNeedsRetry = true
                    deviceError = "Keymap: " + (failure.localizedDescription) + keymapLogSuffix()
                } else {
                    let list = missing.map(\.description).joined(separator: ", ")
                    deviceError = "Keymap management is off, and the pad is not bound for: \(list). Per-key colours and those inputs will do nothing."
                }
                keymapErrorMessage = deviceError
            case .unconfirmed, .writeFailed:
                // A write may have reached flash: don't write again on a
                // reconnect or a later launch until the user retries.
                keymapSettled = true
                if config.manageKeymap {
                    keymapRecords.setNotAccepted(true, firmware: firmware)
                    keymapNeedsRetry = true
                }
                deviceError = "Keymap: \(failure.localizedDescription)" + keymapLogSuffix()
                keymapErrorMessage = deviceError
            case .noProfiles, .unreadable:
                deviceError = "Keymap: \(failure.localizedDescription)" + keymapLogSuffix()
            }
        } catch {
            keymapReady = false
            deviceError = "Keymap: \(error.localizedDescription)" + keymapLogSuffix()
        }
    }

    /// The pad's own last words during a keymap operation, if it said any.
    private func keymapLogSuffix() -> String {
        guard !keymapLog.isEmpty else { return "" }
        return " Pad log: " + keymapLog.suffix(3).joined(separator: " · ")
    }

    private func scheduleReopen() {
        guard isRunning, reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRunning else { return }
                if self.deviceConnected { break }
                await self.openDevice()
                if self.deviceConnected {
                    await self.forceRepaint()
                    break
                }
            }
            self?.reopenTask = nil
        }
    }

    // MARK: - Herdr events

    private func startLifecycleStream() {
        guard isRunning else { return }
        let stream = HerdrEventStream(subscriptions: [
            ["type": "pane.created"],
            ["type": "pane.closed"],
            ["type": "pane.exited"],
            ["type": "pane.agent_detected"],
        ])
        stream.onReady = { [weak self] in
            guard let self, !self.herdr.lifecycleSubscribed else { return }
            self.herdr.lifecycleSubscribed = true
        }
        stream.onEvent = { [weak self] _ in self?.schedule() }
        stream.onClosed = { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.lifecycle = nil
            self.herdr.lifecycleSubscribed = false
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.startLifecycleStream()
            }
        }
        lifecycle = stream.start()
    }

    /// One dedicated stream per agent pane: a subscription owns its connection
    /// and cannot be extended after the fact.
    private func reconcileStatusStreams(_ agents: [HerdrAgent]) {
        let wanted = Set(agents.compactMap(\.paneID))
        for (paneID, stream) in statusStreams where !wanted.contains(paneID) {
            stream.stop()
            statusStreams.removeValue(forKey: paneID)
        }
        for paneID in wanted where statusStreams[paneID] == nil {
            let stream = HerdrEventStream(subscriptions: [
                ["type": "pane.agent_status_changed", "pane_id": paneID],
            ])
            stream.onEvent = { [weak self] _ in self?.schedule() }
            stream.onClosed = { [weak self] _ in
                guard let self else { return }
                self.statusStreams.removeValue(forKey: paneID)
                if self.herdr.statusStreamCount != self.statusStreams.count {
                    self.herdr.statusStreamCount = self.statusStreams.count
                }
            }
            statusStreams[paneID] = stream.start()
        }
        if herdr.statusStreamCount != statusStreams.count {
            herdr.statusStreamCount = statusStreams.count
        }
    }

    /// An event-driven refresh: debounced, and spaced at least
    /// `minimumEventRefreshGap` after the previous refresh started, so busy
    /// agents cannot turn status events into a re-render storm.
    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let sinceLast = self.lastRefreshStart.map { Date().timeIntervalSince($0) } ?? .infinity
            let delay = max(self.config.debounce, Self.minimumEventRefreshGap - sinceLast)
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            self.debounceTask = nil
            await self.refresh()
        }
    }

    /// Ping and workspace/tab labels, on their own slower clocks so the poll
    /// stays one `agent.list` most of the time. A failure here is not worth
    /// marking Herdr down for — `agent.list` just worked.
    /// Works on `status`, a local copy, so the caller publishes once.
    private func refreshHerdrMetadataIfNeeded(_ fetched: [HerdrAgent], into status: inout HerdrStatus, generation: Int) async {
        let now = Date()
        if status.version == nil || now.timeIntervalSince(herdrPingAt ?? .distantPast) > Self.herdrPingInterval {
            herdrPingAt = now
            let pong = try? await HerdrClient.ping()
            guard isCurrent(generation) else { return }
            if let pong {
                status.version = pong.version
                status.protocolVersion = pong.protocolVersion
            }
        }
        let knownTabs = Set(status.tabs.map(\.tabID))
        let unseenTab = fetched.contains { agent in
            agent.tabID.map { !knownTabs.contains($0) } ?? false
        }
        guard unseenTab
                || now.timeIntervalSince(herdrMetadataAt ?? .distantPast) > Self.herdrMetadataInterval
        else { return }
        herdrMetadataAt = now
        let workspaces = try? await HerdrClient.listWorkspaces()
        guard isCurrent(generation) else { return }
        if let workspaces { status.workspaces = workspaces }
        let tabs = try? await HerdrClient.listTabs()
        guard isCurrent(generation) else { return }
        if let tabs { status.tabs = tabs }
    }

    /// Whether a refresh begun in run `generation` may still publish.
    private func isCurrent(_ generation: Int) -> Bool {
        isRunning && runGeneration == generation
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lastFingerprint = nil
        await refresh()
    }

    /// One pass: ask Herdr, then publish what changed and paint. Herdr
    /// status is built on a local copy and published once at the end (and
    /// only if it differs), not field by field across awaits — every publish
    /// re-renders every view that observes the bridge.
    private func refresh() async {
        guard isRunning else { return }
        let generation = runGeneration

        let socket = HerdrClient.socketLocation()
        var status = herdr
        status.socketPath = socket.path
        status.socketSource = socket.source
        status.pollInterval = config.pollInterval
        // One timestamp for the attempt and, when it works, the refresh, so
        // a successful attempt never reads as a separate failed one.
        let started = Date()
        lastRefreshStart = started
        status.lastAttemptAt = started

        // Herdr being down is not a reason to leave the pad stale: the agent
        // keys clear, and everything that does not depend on Herdr — action
        // keys, saved key looks, custom zones — still paints.
        var fetched: [HerdrAgent] = []
        let result: Result<[HerdrAgent], Error>
        do {
            result = .success(try await HerdrClient.listAgents())
        } catch {
            result = .failure(error)
        }
        // stop() (or a stop/start) ran while that was in flight: its fresh
        // status wins over this stale result.
        guard isCurrent(generation) else { return }
        switch result {
        case .success(let agents):
            fetched = agents
            status.reachability = .connected
            status.lastRefreshAt = started
            await refreshHerdrMetadataIfNeeded(fetched, into: &status, generation: generation)
        case .failure(let error):
            status.reachability = HerdrStatus.reachability(for: error)
            status.version = nil
            status.protocolVersion = nil
            status.workspaces = []
            status.tabs = []
            herdrMetadataAt = nil
        }
        guard isCurrent(generation) else { return }
        // Fields the streams maintain on their own may have moved meanwhile.
        status.lifecycleSubscribed = herdr.lifecycleSubscribed
        status.statusStreamCount = herdr.statusStreamCount
        setIfChanged(\.herdr, status)
        setIfChanged(\.agents, fetched)
        reconcileStatusStreams(fetched)
        await paint(fetched)
    }

    /// Everything the pad shows for these agents and the current bindings
    /// and preferences. Pure, so it can be checked without a device.
    func renderedLighting(for agents: [HerdrAgent]) -> (state: String?, threads: [OAI.Thread], keys: OAI.Zone, ambient: OAI.Zone) {
        let state = StatusMapper.aggregate(agents, config)
        // An agent key bound to anything but Focus agent shows its action
        // instead of its agent.
        let overriddenAgentKeys = Set(Pad.agentKeyIDs.filter { keyBindings.action(for: $0) != .focusAgent })
        let agentThreads = StatusMapper.threads(for: agents, config)
            .filter { !overriddenAgentKeys.contains($0.id) }
        let lightState = ActionLightState(voiceActive: voiceActive)
        // Only keycaps have LEDs; the dial and joystick never take a thread.
        let actionThreads = Pad.configurableActionKeyIDs.compactMap { key in
            StatusMapper.actionThread(for: keyBindings.action(for: key), key: key, state: lightState, config)
        }
        return (state,
                agentThreads + actionThreads,
                StatusMapper.backlightZone(for: state, config),
                StatusMapper.ambientZone(for: state, config))
    }

    private func paint(_ fetched: [HerdrAgent]) async {
        let picture = renderedLighting(for: fetched)

        // Fingerprint the whole rendered picture, not just the aggregate, so
        // one agent changing still repaints when the worst state has not —
        // and a speed or zone edit repaints too.
        let fingerprint = Self.fingerprint(picture.threads, keys: picture.keys, ambient: picture.ambient)
            + "|agg:\(picture.state ?? "-")"

        publishKeyState(picture.threads)
        setIfChanged(\.underglowZone, picture.ambient)
        setIfChanged(\.backlightZone, picture.keys)
        setIfChanged(\.aggregateState, picture.state)

        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(threads: picture.threads, keys: picture.keys, ambient: picture.ambient)
    }

    static func fingerprint(_ threads: [OAI.Thread], keys: OAI.Zone, ambient: OAI.Zone) -> String {
        func zone(_ zone: OAI.Zone) -> String {
            "\(zone.effect.rawValue):\(zone.brightness):\(zone.speed):\(zone.magic):\(zone.color)"
        }
        return threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1):\(thread.speed ?? -1)"
        }.joined(separator: "|") + "|keys:\(zone(keys))|ambient:\(zone(ambient))"
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        var brightness: [Int: Double] = [:]
        var all: [Int: OAI.Thread] = [:]
        for thread in threads {
            all[thread.id] = thread
            guard let packed = thread.color, let level = thread.brightness, level > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
            brightness[thread.id] = level
        }
        setIfChanged(\.keyColors, colors)
        setIfChanged(\.keyEffects, effects)
        setIfChanged(\.keyBrightness, brightness)
        setIfChanged(\.keyThreads, all)
    }

    private func apply(threads: [OAI.Thread], keys: OAI.Zone, ambient: OAI.Zone) async {
        guard deviceConnected else { return }
        // Never interleave lighting with a keymap read/write: hold it, and
        // let the pass after the keymap settles paint.
        guard !keymapBusy else {
            lastFingerprint = nil
            return
        }
        do {
            _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
            _ = try await device.callAsync(
                OAI.methodRGBConfig,
                params: OAI.rgbConfigParams(keys: keys, ambient: ambient)
            )
        } catch {
            deviceError = error.localizedDescription
            lastFingerprint = nil   // repaint on the next tick
        }
    }

    /// Thread state paints over zone state, so clearing the zones alone leaves
    /// the pad lit. Both have to go.
    private func allLightsOff() async {
        let threads = (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
        _ = try? await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        _ = try? await device.callAsync(
            OAI.methodRGBConfig,
            params: OAI.rgbConfigParams(keys: .dark, ambient: .dark)
        )
    }

    // MARK: - Input dispatch

    /// Every input arrives here — pad, emulator and on-screen mirrors alike —
    /// and runs whatever it is bound to.
    public func handleKeyPress(_ index: Int) {
        perform(keyBindings.action(for: index), from: index)
    }

    /// Fires an input as if it were pressed. Same as `handleKeyPress`.
    public func fire(_ input: Int) { handleKeyPress(input) }

    /// Runs an action, saved or not — the one executor every input goes
    /// through, and what an editor's "Test" button calls. `input` is the
    /// input it came from, which Focus agent needs to pick a slot.
    public func perform(_ action: InputAction, from input: Int? = nil) {
        lastActionError = nil
        lastAction = ActionEvent(input: input, action: action, date: Date())

        switch action {
        case .none:
            return
        // The app owns these.
        case .voice: onVoiceKey?(); return
        case .effortUp: onTune?(.effortUp); return
        case .effortDown: onTune?(.effortDown); return
        case .modelNext: onTune?(.modelNext); return
        case .modelPrevious: onTune?(.modelPrevious); return
        case .modelPickerConfirm: onTune?(.pickerConfirm); return
        case .modelPickerCancel: onTune?(.pickerCancel); return
        default:
            break
        }

        if let actionSink {
            actionSink(action, input)
            return
        }

        switch action {
        case .focusAgent:
            if let input, let slot = Pad.agentSlot(for: input) {
                Task { await focusSlot(slot) }
            } else {
                Task { await focusCurrentAgent() }
            }
        case .focusSlot(let slot):
            Task { await focusSlot(slot - 1) }
        case .nextTab:
            runHerdr { try await HerdrClient.cycleTabs(by: 1) }
        case .previousTab:
            runHerdr { try await HerdrClient.cycleTabs(by: -1) }
        case .nextWorkspace:
            runHerdr { try await HerdrClient.cycleWorkspaces(by: 1) }
        case .previousWorkspace:
            runHerdr { try await HerdrClient.cycleWorkspaces(by: -1) }
        case .focusPane(let direction):
            runHerdr { try await HerdrClient.focusPane(direction: direction.rawValue) }
        case .zoomPane:
            runHerdr { try await HerdrClient.zoomPane() }
        case .sendKeysToAgent(let keys):
            let list = HerdrClient.keyList(keys)
            guard !list.isEmpty else { return noteActionError("No keys are set for this input.") }
            Task { await withFocusedPane { pane in try await HerdrClient.sendKeys(paneID: pane, keys: list) } }
        case .herdrCommand(let line):
            Task { await runHerdrCommand(line) }
        case .insertText(let text):
            guard !text.isEmpty else { return }
            Task { await injectPrompt(text) }
        case .submitPrompt(let text):
            guard !text.isEmpty else { return noteActionError("No prompt text is set for this input.") }
            Task { await submitPrompt(text) }
        case .scroll(let direction, let amount):
            runSystem { try SystemActions.scroll(direction, lines: amount) }
        case .keyboardShortcut(let shortcut):
            runSystem { try SystemActions.keyboardShortcut(shortcut) }
        case .mediaKey(let key):
            runSystem { try SystemActions.mediaKey(key) }
        case .typeText(let text):
            runSystem { try SystemActions.typeText(text) }
        case .openURL(let target):
            runSystem { try SystemActions.open(target) }
        case .shellCommand(let command):
            Task {
                do { try await SystemActions.runShell(command) }
                catch { self.noteActionError(error.localizedDescription) }
            }
        case .none, .voice, .effortUp, .effortDown, .modelNext,
             .modelPrevious, .modelPickerConfirm, .modelPickerCancel:
            break
        }
    }

    /// Runs a Herdr CLI command line (`tab rename {tab} {ask:New tab name}`):
    /// placeholders are filled from Herdr's focus *now*, asks go through
    /// `onAsk`, and the `herdr` binary runs with the arguments directly,
    /// pointed at the bridge's socket. A cancelled ask does nothing; any
    /// failure — a legacy keybinding value, nothing focused, Herdr's own
    /// error — lands in `lastActionError`.
    public func runHerdrCommand(_ line: String) async {
        do {
            let context = herdrContextProvider ?? { needs in try await HerdrClient.commandContext(needs: needs) }
            guard let arguments = try await HerdrCommand.prepare(line, context: context, ask: onAsk) else {
                return
            }
            if let herdrCommandRunner {
                try await herdrCommandRunner(arguments)
            } else {
                try await HerdrCLI.run(arguments, socketPath: HerdrClient.socketPath())
            }
            // Renames and new tabs change what the Herdr page lists.
            if isRunning {
                herdrMetadataAt = nil
                schedule()
            }
        } catch {
            noteActionError(error.localizedDescription)
        }
    }

    private func runHerdr(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() }
            catch { noteActionError(error.localizedDescription) }
        }
    }

    private func runSystem(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            noteActionError(error.localizedDescription)
        }
        refreshAccessibilityStatus()
    }

    private func withFocusedPane(_ body: (String) async throws -> Void) async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(), let pane = agent.paneID else {
                noteActionError("Nothing has focus in Herdr right now.")
                return
            }
            try await body(pane)
        } catch {
            noteActionError(error.localizedDescription)
        }
    }

    private func noteActionError(_ message: String) {
        lastActionError = message
    }

    /// Types text into the focused agent's prompt, unsubmitted — the human
    /// still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        await withFocusedPane { pane in try await HerdrClient.sendText(paneID: pane, text: text) }
    }

    /// Submits text to the focused agent as one paste-and-Enter. Herdr
    /// refuses a blocked agent, which is reported rather than retried.
    public func submitPrompt(_ text: String) async {
        await withFocusedPane { pane in try await HerdrClient.promptAgent(target: pane, text: text) }
    }

    /// Repaints the voice key. Called by the app when a take starts or
    /// ends, so the key reflects what is actually happening.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await forceRepaint()
    }

    /// Lets app-layer features that fail outside the bridge (voice, tune)
    /// surface their error as the last action error.
    public func noteError(_ message: String) {
        lastActionError = message
    }

    /// Clears the last action error, e.g. when the user dismisses it.
    public func clearActionError() {
        lastActionError = nil
    }

    /// Advances the focused workspace to its next tab, wrapping.
    public func cycleTabs() async {
        do {
            try await HerdrClient.cycleTabs()
        } catch {
            noteActionError(error.localizedDescription)
        }
    }

    /// Slot N (0-based) is the Nth key in reading order (`Pad.agentKeyIDs[N]`)
    /// — the same mapping the lighting uses, which is what makes the key you
    /// look at the key you press.
    ///
    /// Herdr selects the pane but leaves the terminal wherever it was in the
    /// window order, so an agent key pressed from a browser used to move a
    /// cursor you could not see. The terminal comes forward with it.
    public func focusSlot(_ index: Int) async {
        guard index >= 0, index < agents.count else { return }
        guard let target = agents[index].focusTarget else { return }
        await focus(target)
    }

    /// Focuses one agent by pane id (or terminal id), as a Herdr page row does.
    public func focusAgent(_ agent: HerdrAgent) async {
        guard let target = agent.focusTarget else { return }
        await focus(target)
    }

    private func focus(_ target: String) async {
        do {
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
        } catch {
            noteActionError(error.localizedDescription)
        }
    }

    /// Returns focus to the agent Herdr currently marks as focused. Used by a
    /// Focus agent action on an input that has no dedicated agent slot.
    public func focusCurrentAgent() async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let target = agent.focusTarget
            else {
                noteActionError("Nothing is focused in Herdr right now.")
                return
            }
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
        } catch {
            noteActionError(error.localizedDescription)
        }
    }

    /// The app Herdr's panes live in. Override with `WL_TERMINAL_BUNDLE_ID` if
    /// they live somewhere other than Ghostty.
    public static let defaultTerminalBundleID = "com.mitchellh.ghostty"

    /// Brings the terminal forward unless it is already the active app.
    ///
    /// Nothing is ever launched: the agent whose key was pressed is running in
    /// a pane of a terminal that is by definition already up, so a terminal
    /// that is not running means the bundle id is wrong, and opening a fresh
    /// window would not be what the key meant. macOS may refuse a background
    /// app's `activate` outright, which is what the second attempt is for —
    /// `openApplication` on an already-running app raises it the way `open -a`
    /// does.
    private func raiseTerminal() {
        let identifier = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerminalBundleID
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier).first
        else { return }
        guard !app.isActive else { return }
        if app.activate(options: []) { return }
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// The model and effort actions, handed to the app through
/// `BridgeController.onTune`.
public enum TuneCommand: String, CaseIterable, Sendable {
    case effortUp
    case effortDown
    case modelNext
    case modelPrevious
    case pickerConfirm
    case pickerCancel
}

/// One dispatched action, for feedback.
public struct ActionEvent: Equatable, Sendable {
    /// The input it came from; nil for a direct `perform`.
    public var input: Int?
    public var action: InputAction
    public var date: Date
}
