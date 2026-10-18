import XCTest
@testable import CreatorMicroStudioKit

final class LightingPreferencesTests: XCTestCase {

    private func parse(_ json: String) -> LightingPreferences {
        LightingPreferences.parse(Data(json.utf8))
    }

    private func temporaryStore() -> StudioConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-lighting-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return StudioConfigStore(path: directory.appendingPathComponent("config.json").path)
    }

    // MARK: - Parsing

    func testNoLightingMeansTheBuiltInLook() {
        let prefs = parse(#"{"actions": {}}"#)
        XCTAssertEqual(prefs, LightingPreferences())
        XCTAssertEqual(prefs.underglow.mode, .status)
        XCTAssertEqual(prefs.backlight.mode, .off)
        XCTAssertTrue(prefs.keys.isEmpty)
        // The defaults must match the bridge's pinned status colours.
        let cfg = BridgeConfig(lighting: prefs)
        XCTAssertEqual(cfg.color(for: "blocked"), 0xFF2D2D)
        XCTAssertEqual(cfg.effect(for: "blocked"), .breath)
        XCTAssertEqual(cfg.color(for: "working"), 0xFFA000)
        XCTAssertEqual(cfg.color(for: "done"), 0x00B0FF)
        XCTAssertEqual(cfg.color(for: "idle"), 0x00C853)
        XCTAssertEqual(cfg.color(for: "unknown"), 0x00C853)
    }

    func testMalformedInputFallsBackFieldByField() {
        XCTAssertEqual(parse("not json"), LightingPreferences())
        XCTAssertEqual(parse(#"{"lighting": "bright"}"#), LightingPreferences())
        let prefs = parse(##"{"lighting": {"brightness": "loud", "speed": 3, "underglow": {"mode": "disco", "c": "#12"}, "status": {"blocked": {"c": "nope", "e": "sparkle"}}}}"##)
        XCTAssertEqual(prefs.brightness, 1, "unparseable keeps the default")
        XCTAssertEqual(prefs.speed, 1, "out of range is clamped")
        XCTAssertEqual(prefs.underglow, LightingPreferences.defaultUnderglow)
        XCTAssertEqual(prefs.status["blocked"], LightingPreferences.defaultStatus["blocked"])
    }

    func testTheSpecExampleParses() {
        let prefs = parse(#"""
        {"lighting": {
          "brightness": 0.8,
          "status": {"blocked": {"c":"#FF0000","e":"breath"}, "working": {"c": "#FFAA00", "e": 1, "b": 0.5}},
          "underglow": {"mode": "custom", "c":"#00C853", "e":"rainbow", "b":1, "s":0.5},
          "backlight": {"mode": "custom", "c":"#FFA000", "e":"solid", "b":0.3, "s":0.5},
          "keys": {"7": {"c":"#FFA000","e":"solid","b":0.6,"s":0.5}, "13": {"c": "#FFFFFF"}, "8": {"e": "solid"}}
        }}
        """#)
        XCTAssertEqual(prefs.brightness, 0.8)
        XCTAssertEqual(prefs.status["blocked"]?.color, 0xFF0000)
        XCTAssertEqual(prefs.status["working"], .init(color: 0xFFAA00, effect: .solid, brightness: 0.5))
        XCTAssertEqual(prefs.status["done"], LightingPreferences.defaultStatus["done"], "untouched states keep defaults")
        XCTAssertEqual(prefs.underglow.mode, .custom)
        XCTAssertEqual(prefs.underglow.look.effect, .rainbow)
        XCTAssertEqual(prefs.backlight.mode, .custom)
        XCTAssertEqual(prefs.backlight.look.brightness, 0.3)
        XCTAssertEqual(prefs.keys[7], .init(color: 0xFFA000, effect: .solid, brightness: 0.6, speed: 0.5))
        XCTAssertNil(prefs.keys[13], "inputs without LEDs take no look")
        XCTAssertNil(prefs.keys[8], "a look needs a colour")
    }

    func testEffectsAcceptNamesAndInts() {
        XCTAssertEqual(OAI.Effect(configValue: "breath"), .breath)
        XCTAssertEqual(OAI.Effect(configValue: "Breathing"), .breath)
        XCTAssertEqual(OAI.Effect(configValue: "shallow-breath"), .shallowBreath)
        XCTAssertEqual(OAI.Effect(configValue: "shallow_breath"), .shallowBreath)
        XCTAssertEqual(OAI.Effect(configValue: 3), .rainbow)
        XCTAssertEqual(OAI.Effect(configValue: "5"), .gradient)
        XCTAssertNil(OAI.Effect(configValue: "sparkle"))
        XCTAssertNil(OAI.Effect(configValue: 42))
        for effect in OAI.Effect.allCases {
            XCTAssertEqual(OAI.Effect(configValue: effect.configName), effect)
        }
    }

    func testJSONRoundTrip() throws {
        var prefs = LightingPreferences(brightness: 0.7, speed: 0.4)
        prefs.status["blocked"] = .init(color: 0x123456, effect: .gradient, brightness: 0.9, speed: 0.2)
        // Zone looks missing b/s inherit the zone defaults on read, so spell
        // them out for an exact round trip.
        prefs.underglow = .init(mode: .off, look: .init(color: 0xABCDEF, effect: .snake, brightness: 0.8, speed: 0.1))
        prefs.backlight = .init(mode: .custom, look: .init(color: 0x00FF00, effect: .solid, brightness: 0.2, speed: 0.6))
        prefs.keys = [3: .init(color: 0xFF00FF, effect: .breath, brightness: 0.5)]

        let data = try JSONSerialization.data(withJSONObject: ["lighting": prefs.jsonObject])
        XCTAssertEqual(LightingPreferences.parse(data), prefs)

        let coded = try JSONDecoder().decode(LightingPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(coded, prefs)
    }

    // MARK: - Storage

    func testSavePreservesTheRestOfTheFile() throws {
        let store = temporaryStore()
        try KeyBindings.setAction(.zoomPane, for: 6, store: store)
        try store.update { $0["future"] = ["x": 1] }

        var prefs = LightingPreferences()
        prefs.underglow.mode = .custom
        try LightingPreferences.save(prefs, to: store)

        XCTAssertEqual(LightingPreferences.load(from: store), prefs)
        XCTAssertEqual(KeyBindings.load(from: store).action(for: 6), .zoomPane)
        XCTAssertNotNil(try store.readObject()["future"])
    }

    /// The Studio editor's save merges against disk: keys another writer
    /// (the standalone Inspector) added after the draft was loaded survive,
    /// and only what the draft changed is written.
    func testMergedSavePreservesConcurrentKeyAdds() throws {
        let store = temporaryStore()
        try LightingPreferences.update(in: store) { $0.keys[1] = .init(color: 0x111111) }
        let baseline = LightingPreferences.load(from: store)

        // Meanwhile, another process saves keys 7 and 8 and a custom underglow.
        try LightingPreferences.update(in: store) {
            $0.keys[7] = .init(color: 0x070707)
            $0.keys[8] = .init(color: 0x080808)
            $0.underglow = .init(mode: .custom, look: .init(color: 0xABCDEF))
        }

        // The editor changes brightness, removes key 1 and adds key 3.
        var draft = baseline
        draft.brightness = 0.25
        draft.keys[1] = nil
        draft.keys[3] = .init(color: 0x333333)
        draft.status["done"] = .init(color: 0x0000FF)
        let written = try LightingPreferences.save(draft, baseline: baseline, to: store)

        let loaded = LightingPreferences.load(from: store)
        XCTAssertEqual(loaded, written)
        XCTAssertEqual(loaded.brightness, 0.25)
        XCTAssertNil(loaded.keys[1])
        XCTAssertEqual(loaded.keys[3]?.color, 0x333333)
        XCTAssertEqual(loaded.keys[7]?.color, 0x070707)
        XCTAssertEqual(loaded.keys[8]?.color, 0x080808)
        XCTAssertEqual(loaded.underglow.mode, .custom)
        XCTAssertEqual(loaded.underglow.look.color, 0xABCDEF)
        XCTAssertEqual(loaded.status["done"]?.color, 0x0000FF)
        XCTAssertEqual(loaded.status["idle"], LightingPreferences.defaultStatus["idle"])
    }

    func testRebaseAppliesOnlyChangedFields() {
        let baseline = LightingPreferences()
        var disk = baseline
        disk.speed = 0.9
        disk.backlight.mode = .custom
        var draft = baseline
        draft.backlight.look.color = 0x123456
        let out = draft.rebased(onto: disk, from: baseline)
        XCTAssertEqual(out.speed, 0.9)
        XCTAssertEqual(out.backlight.mode, .custom)
        XCTAssertEqual(out.backlight.look.color, 0x123456)
        XCTAssertEqual(baseline.rebased(onto: disk, from: baseline), disk)
    }

    /// A state that falls back to idle always builds on the merged idle,
    /// whatever order the dictionary happens to iterate in.
    func testUnknownStatusBuildsOnTheCustomisedIdle() {
        for _ in 0..<20 {
            let prefs = parse(##"{"lighting": {"status": {"idle": {"c": "#0000FF"}, "unknown": {"e": "breath"}, "zzz": {"e": "snake"}}}}"##)
            XCTAssertEqual(prefs.status["unknown"], .init(color: 0x0000FF, effect: .breath))
            XCTAssertEqual(prefs.status["zzz"], .init(color: 0x0000FF, effect: .snake))
        }
    }

    func testUpdateEditsWhatIsOnDisk() throws {
        let store = temporaryStore()
        try LightingPreferences.update(in: store) { $0.keys[2] = .init(color: 0xFF0000) }
        try LightingPreferences.update(in: store) { $0.keys[4] = .init(color: 0x00FF00) }
        let loaded = LightingPreferences.load(from: store)
        XCTAssertEqual(loaded.keys[2]?.color, 0xFF0000)
        XCTAssertEqual(loaded.keys[4]?.color, 0x00FF00)

        try LightingPreferences.reset(in: store)
        XCTAssertEqual(LightingPreferences.load(from: store), LightingPreferences())
        XCTAssertNil(try store.readObject()["lighting"])
    }

    // MARK: - Merging into the bridge

    func testPreferencesMergeIntoBridgeConfig() {
        var prefs = LightingPreferences(brightness: 0.5, speed: 0.25)
        prefs.status["working"] = .init(color: 0x112233, effect: .snake, brightness: 0.5, speed: 0.9)
        prefs.status["idle"] = .init(color: 0x445566, effect: .solid)
        let cfg = BridgeConfig(lighting: prefs)

        XCTAssertEqual(cfg.brightness, 0.5)
        XCTAssertEqual(cfg.speed, 0.25)
        XCTAssertEqual(cfg.color(for: "working"), 0x112233)
        XCTAssertEqual(cfg.effect(for: "working"), .snake)
        XCTAssertEqual(cfg.brightness(for: "working"), 0.25, "global times the state's own")
        XCTAssertEqual(cfg.speed(for: "working"), 0.9)
        XCTAssertEqual(cfg.color(for: "unknown"), 0x445566, "unknown follows idle")

        let thread = StatusMapper.threads(for: [HerdrAgent(status: "working")], cfg)[0]
        XCTAssertEqual(thread.color, 0x112233)
        XCTAssertEqual(thread.brightness, 0.25)
        XCTAssertEqual(thread.speed, 0.9)
    }

    func testUnderglowModes() {
        var prefs = LightingPreferences()
        let cfgStatus = BridgeConfig(lighting: prefs)
        XCTAssertEqual(StatusMapper.ambientZone(for: "blocked", cfgStatus).color, 0xFF2D2D)
        XCTAssertEqual(StatusMapper.ambientZone(for: nil, cfgStatus), .dark, "no agents, no status glow")

        prefs.underglow = .init(mode: .custom, look: .init(color: 0x00C853, effect: .rainbow, brightness: 0.5, speed: 0.7))
        prefs.brightness = 0.5
        let custom = StatusMapper.ambientZone(for: nil, BridgeConfig(lighting: prefs))
        XCTAssertEqual(custom.color, 0x00C853, "custom paints even with Herdr down")
        XCTAssertEqual(custom.effect, .rainbow)
        XCTAssertEqual(custom.brightness, 0.25)
        XCTAssertEqual(custom.speed, 0.7)

        prefs.underglow.mode = .off
        XCTAssertEqual(StatusMapper.ambientZone(for: "blocked", BridgeConfig(lighting: prefs)), .dark)
    }

    func testBacklightModes() {
        var prefs = LightingPreferences()
        XCTAssertEqual(StatusMapper.backlightZone(for: "working", BridgeConfig(lighting: prefs)), .dark)
        var driving = BridgeConfig(lighting: prefs)
        driving.driveBacklight = true
        XCTAssertEqual(StatusMapper.backlightZone(for: "working", driving).color, 0xFFA000)

        prefs.backlight.mode = .custom
        let zone = StatusMapper.backlightZone(for: nil, BridgeConfig(lighting: prefs))
        XCTAssertEqual(zone.color, 0xFFA000)
        XCTAssertEqual(zone.brightness, 0.3)
    }

    func testEmptyAgentSlotUsesItsSavedLook() {
        var prefs = LightingPreferences()
        prefs.keys[0] = .init(color: 0x202020, effect: .solid, brightness: 0.1)
        let threads = StatusMapper.threads(for: [HerdrAgent(status: "working")], BridgeConfig(lighting: prefs))
        // Slot 0 is key 1 (working); slot 1 is key 0, empty, so its look shows.
        XCTAssertEqual(threads[0].id, 1)
        XCTAssertEqual(threads[0].color, 0xFFA000)
        XCTAssertEqual(threads[1].id, 0)
        XCTAssertEqual(threads[1].color, 0x202020)
        XCTAssertEqual(threads[1].brightness, 0.1)
        XCTAssertEqual(threads[2].effect, .off, "keys without a look stay dark")
    }
}
