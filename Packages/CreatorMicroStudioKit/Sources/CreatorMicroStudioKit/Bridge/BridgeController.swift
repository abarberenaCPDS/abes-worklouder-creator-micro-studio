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
    @Published public private(set) var agents: [HerdrAgent] = []
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: String?
    @Published public private(set) var lastError: String?
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// Whether the GitButler stack is on screen. Only the key light cares —
    /// the panel itself lives in the app layer.
    @Published public private(set) var stackPanelOpen = false
    /// Same for the land window.
    @Published public private(set) var landPanelOpen = false
    /// Whether a Claude voice take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false

    public var config: BridgeConfig
    /// Text macros for the spare keys, reloaded on every bridge start so a
    /// config edit only needs an off/on toggle, not a relaunch.
    @Published public private(set) var keyBindings = KeyBindings.load()

    /// Called when the stack key is pressed. The bridge owns the key, the app
    /// owns the window, so this is where the two meet.
    public var onStackKey: (() -> Void)?
    /// Called when the land key is pressed; same split as `onStackKey`.
    public var onLandKey: (() -> Void)?
    /// Called when either half of the wide voice key is pressed.
    public var onVoiceKey: (() -> Void)?
    /// Called per dial detent: +1 clockwise, -1 counter-clockwise.
    public var onDial: ((Int) -> Void)?
    /// Called when the joystick enters a cardinal sector.
    public var onJoystick: ((Pad.JoystickDirection) -> Void)?
    /// Consulted before any key does its normal job. Returning true consumes
    /// the press — this is how a pending land confirmation turns every other
    /// key into "cancel" without those keys also doing their usual work.
    public var onKeyIntercept: ((Int) -> Bool)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    private var lifecycle: HerdrEventStream?
    private var statusStreams: [String: HerdrEventStream] = [:]
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var lastFingerprint: String?
    private var issuedIDs = Set<Int>()
    private var warnedPermission = false

    public init(config: BridgeConfig = BridgeConfig()) {
        self.config = config
        wire(device)
    }

    /// Stable, disconnected sample state for SwiftUI Canvas previews. It never
    /// opens HID, starts polling, or contacts Herdr.
    public static func previewFixture(permissionDenied: Bool = false) -> BridgeController {
        let bridge = BridgeController()
        bridge.permissionDenied = permissionDenied
        bridge.isRunning = !permissionDenied
        bridge.deviceConnected = !permissionDenied
        bridge.keymapReady = true
        bridge.deviceName = permissionDenied ? "—" : "Creator Micro 2 · Preview"
        bridge.firmware = permissionDenied ? "—" : "2.4.1"
        bridge.battery = permissionDenied ? nil : "82%"
        bridge.agents = [
            HerdrAgent(agent: "claude", status: "working", cwd: "/workspace/api", focused: true),
            HerdrAgent(agent: "codex", status: "idle", cwd: "/workspace/web"),
            HerdrAgent(agent: "claude", status: "blocked", cwd: "/workspace/worker"),
            HerdrAgent(agent: "codex", status: "done", cwd: "/workspace/docs"),
        ]
        bridge.keyBindings = KeyBindings(
            texts: [9: "Open pull requests", 10: "Summarize this workspace", 12: "Run the test suite"]
        )
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
        lastError = nil
        contendingClient = false
        keyBindings = KeyBindings.load()

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
        pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        lifecycle?.stop(); lifecycle = nil
        statusStreams.values.forEach { $0.stop() }
        statusStreams.removeAll()
        lastFingerprint = nil

        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there.
        if device.isConnected {
            await allLightsOff()
            device.disconnect(reason: nil)
        }
        deviceConnected = false
        keyColors = [:]
        keyEffects = [:]
        aggregateState = nil
        agents = []
    }

    /// Apply host-side action and macro edits immediately without a HID keymap write.
    public func reloadKeyBindings() {
        keyBindings = KeyBindings.load()
        lastFingerprint = nil
        if isRunning { Task { await refresh() } }
    }

    // MARK: - Device

    private func openDevice() async {
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission.
        WLDevice.requestInputMonitoringAccessIfNeeded()

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            deviceName = device.info?.product ?? "Work Louder device"
            lastError = nil
        } catch {
            deviceConnected = false
            let message = error.localizedDescription
            if message.contains("0xE00002C1") || message.contains("Input Monitoring") {
                permissionDenied = true
                if !warnedPermission { warnedPermission = true; lastError = message }
            } else {
                lastError = message
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
    private func ensureKeymap() async {
        do {
            if config.manageKeymap {
                _ = try await KeymapManager.apply(device)
                keymapReady = true
            } else {
                let cfg = try await KeymapManager.read(device)
                keymapReady = KeymapManager.isAgentKeymapApplied(cfg)
                if !keymapReady {
                    lastError = "The agent keys and the stack key are not bound to KV_OAI_AG00..AG06, so per-key colours will do nothing."
                }
            }
        } catch {
            keymapReady = false
            lastError = "Keymap: \(error.localizedDescription)"
        }
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
        stream.onEvent = { [weak self] _ in self?.schedule() }
        stream.onClosed = { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.lifecycle = nil
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
                self?.statusStreams.removeValue(forKey: paneID)
            }
            statusStreams[paneID] = stream.start()
        }
    }

    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.config.debounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.debounceTask = nil
            await self.refresh()
        }
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lastFingerprint = nil
        await refresh()
    }

    private func refresh() async {
        guard isRunning else { return }

        let fetched: [HerdrAgent]
        do {
            fetched = try await HerdrClient.listAgents()
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        agents = fetched
        reconcileStatusStreams(fetched)

        let state = StatusMapper.aggregate(fetched, config)
        let overriddenAgentKeys = Set(Pad.agentKeyIDs.filter { key in
            guard let action = keyBindings.actionOverride(for: key) else { return false }
            return action != .focusAgent
        })
        let agentThreads = StatusMapper.threads(for: fetched, config)
            .filter { !overriddenAgentKeys.contains($0.id) }
        let actionThreads = Pad.configurableActionKeyIDs.compactMap(actionThread(for:))
        let threads = agentThreads + actionThreads

        // Fingerprint the whole rendered picture, not just the aggregate, so
        // one agent changing still repaints when the worst state has not.
        let fingerprint = threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1)"
        }.joined(separator: "|") + "|agg:\(state ?? "-")"

        publishKeyState(threads)
        aggregateState = state

        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(state: state, threads: threads)
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        for thread in threads {
            guard let packed = thread.color, (thread.brightness ?? 0) > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
        }
        keyColors = colors
        keyEffects = effects
    }

    private func apply(state: String?, threads: [OAI.Thread]) async {
        guard deviceConnected else { return }
        do {
            _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
            let zone = StatusMapper.zone(for: state, config) ?? .dark
            _ = try await device.callAsync(
                OAI.methodRGBConfig,
                params: OAI.rgbConfigParams(
                    keys: config.driveBacklight ? zone : .dark,
                    ambient: zone
                )
            )
        } catch {
            lastError = error.localizedDescription
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

    // MARK: - Key presses

    /// Every bound key arrives here. Which key does what is the one place that
    /// has to agree with `Pad`, so keep the dispatch in a single switch.
    public func handleKeyPress(_ index: Int) {
        if onKeyIntercept?(index) == true { return }

        if index == Pad.dialUpID || index == Pad.dialDownID {
            onDial?(index == Pad.dialUpID ? 1 : -1)
            return
        }
        if let direction = Pad.JoystickDirection(keyID: index) {
            onJoystick?(direction)
            return
        }

        switch keyBindings.action(for: index) {
        case .defaultAction, .none:
            break
        case .focusAgent:
            if let slot = Pad.agentSlot(for: index) {
                Task { await focusSlot(slot) }
            } else {
                Task { await focusCurrentAgent() }
            }
        case .stack:
            onStackKey?()
        case .cycleTabs:
            Task { await cycleTabs() }
        case .land:
            onLandKey?()
        case .macro:
            if let text = keyBindings.text(for: index) {
                Task { await injectPrompt(text) }
            }
        case .voice:
            if let text = keyBindings.text(for: index) {
                Task { await injectPrompt(text) }
            } else {
                onVoiceKey?()
            }
        }
    }

    private func actionThread(for key: Int) -> OAI.Thread? {
        switch keyBindings.action(for: key) {
        case .defaultAction:
            return nil
        case .focusAgent:
            guard Pad.agentSlot(for: key) == nil else { return nil }
            return StatusMapper.focusAgentThread(id: key, config)
        case .none:
            return OAI.Thread(id: key, brightness: 0, effect: .off)
        case .stack:
            return StatusMapper.stackThread(open: stackPanelOpen, config, id: key)
        case .cycleTabs:
            return StatusMapper.tabCycleThread(config, id: key)
        case .land:
            return StatusMapper.landThread(open: landPanelOpen, config, id: key)
        case .macro:
            guard keyBindings.text(for: key) != nil else {
                return OAI.Thread(id: key, brightness: 0, effect: .off)
            }
            return StatusMapper.macroThread(id: key, config)
        case .voice:
            if keyBindings.text(for: key) != nil {
                return StatusMapper.macroThread(id: key, config)
            }
            return StatusMapper.voiceThread(id: key, active: voiceActive, config)
        }
    }

    /// Types a macro string into the focused agent's prompt, unsubmitted —
    /// the human still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let pane = agent.paneID
            else {
                lastError = "Nothing has focus in Herdr right now."
                return
            }
            try await HerdrClient.sendText(paneID: pane, text: text)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the voice key. Same contract as `setStackPanelOpen`.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await forceRepaint()
    }

    /// Lets app-layer features that fail outside the bridge surface their
    /// error where the menu already shows the bridge's own.
    public func noteError(_ message: String) {
        lastError = message
    }

    /// Advances the focused workspace to its next tab, wrapping.
    public func cycleTabs() async {
        do {
            try await HerdrClient.cycleTabs()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the stack key. Called by the app when the window opens or
    /// closes, so the key reflects what is actually on screen.
    public func setStackPanelOpen(_ open: Bool) async {
        guard stackPanelOpen != open else { return }
        stackPanelOpen = open
        await forceRepaint()
    }

    /// Repaints the land key. Same contract as `setStackPanelOpen`.
    public func setLandPanelOpen(_ open: Bool) async {
        guard landPanelOpen != open else { return }
        landPanelOpen = open
        await forceRepaint()
    }

    /// Slot N is the Nth key in reading order (`Pad.agentKeyIDs[N]`) — the
    /// same mapping the lighting uses, which is what makes the key you look at
    /// the key you press.
    ///
    /// Herdr selects the pane but leaves the terminal wherever it was in the
    /// window order, so an agent key pressed from a browser used to move a
    /// cursor you could not see. The terminal comes forward with it.
    public func focusSlot(_ index: Int) async {
        guard index >= 0, index < agents.count else { return }
        guard let target = agents[index].focusTarget else { return }
        do {
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns focus to the agent Herdr currently marks as focused. Used by a
    /// Focus Agent action on a physical key that has no dedicated agent slot.
    public func focusCurrentAgent() async {
        do {
            guard let agent = try await HerdrClient.focusedAgent(),
                  let target = agent.focusTarget
            else {
                lastError = "Nothing is focused in Herdr right now."
                return
            }
            try await HerdrClient.focusAgent(target)
            raiseTerminal()
        } catch {
            lastError = error.localizedDescription
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
