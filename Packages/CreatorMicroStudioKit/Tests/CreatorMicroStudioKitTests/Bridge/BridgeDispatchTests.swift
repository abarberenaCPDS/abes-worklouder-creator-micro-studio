import XCTest
@testable import CreatorMicroStudioKit

/// Dispatch and painting, checked on a bridge that is never started: no HID,
/// no Herdr, no synthesised events. Package-executed actions are routed to
/// `actionSink` instead of running.
@MainActor
final class BridgeDispatchTests: XCTestCase {

    private var sunk: [(InputAction, Int?)] = []
    private var tuned: [TuneCommand] = []
    private var app: [String] = []

    private func makeBridge(_ bindings: KeyBindings = KeyBindings(),
                            lighting: LightingPreferences? = nil) throws -> BridgeController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-bridge-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = StudioConfigStore(path: directory.appendingPathComponent("config.json").path)
        if let lighting { try LightingPreferences.save(lighting, to: store) }

        let bridge = BridgeController(store: store)
        bridge.useBindings(bindings)
        bridge.actionSink = { [weak self] action, input in self?.sunk.append((action, input)) }
        bridge.onTune = { [weak self] command in self?.tuned.append(command) }
        bridge.onVoiceKey = { [weak self] in self?.app.append("voice") }
        return bridge
    }

    // MARK: - Routing

    func testDefaultDialAndJoystickRouteToTune() throws {
        let bridge = try makeBridge()
        for input in [13, 14, 15, 17, 18, 16] { bridge.handleKeyPress(input) }
        XCTAssertEqual(tuned, [.effortUp, .effortDown, .modelPrevious, .modelNext, .pickerConfirm, .pickerCancel])
        XCTAssertTrue(sunk.isEmpty)
    }

    func testDialPushDefaultsToPlayPause() throws {
        let bridge = try makeBridge()
        bridge.handleKeyPress(Pad.dialPushID)
        XCTAssertEqual(sunk.map(\.0), [.mediaKey(.playPause)])
        XCTAssertEqual(sunk.first?.1, 19)
    }

    func testKeysAndControlsShareOneExecutor() throws {
        let bridge = try makeBridge(KeyBindings(actions: [
            3: .effortUp,
            Pad.dialUpID: .scroll(.down, amount: 2),
            Pad.joyNorthID: .modelNext,
            Pad.joyWestID: .voice,
            6: .submitPrompt("Run the test suite"),
            Pad.dialPushID: .none,
        ]))
        bridge.handleKeyPress(3)
        bridge.handleKeyPress(Pad.dialUpID)
        bridge.handleKeyPress(Pad.joyNorthID)
        bridge.handleKeyPress(Pad.joyWestID)
        bridge.handleKeyPress(6)
        bridge.handleKeyPress(Pad.dialPushID)
        bridge.handleKeyPress(0)

        XCTAssertEqual(tuned, [.effortUp, .modelNext], "keys and controls can run tune actions")
        XCTAssertEqual(app, ["voice"], "the joystick can reach app-owned actions")
        XCTAssertEqual(sunk.map(\.0), [.scroll(.down, amount: 2), .submitPrompt("Run the test suite"), .focusAgent])
        XCTAssertEqual(sunk.last?.1, 0, "focus agent knows which key it came from")
        XCTAssertEqual(bridge.lastAction?.action, .focusAgent)
    }

    func testDispatchUsesConfiguredAgentSlots() throws {
        let bridge = try makeBridge(KeyBindings(agentKeyIDs: [8, 0]))
        XCTAssertEqual(bridge.agentKeyIDs, [0, 8])
        XCTAssertEqual(bridge.agentSlot(for: 0), 0)
        XCTAssertEqual(bridge.agentSlot(for: 8), 1)
        XCTAssertNil(bridge.agentSlot(for: 1))
        bridge.handleKeyPress(8)
        XCTAssertEqual(sunk.last?.0, .focusAgent)
        XCTAssertEqual(sunk.last?.1, 8)
    }

    func testPerformRunsUnsavedActions() throws {
        let bridge = try makeBridge()
        bridge.perform(.modelPickerConfirm)
        bridge.perform(.openURL("https://example.com"))
        XCTAssertEqual(tuned, [.pickerConfirm])
        XCTAssertEqual(sunk.map(\.0), [.openURL("https://example.com")])
        XCTAssertNil(sunk.first?.1)
    }

    // MARK: - Errors

    func testActionErrorsAreSeparateFromDeviceErrors() throws {
        let bridge = try makeBridge()
        bridge.noteError("Voice failed")
        XCTAssertEqual(bridge.lastActionError, "Voice failed")
        XCTAssertNil(bridge.deviceError)
        XCTAssertEqual(bridge.lastError, "Voice failed")
        bridge.perform(.none)
        XCTAssertNil(bridge.lastActionError, "a new action clears the last failure")
    }

    // MARK: - Painting

    func testControlsNeverTakeALightingThread() throws {
        let bridge = try makeBridge(KeyBindings(actions: [
            Pad.dialUpID: .zoomPane, Pad.joyNorthID: .scroll(.up, amount: 1), Pad.dialPushID: .voice,
        ]))
        let picture = bridge.renderedLighting(for: [])
        XCTAssertTrue(picture.threads.allSatisfy { $0.id < Pad.keyCount })
        XCTAssertEqual(Set(picture.threads.map(\.id)), Set(0..<Pad.keyCount), "every key gets a value")
    }

    /// With Herdr down there are no agents, but non-agent keys, saved looks
    /// and custom zones still paint.
    func testPaintsPreferencesWithoutHerdr() throws {
        var prefs = LightingPreferences()
        prefs.underglow = .init(mode: .custom, look: .init(color: 0x112233, effect: .rainbow, brightness: 1, speed: 0.5))
        prefs.backlight = .init(mode: .custom, look: .init(color: 0x445566, effect: .solid, brightness: 0.4, speed: 0.5))
        prefs.keys[9] = .init(color: 0xABCDEF, effect: .breath, brightness: 0.6)
        let bridge = try makeBridge(KeyBindings(actions: [6: .zoomPane]), lighting: prefs)

        let picture = bridge.renderedLighting(for: [])
        XCTAssertNil(picture.state)
        XCTAssertEqual(picture.ambient.color, 0x112233)
        XCTAssertEqual(picture.keys.color, 0x445566)
        let threads = Dictionary(uniqueKeysWithValues: picture.threads.map { ($0.id, $0) })
        XCTAssertEqual(threads[9]?.color, 0xABCDEF, "a saved key look")
        XCTAssertEqual(threads[9]?.brightness, 0.6)
        XCTAssertEqual(threads[6]?.color, BridgeConfig().tabCycleColor, "action colours still paint")
        XCTAssertEqual(threads[1]?.effect, .off, "agent keys clear rather than go stale")
    }

    func testAgentKeysKeepAgentColoursOverASavedLook() throws {
        var prefs = LightingPreferences()
        prefs.keys[1] = .init(color: 0x010101)
        let bridge = try makeBridge(lighting: prefs)
        let picture = bridge.renderedLighting(for: [HerdrAgent(status: "blocked", paneID: "w1:p1")])
        let key1 = picture.threads.first { $0.id == 1 }
        XCTAssertEqual(key1?.color, 0xFF2D2D)
        XCTAssertEqual(picture.threads.filter { $0.id == 1 }.count, 1)
    }

    func testRemappedAgentKeyShowsItsAction() throws {
        let bridge = try makeBridge(KeyBindings(actions: [1: .shellCommand("make")]))
        let picture = bridge.renderedLighting(for: [HerdrAgent(status: "blocked", paneID: "w1:p1")])
        let key1 = picture.threads.filter { $0.id == 1 }
        XCTAssertEqual(key1.count, 1)
        XCTAssertEqual(key1.first?.color, BridgeConfig().launchColor)
    }

    func testConfiguredLayoutControlsStatusRenderingAndCustomActionsWin() throws {
        let bindings = KeyBindings(actions: [8: .shellCommand("make")], agentKeyIDs: [8, 0])
        let bridge = try makeBridge(bindings)
        let picture = bridge.renderedLighting(for: [
            HerdrAgent(status: "blocked", paneID: "w1:p1"),
            HerdrAgent(status: "working", paneID: "w1:p2"),
        ])
        let threads = Dictionary(uniqueKeysWithValues: picture.threads.map { ($0.id, $0) })
        XCTAssertEqual(threads[8]?.color, BridgeConfig().launchColor,
                       "a custom action suppresses status on a configured slot key")
        XCTAssertEqual(threads[0]?.color, 0xFF2D2D, "the first physical slot follows configured reading order")
        XCTAssertEqual(threads[1]?.color, BridgeConfig().focusAgentColor,
                       "unassigned Focus agent keys return to current-agent lighting")
    }

    func testBridgeAgentLayoutSetterPersistsAndReloads() throws {
        let bridge = try makeBridge()
        try bridge.setAgentKeys([7, 2])
        XCTAssertEqual(bridge.agentKeyIDs, [2, 7])
        XCTAssertEqual(bridge.agentSlot(for: 2), 0)
        XCTAssertEqual(bridge.action(for: 7), .focusAgent)
        XCTAssertEqual(KeyBindings.load(from: bridge.store).agentKeyIDs, [2, 7])
    }

    func testBridgeAgentLayoutSetterForwardsExpectedBindingsConflict() throws {
        let bridge = try makeBridge()
        let expected = KeyBindings.load(from: bridge.store)
        try KeyBindings.setAction(.zoomPane, for: 6, store: bridge.store)
        let before = try Data(contentsOf: URL(fileURLWithPath: bridge.store.path))

        XCTAssertThrowsError(try bridge.setAgentKeys([2, 7], expectedBindings: expected)) {
            XCTAssertEqual($0 as? KeyBindings.EditError, .configurationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: bridge.store.path)), before)
    }

    func testPreviewDoesNotSave() throws {
        let bridge = try makeBridge()
        var prefs = LightingPreferences()
        prefs.underglow.mode = .off
        bridge.previewLighting(prefs)
        XCTAssertTrue(bridge.isPreviewingLighting)
        XCTAssertEqual(bridge.lighting.underglow.mode, .off)
        XCTAssertEqual(LightingPreferences.load(from: bridge.store), LightingPreferences())

        bridge.reloadLighting()
        XCTAssertFalse(bridge.isPreviewingLighting)
        XCTAssertEqual(bridge.lighting, LightingPreferences())

        try bridge.saveLighting(prefs)
        XCTAssertEqual(LightingPreferences.load(from: bridge.store), prefs)
        try bridge.restoreDefaultLighting()
        XCTAssertEqual(bridge.lighting, LightingPreferences())
    }

    /// A preview never moves the saved baseline, and saving merges against
    /// disk, so a key the standalone Inspector saved meanwhile survives.
    func testSaveLightingMergesWithOutsideWrites() throws {
        let bridge = try makeBridge()
        var draft = bridge.savedLighting
        draft.brightness = 0.4
        bridge.previewLighting(draft)
        XCTAssertEqual(bridge.savedLighting, LightingPreferences())

        try LightingPreferences.update(in: bridge.store) { $0.keys[7] = .init(color: 0x777777) }
        try bridge.saveLighting(draft)

        XCTAssertEqual(bridge.savedLighting.brightness, 0.4)
        XCTAssertEqual(bridge.savedLighting.keys[7]?.color, 0x777777)
        XCTAssertEqual(LightingPreferences.load(from: bridge.store), bridge.savedLighting)
        XCTAssertFalse(bridge.isPreviewingLighting)
    }

    func testBridgeSettersSaveAndReload() throws {
        let bridge = try makeBridge()
        try bridge.setAction(.mediaKey(.mute), for: [Pad.dialPushID, 12])
        XCTAssertEqual(bridge.action(for: 12), .mediaKey(.mute))
        XCTAssertEqual(KeyBindings.load(from: bridge.store).action(for: 19), .mediaKey(.mute))
        try bridge.resetActions(for: [12])
        XCTAssertEqual(bridge.action(for: 12), .focusAgent)
        XCTAssertTrue(bridge.needsAccessibility)
    }

    func testFingerprintCoversSpeedAndZones() {
        let thread = OAI.Thread(id: 0, color: 1, brightness: 1, effect: .solid, speed: 0.5)
        var faster = thread
        faster.speed = 0.9
        let base = BridgeController.fingerprint([thread], keys: .dark, ambient: .dark)
        XCTAssertNotEqual(base, BridgeController.fingerprint([faster], keys: .dark, ambient: .dark))
        XCTAssertNotEqual(base, BridgeController.fingerprint([thread], keys: OAI.Zone(color: 5), ambient: .dark))
        XCTAssertNotEqual(base, BridgeController.fingerprint([thread], keys: .dark, ambient: OAI.Zone(speed: 0.1)))
    }

    // MARK: - Action key colours

    func testActionKeysTakeTheirCategoryColours() {
        let cfg = BridgeConfig()
        func color(_ action: InputAction) -> Int? { StatusMapper.actionThread(for: action, key: 9, cfg)?.color }
        XCTAssertEqual(color(.focusAgent), cfg.focusAgentColor)
        XCTAssertEqual(color(.focusSlot(3)), cfg.focusAgentColor)
        XCTAssertEqual(color(.nextTab), cfg.tabCycleColor)
        XCTAssertEqual(color(.zoomPane), cfg.tabCycleColor)
        XCTAssertEqual(color(.insertText("x")), cfg.macroColor)
        XCTAssertEqual(color(.effortUp), cfg.tuneColor)
        XCTAssertEqual(color(.voice), cfg.voiceColor)
        XCTAssertEqual(color(.scroll(.up, amount: 1)), cfg.systemColor)
        XCTAssertEqual(color(.shellCommand("ls")), cfg.launchColor)
        XCTAssertEqual(StatusMapper.actionThread(for: .none, key: 9, cfg)?.effect, .off)
        XCTAssertEqual(StatusMapper.actionThread(for: .insertText(""), key: 9, cfg)?.effect, .off)
        XCTAssertNil(StatusMapper.actionThread(for: .focusAgent, key: 0, cfg), "agent keys show agents")
        XCTAssertNil(StatusMapper.actionThread(for: .focusAgent, key: 8, cfg, agentKeyIDs: [8]),
                     "configured keys show status when Focus agent is bound")
        XCTAssertEqual(StatusMapper.actionThread(for: .focusAgent, key: 8, cfg, agentKeyIDs: [])?.color,
                       cfg.focusAgentColor, "an unassigned key focuses Herdr's current agent")
        XCTAssertNil(StatusMapper.actionThread(for: .zoomPane, key: 13, cfg), "the dial has no LED")
    }

    func testActiveStatesBeatASavedLook() {
        var prefs = LightingPreferences()
        prefs.keys[6] = .init(color: 0x010101)
        let cfg = BridgeConfig(lighting: prefs)
        XCTAssertEqual(StatusMapper.actionThread(for: .voice, key: 6, cfg)?.color, 0x010101)
        let recording = StatusMapper.actionThread(for: .voice, key: 6, state: .init(voiceActive: true), cfg)
        XCTAssertEqual(recording?.color, cfg.voiceActiveColor)
        XCTAssertEqual(recording?.effect, .breath)
    }
}
