import XCTest
@testable import CreatorMicroStudioKit

final class KeyBindingsTests: XCTestCase {

    private func parse(_ json: String) -> KeyBindings {
        KeyBindings.parse(Data(json.utf8))
    }

    // MARK: - Defaults

    func testMissingFileMeansDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.agentKeyIDs, [1, 0, 2, 3, 4, 5])
        XCTAssertEqual(bindings.text(for: 9), "Open a pull request for this branch")
        XCTAssertEqual(bindings.text(for: 12), "Run the test suite")
        XCTAssertNil(bindings.text(for: 10))
        XCTAssertTrue(bindings.actions.isEmpty)
    }

    func testAgentKeyLayoutParsingAndValidation() {
        XCTAssertEqual(parse(#"{"agentKeys": [12, 1, 12, 0]}"#).agentKeyIDs, [1, 0, 12],
                       "duplicates collapse and physical reading order is canonical")
        XCTAssertEqual(parse(#"{"agentKeys": []}"#).agentKeyIDs, [], "empty is intentional")
        for invalid in [#"{"agentKeys": "1,2"}"#,
                        #"{"agentKeys": [1, 13]}"#,
                        #"{"agentKeys": [-1]}"#,
                        #"{"agentKeys": [1.5]}"#,
                        #"{"agentKeys": [true]}"#] {
            XCTAssertEqual(parse(invalid).agentKeyIDs, Pad.agentKeyIDs, invalid)
        }
    }

    func testLoadingLayoutDoesNotReplaceCustomActionsOnDefaultAgentKeys() {
        let bindings = parse(#"{"agentKeys": [1, 0], "actions": {"0": "zoom-pane", "1": "next-tab"}}"#)
        XCTAssertEqual(bindings.agentKeyIDs, [1, 0])
        XCTAssertEqual(bindings.action(for: 0), .zoomPane)
        XCTAssertEqual(bindings.action(for: 1), .nextTab)
        XCTAssertEqual(bindings.agentSlot(for: 1), 0)
        XCTAssertEqual(bindings.agentSlot(for: 0), 1)
        XCTAssertNil(bindings.agentSlot(for: 2))
    }

    func testAllThirteenKeysNormalizeToPhysicalReadingOrder() {
        let reversed = Array((0..<Pad.keyCount).reversed())
        let bindings = KeyBindings(agentKeyIDs: reversed)
        XCTAssertEqual(bindings.agentKeyIDs, Pad.displayRows.flatMap { $0 })
        XCTAssertEqual(bindings.agentKeyIDs.count, 13)
    }

    /// The fallback prompt strings stay limited to the keys that have stock
    /// prompt suggestions, independently of each key's default action.
    func testDefaultsSitOnTheMacroKeys() {
        XCTAssertEqual(KeyBindings.defaults.keys.sorted(), Pad.macroKeyIDs.sorted())
    }

    /// No config means today's behaviour: keys focus agents, the dial steps
    /// effort, the joystick works the model list and picker, and the dial
    /// push keeps the play/pause it sent before AG19 was bound.
    func testDefaultsForAllTwentyInputs() {
        let bindings = KeyBindings()
        XCTAssertEqual(Pad.configurableInputIDs, Array(0...19))
        for key in 0..<13 {
            XCTAssertEqual(bindings.action(for: key), .focusAgent, "key \(key)")
        }
        XCTAssertEqual(bindings.action(for: 13), .effortUp)
        XCTAssertEqual(bindings.action(for: 14), .effortDown)
        XCTAssertEqual(bindings.action(for: 15), .modelPrevious)
        XCTAssertEqual(bindings.action(for: 16), .modelPickerCancel)
        XCTAssertEqual(bindings.action(for: 17), .modelNext)
        XCTAssertEqual(bindings.action(for: 18), .modelPickerConfirm)
        XCTAssertEqual(bindings.action(for: 19), .mediaKey(.playPause))
        XCTAssertEqual(bindings.action(for: 20), .none, "outside the input space")
        for input in Pad.configurableInputIDs {
            XCTAssertFalse(bindings.isCustomised(input))
        }
    }

    // MARK: - Legacy forms

    func testLegacyStringKindsStillParse() {
        let bindings = parse(#"{"actions":{"0":"zoom-pane","6":"cycle-tabs","7":"next-workspace","8":"macro","9":"voice","10":"none","12":"focus-agent"}, "keys": {"8": "Ship it"}}"#)
        XCTAssertEqual(bindings.action(for: 0), .zoomPane)
        XCTAssertEqual(bindings.action(for: 6), .nextTab, "cycle-tabs is next tab")
        XCTAssertEqual(bindings.action(for: 7), .nextWorkspace)
        XCTAssertEqual(bindings.action(for: 8), .insertText("Ship it"), "macro inserts the key's text")
        XCTAssertEqual(bindings.action(for: 9), .insertText("Open a pull request for this branch"),
                       "voice with text inserts it, as before")
        XCTAssertEqual(bindings.action(for: 10), .none)
        XCTAssertEqual(bindings.action(for: 12), .focusAgent)
        XCTAssertEqual(bindings.action(for: 11), .focusAgent)
    }

    func testLegacyVoiceWithoutTextIsVoice() {
        XCTAssertEqual(parse(#"{"actions":{"10":"voice"}}"#).action(for: 10), .voice)
    }

    func testLegacyMacroWithoutTextInsertsNothing() {
        XCTAssertEqual(parse(#"{"actions":{"3":"macro"}}"#).action(for: 3), .insertText(""))
        XCTAssertEqual(parse(#"{"actions":{"12":"macro"}, "keys": {"12": ""}}"#).action(for: 12),
                       .insertText(""), "an empty string removes the suggested text")
    }

    func testFileOverridesAKeyTextAndKeepsTheOtherDefault() {
        let bindings = parse(#"{"keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 9), "Ship it")
        XCTAssertEqual(bindings.text(for: 12), "Run the test suite")
    }

    func testPairedVoiceKeysBindTogether() {
        let bindings = parse(#"{"keys": {"10+11": "Summarise"}, "actions": {"10": "macro", "11": "voice"}}"#)
        XCTAssertEqual(bindings.action(for: 10), .insertText("Summarise"))
        XCTAssertEqual(bindings.action(for: 11), .insertText("Summarise"))
    }

    /// Dictionary order used to decide which of "10+11" and "10" won. The
    /// specific id always wins now, however many times this runs.
    func testSpecificVoiceKeyBeatsThePairDeterministically() {
        for _ in 0..<50 {
            let bindings = parse(#"{"keys": {"10": "left", "10+11": "both"}, "actions": {"10+11": "macro", "11": "none"}}"#)
            XCTAssertEqual(bindings.text(for: 10), "left")
            XCTAssertEqual(bindings.text(for: 11), "both")
            XCTAssertEqual(bindings.action(for: 10), .insertText("left"))
            XCTAssertEqual(bindings.action(for: 11), .none)
        }
    }

    func testMalformedFileFallsBackToDefaults() {
        XCTAssertEqual(parse("not json"), KeyBindings())
        XCTAssertEqual(parse(#"{"keys": "nope"}"#), KeyBindings())
        XCTAssertEqual(parse(#"{"actions": ["nope"]}"#), KeyBindings())
    }

    /// Configs saved while the GitButler "stack" and "land" actions existed
    /// still load: those entries are no override, so each input falls back
    /// to its own default, and saving another input leaves the file usable.
    func testRemovedGitButlerActionsFallBackToDefaults() throws {
        let legacy = #"{"actions": {"6": "stack", "8": "land", "joy-up": {"type": "stack"}, "dial-push": "land", "9": "next-tab"}}"#
        let bindings = parse(legacy)
        XCTAssertEqual(bindings.action(for: 6), .focusAgent)
        XCTAssertEqual(bindings.action(for: 8), .focusAgent)
        XCTAssertEqual(bindings.action(for: Pad.joyNorthID), InputAction.defaultAction(for: Pad.joyNorthID))
        XCTAssertEqual(bindings.action(for: Pad.dialPushID), .mediaKey(.playPause))
        XCTAssertEqual(bindings.action(for: 9), .nextTab, "other overrides still apply")
        XCTAssertEqual(Set(bindings.actions.keys), [9], "retired entries are not overrides")

        let store = temporaryStore()
        try write(legacy, to: store)
        XCTAssertEqual(KeyBindings.load(from: store), bindings)
        try KeyBindings.setAction(.voice, for: 7, store: store)
        let loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 7), .voice)
        XCTAssertEqual(loaded.action(for: 6), .focusAgent)
    }

    func testInvalidActionOverridesAreIgnored() {
        let bindings = parse(#"{"actions":{"0":"next-workspace","6":"unknown","20":"zoom-pane","8":"default","9":{"type":"nope"},"x":"zoom-pane"}}"#)
        XCTAssertEqual(bindings.action(for: 0), .nextWorkspace)
        XCTAssertEqual(bindings.action(for: 6), .focusAgent)
        XCTAssertEqual(bindings.action(for: 8), .focusAgent, "default means no override")
        XCTAssertEqual(bindings.action(for: 9), .focusAgent)
        XCTAssertEqual(bindings.actions.count, 1)
    }

    // MARK: - New forms

    func testParameterisedObjectsParse() {
        let bindings = parse(#"""
        {"actions": {
          "0": "focus-agent",
          "13": "effort-up",
          "9": {"type": "submit-prompt", "text": "Run the test suite"},
          "19": {"type": "media-key", "key": "play-pause"},
          "15": {"type": "scroll", "direction": "up", "amount": 3},
          "dial-push": "none"
        }}
        """#)
        XCTAssertEqual(bindings.action(for: 9), .submitPrompt("Run the test suite"))
        XCTAssertEqual(bindings.action(for: 19), .mediaKey(.playPause), "the numeric id beats the alias")
        XCTAssertEqual(bindings.action(for: 15), .scroll(.up, amount: 3))
        XCTAssertEqual(bindings.action(for: 13), .effortUp)
    }

    func testDialAndJoystickTakeEveryAction() {
        for input in Pad.configurableInputIDs {
            for kind in InputAction.Kind.allCases {
                let action = kind.defaultAction
                let value = action.configValue
                let data = try! JSONSerialization.data(withJSONObject: ["actions": [String(input): value]])
                XCTAssertEqual(KeyBindings.parse(data).action(for: input), action,
                               "input \(input) accepts \(kind.title)")
            }
        }
    }

    func testAliasesNameTheControls() {
        let bindings = parse(#"{"actions": {"dial-right": "next-tab", "dial-left": "previous-tab", "dial-push": "voice", "joy-up": "zoom-pane", "joy-left": "next-workspace", "joy-down": "zoom-pane", "joy-right": "none"}}"#)
        XCTAssertEqual(bindings.action(for: Pad.dialUpID), .nextTab)
        XCTAssertEqual(bindings.action(for: Pad.dialDownID), .previousTab)
        XCTAssertEqual(bindings.action(for: Pad.dialPushID), .voice)
        XCTAssertEqual(bindings.action(for: Pad.joyNorthID), .zoomPane)
        XCTAssertEqual(bindings.action(for: Pad.joyWestID), .nextWorkspace)
        XCTAssertEqual(bindings.action(for: Pad.joySouthID), .zoomPane)
        XCTAssertEqual(bindings.action(for: Pad.joyEastID), .none)
    }

    func testAliasLookupCoversEveryControl() {
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "dial-right"), [13])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "DIAL-LEFT"), [14])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "dial-push"), [19])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "joy-up"), [15])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "joy-left"), [16])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "joy-down"), [17])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "joy-right"), [18])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "dial-cw"), [13])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "10+11"), [10, 11])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "7"), [7])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "20"), [])
        XCTAssertEqual(Pad.inputIDs(forConfigKey: "nope"), [])
    }

    func testInputCatalogueIsComplete() {
        XCTAssertEqual(Pad.inputs.map(\.id).sorted(), Pad.configurableInputIDs)
        XCTAssertEqual(Set(Pad.inputs.map(\.name)).count, 20, "names are unique")
        XCTAssertEqual(Pad.InputGroup.keys.inputs.count, 13)
        XCTAssertEqual(Pad.InputGroup.dial.inputs.map(\.id), [13, 14, 19])
        XCTAssertEqual(Pad.InputGroup.joystick.inputs.map(\.id), [15, 17, 16, 18])
        XCTAssertEqual(Pad.input(19)?.name, "Dial push")
        XCTAssertTrue(Pad.input(3)?.hasLight == true)
        XCTAssertFalse(Pad.input(13)?.hasLight == true)
        XCTAssertEqual(Pad.input(0)?.agentSlot, 1)
        XCTAssertEqual(Pad.input(Pad.joyEastID)?.joystickDirection, .east)
        for direction in Pad.JoystickDirection.allCases {
            XCTAssertEqual(Pad.JoystickDirection(keyID: direction.inputID), direction)
        }
    }

    func testClaudeAndCodexListsStillLoad() {
        let bindings = parse(#"{"claude": {"models": ["opus", "sonnet"], "efforts": ["low", "high"]}, "codex": {"models": ["gpt-5.6-sol"]}}"#)
        XCTAssertEqual(bindings.claudeModels, ["opus", "sonnet"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.codexModels, ["gpt-5.6-sol"])
        XCTAssertEqual(parse(#"{"claude": {"models": []}}"#).claudeModels, KeyBindings.defaultClaudeModels)
        XCTAssertEqual(KeyBindings().codexModels, [])
    }

    // MARK: - Writing

    private func temporaryStore() -> StudioConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wl-bindings-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return StudioConfigStore(path: directory.appendingPathComponent("config.json").path)
    }

    private func write(_ json: String, to store: StudioConfigStore) throws {
        let url = URL(fileURLWithPath: store.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func object(_ store: StudioConfigStore) throws -> [String: Any] {
        try store.readObject()
    }

    func testWritesUseStringFormsForPlainActionsAndObjectsForParameterisedOnes() throws {
        let store = temporaryStore()
        try KeyBindings.setAction(.zoomPane, for: 6, store: store)
        try KeyBindings.setAction(.scroll(.up, amount: 5), for: Pad.dialUpID, store: store)
        try KeyBindings.setAction(.submitPrompt("Run the test suite"), for: 9, store: store)

        let actions = try XCTUnwrap(object(store)["actions"] as? [String: Any])
        XCTAssertEqual(actions["6"] as? String, "zoom-pane")
        let scroll = try XCTUnwrap(actions["13"] as? [String: Any])
        XCTAssertEqual(scroll["type"] as? String, "scroll")
        XCTAssertEqual(scroll["direction"] as? String, "up")
        XCTAssertEqual(scroll["amount"] as? Int, 5)
        XCTAssertEqual((actions["9"] as? [String: Any])?["text"] as? String, "Run the test suite")

        let loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 6), .zoomPane)
        XCTAssertEqual(loaded.action(for: 13), .scroll(.up, amount: 5))
        XCTAssertEqual(loaded.action(for: 9), .submitPrompt("Run the test suite"))
    }

    func testRoundTripPreservesUnknownKeys() throws {
        let store = temporaryStore()
        try write(#"{"future": {"x": 1}, "claude": {"models": ["opus"]}, "lighting": {"brightness": 0.5}, "actions": {"5": "next-workspace"}}"#, to: store)
        try KeyBindings.setAction(.mediaKey(.mute), for: Pad.dialPushID, store: store)

        let json = try object(store)
        XCTAssertEqual((json["future"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertEqual((json["claude"] as? [String: Any])?["models"] as? [String], ["opus"])
        XCTAssertEqual((json["lighting"] as? [String: Any])?["brightness"] as? Double, 0.5)
        let loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 5), .nextWorkspace)
        XCTAssertEqual(loaded.action(for: 19), .mediaKey(.mute))
        XCTAssertEqual(loaded.claudeModels, ["opus"])
    }

    func testSetAgentKeysAtomicallySavesLayoutAndResetsOnlyNewKeys() throws {
        let store = temporaryStore()
        try write(#"{"agentKeys": [1, 0], "actions": {"1": "zoom-pane", "0": "next-tab", "6": "shell-command"}, "other": 42}"#, to: store)

        try KeyBindings.setAgentKeys([6, 0, 6, 12], store: store)

        let object = try object(store)
        XCTAssertEqual(object["agentKeys"] as? [Int], [0, 6, 12])
        XCTAssertEqual(object["other"] as? Int, 42)
        let actions = try XCTUnwrap(object["actions"] as? [String: Any])
        XCTAssertEqual(actions["6"] as? String, "focus-agent", "new slot replaces its previous action")
        XCTAssertEqual(actions["12"] as? String, "focus-agent")
        XCTAssertEqual(actions["1"] as? String, "zoom-pane", "removed keys keep their action")
        XCTAssertEqual(actions["0"] as? String, "next-tab", "existing layout keys keep their action")

        let loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.agentKeyIDs, [0, 6, 12])
        XCTAssertEqual(loaded.action(for: 6), .focusAgent)
        XCTAssertEqual(loaded.action(for: 1), .zoomPane)
        XCTAssertEqual(loaded.action(for: 0), .nextTab)
    }

    func testSetAgentKeysAllowsEmptyAndResettingToDefaultLayout() throws {
        let store = temporaryStore()
        try KeyBindings.setAgentKeys([], store: store)
        XCTAssertEqual(KeyBindings.load(from: store).agentKeyIDs, [])
        try KeyBindings.setAgentKeys(Pad.agentKeyIDs, store: store)
        XCTAssertEqual(KeyBindings.load(from: store).agentKeyIDs, Pad.agentKeyIDs)
    }

    func testSetAgentKeysRejectsNonKeycapsWithoutWriting() throws {
        let store = temporaryStore()
        try write(#"{"agentKeys": [1], "other": "untouched"}"#, to: store)
        XCTAssertThrowsError(try KeyBindings.setAgentKeys([1, 13], store: store))
        XCTAssertEqual(try object(store)["agentKeys"] as? [Int], [1])
        XCTAssertEqual(try object(store)["other"] as? String, "untouched")
    }

    func testSetAgentKeysLeavesMalformedConfigUntouchedOnSaveFailure() throws {
        let store = temporaryStore()
        try write("{ not json", to: store)
        XCTAssertThrowsError(try KeyBindings.setAgentKeys([2, 3], store: store))
        XCTAssertEqual(try String(contentsOfFile: store.path), "{ not json")
    }

    func testSetAgentKeysRejectsChangedLayoutWithoutChangingBytes() throws {
        let store = temporaryStore()
        try write(#"{"agentKeys": [1, 0], "actions": {"6": "shell-command"}}"#, to: store)
        let expected = KeyBindings.load(from: store)
        try store.update { $0["agentKeys"] = [1, 0, 2] }
        let before = try Data(contentsOf: URL(fileURLWithPath: store.path))

        XCTAssertThrowsError(try KeyBindings.setAgentKeys([3, 4], expectedBindings: expected, store: store)) {
            XCTAssertEqual($0 as? KeyBindings.EditError, .configurationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), before)
    }

    func testSetAgentKeysRejectsChangedKeycapActionWithoutChangingBytes() throws {
        let store = temporaryStore()
        try write(#"{"agentKeys": [1, 0], "actions": {"6": "zoom-pane"}}"#, to: store)
        let expected = KeyBindings.load(from: store)
        try store.update { json in
            var actions = json["actions"] as? [String: Any] ?? [:]
            actions["6"] = "shell-command"
            json["actions"] = actions
        }
        let before = try Data(contentsOf: URL(fileURLWithPath: store.path))

        XCTAssertThrowsError(try KeyBindings.setAgentKeys([3, 4], expectedBindings: expected, store: store)) {
            XCTAssertEqual($0 as? KeyBindings.EditError, .configurationChanged)
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), before)
    }

    func testSetAgentKeysExpectedBindingsIgnoresLightingAndNonKeyActions() throws {
        let store = temporaryStore()
        try write(#"{"agentKeys": [1, 0], "actions": {"6": "zoom-pane"}}"#, to: store)
        let expected = KeyBindings.load(from: store)
        try store.update { json in
            json["lighting"] = ["brightness": 0.5]
            var actions = json["actions"] as? [String: Any] ?? [:]
            actions["13"] = "effort-down"
            json["actions"] = actions
        }

        try KeyBindings.setAgentKeys([5, 2], expectedBindings: expected, store: store)
        let json = try object(store)
        XCTAssertEqual(json["agentKeys"] as? [Int], [2, 5])
        XCTAssertEqual((json["lighting"] as? [String: Any])?["brightness"] as? Double, 0.5)
        XCTAssertEqual(((json["actions"] as? [String: Any])?["13"] as? String), "effort-down")
    }

    func testResettingRemovesTheOverride() throws {
        let store = temporaryStore()
        try KeyBindings.setAction(.nextWorkspace, for: 3, store: store)
        try KeyBindings.setAction(nil, for: 3, store: store)
        XCTAssertNil(try object(store)["actions"], "an empty actions table is dropped")
        XCTAssertEqual(KeyBindings.load(from: store).action(for: 3), .focusAgent)

        // Saving the default is the same as resetting.
        try KeyBindings.setAction(.effortUp, for: Pad.dialUpID, store: store)
        XCTAssertNil(try object(store)["actions"])
    }

    func testBulkSetAndReset() throws {
        let store = temporaryStore()
        try KeyBindings.setAction(.mediaKey(.volumeUp), for: [6, 7, 13], store: store)
        var loaded = KeyBindings.load(from: store)
        for input in [6, 7, 13] { XCTAssertEqual(loaded.action(for: input), .mediaKey(.volumeUp)) }

        try KeyBindings.setActions([6: .zoomPane, 7: nil, 19: .voice], store: store)
        loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 6), .zoomPane)
        XCTAssertEqual(loaded.action(for: 7), .focusAgent)
        XCTAssertEqual(loaded.action(for: 19), .voice)

        try KeyBindings.resetActions(for: [6, 13], store: store)
        loaded = KeyBindings.load(from: store)
        XCTAssertEqual(loaded.action(for: 6), .focusAgent)
        XCTAssertEqual(loaded.action(for: 13), .effortUp)
        XCTAssertEqual(loaded.action(for: 19), .voice)

        try KeyBindings.resetAllActions(store: store)
        XCTAssertTrue(KeyBindings.load(from: store).actions.isEmpty)
    }

    func testEditingOneVoiceKeySplitsThePair() throws {
        let store = temporaryStore()
        try write(#"{"actions": {"10+11": "voice"}}"#, to: store)
        try KeyBindings.setAction(.zoomPane, for: 10, store: store)
        let actions = try XCTUnwrap(object(store)["actions"] as? [String: Any])
        XCTAssertNil(actions["10+11"])
        XCTAssertEqual(actions["10"] as? String, "zoom-pane")
        XCTAssertEqual(actions["11"] as? String, "voice")
    }

    func testWritingAnInputReplacesItsAlias() throws {
        let store = temporaryStore()
        try write(#"{"actions": {"dial-push": "voice", "joy-up": "zoom-pane"}}"#, to: store)
        try KeyBindings.setAction(.nextWorkspace, for: Pad.dialPushID, store: store)
        let actions = try XCTUnwrap(object(store)["actions"] as? [String: Any])
        XCTAssertNil(actions["dial-push"])
        XCTAssertEqual(actions["19"] as? String, "next-workspace", "ids are written numerically")
        XCTAssertEqual(actions["joy-up"] as? String, "zoom-pane", "other aliases stay")
    }

    func testUnknownInputsAreRefused() {
        let store = temporaryStore()
        XCTAssertThrowsError(try KeyBindings.setAction(.zoomPane, for: 20, store: store))
        XCTAssertThrowsError(try KeyBindings.setAction(.zoomPane, for: -1, store: store))
    }

    func testMalformedFileIsNotOverwritten() throws {
        let store = temporaryStore()
        try write("{ not json", to: store)
        XCTAssertThrowsError(try KeyBindings.setAction(.zoomPane, for: 6, store: store))
        XCTAssertEqual(try String(contentsOfFile: store.path), "{ not json")
    }

    func testAccessibilityInputsAreReported() {
        let bindings = KeyBindings(actions: [3: .scroll(.down, amount: 3), 6: .zoomPane, 13: .typeText("hi")])
        // The dial push's play/pause default needs it too.
        XCTAssertEqual(bindings.inputsRequiringAccessibility, [3, 13, 19])
        XCTAssertEqual(bindings.inputs(boundTo: .zoomPane), [6])
    }
}
