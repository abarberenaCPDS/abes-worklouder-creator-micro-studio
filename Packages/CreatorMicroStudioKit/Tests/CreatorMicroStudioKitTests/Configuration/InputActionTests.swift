import XCTest
@testable import CreatorMicroStudioKit

final class InputActionTests: XCTestCase {

    /// One sample of every kind with non-default parameters.
    static let samples: [InputAction] = [
        .none, .focusAgent, .focusSlot(4), .nextTab, .previousTab, .nextWorkspace,
        .previousWorkspace, .focusPane(.left), .zoomPane, .sendKeysToAgent("ctrl+c esc"),
        .herdrCommand("workspace.new"), .insertText("hello"), .submitPrompt("Run the test suite"),
        .effortUp, .effortDown, .modelNext, .modelPrevious, .modelPickerConfirm,
        .modelPickerCancel, .scroll(.right, amount: 7),
        .keyboardShortcut("cmd+shift+k"), .mediaKey(.volumeDown), .voice, .typeText("ünïcødé ✓"),
        .openURL("https://example.com"), .shellCommand("say done"),
    ]

    func testSamplesCoverEveryKind() {
        XCTAssertEqual(Set(Self.samples.map(\.kind)), Set(InputAction.Kind.allCases))
    }

    func testConfigValueRoundTripsForEveryKind() throws {
        for action in Self.samples {
            // Through real JSON, the way config.json carries it.
            let data = try JSONSerialization.data(withJSONObject: ["v": action.configValue])
            let value = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["v"])
            XCTAssertEqual(InputAction.parse(configValue: value), action, "\(action.kind)")
        }
    }

    func testParameterlessActionsAreWrittenAsStrings() {
        for action in Self.samples where action != .voice {
            let isString = action.configValue is String
            XCTAssertEqual(isString, !action.kind.isParameterised, "\(action.kind)")
        }
        // A bare "voice" is the legacy form that may type text instead.
        XCTAssertEqual((InputAction.voice.configValue as? [String: Any])?["type"] as? String, "voice")
        XCTAssertEqual(KeyBindings.parse(Data(#"{"actions": {"9": {"type": "voice"}}}"#.utf8)).action(for: 9),
                       .voice, "the object form is plain voice even with text on the key")
        XCTAssertEqual(InputAction.focusAgent.configValue as? String, "focus-agent")
        XCTAssertEqual(InputAction.modelPickerCancel.configValue as? String, "model-picker-cancel")
    }

    func testCodableMatchesTheConfigShape() throws {
        for action in Self.samples {
            let data = try JSONEncoder().encode(action)
            XCTAssertEqual(try JSONDecoder().decode(InputAction.self, from: data), action, "\(action.kind)")
        }
        let decoded = try JSONDecoder().decode(
            [String: InputAction].self,
            from: Data(#"{"a": "zoom-pane", "b": {"type": "scroll", "direction": "up", "amount": 2}}"#.utf8))
        XCTAssertEqual(decoded["a"], .zoomPane)
        XCTAssertEqual(decoded["b"], .scroll(.up, amount: 2))
        XCTAssertThrowsError(try JSONDecoder().decode(InputAction.self, from: Data(#""nope""#.utf8)))
    }

    /// The GitButler "stack" and "land" actions are gone. Their names, in
    /// either config form and any spelling, read as "no override".
    func testRetiredKindsParseAsNoOverride() {
        for value: Any in ["stack", "land", "LAND", "Stack", ["type": "stack"], ["type": "land"]] {
            XCTAssertNil(InputAction.parse(configValue: value, legacyText: "text"), "\(value)")
        }
        XCTAssertNil(InputAction.Kind(configName: "stack"))
        XCTAssertNil(InputAction.Kind(configName: "land"))
        XCTAssertFalse(InputAction.Category.allCases.contains { $0.rawValue == "panels" },
                       "the category emptied by the removal is gone")
    }

    func testKindNamesAreForgiving() {
        XCTAssertEqual(InputAction.Kind(configName: "focus-agent"), .focusAgent)
        XCTAssertEqual(InputAction.Kind(configName: "focus_agent"), .focusAgent)
        XCTAssertEqual(InputAction.Kind(configName: "focusAgent"), .focusAgent)
        XCTAssertEqual(InputAction.Kind(configName: "MACRO"), .insertText)
        XCTAssertEqual(InputAction.Kind(configName: "cycle-tabs"), .nextTab)
        XCTAssertNil(InputAction.Kind(configName: "fly"))
    }

    func testParametersAreClampedAndDefaulted() {
        XCTAssertEqual(InputAction.parse(configValue: ["type": "focus-slot", "slot": 9]), .focusSlot(6))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "focus-slot"]), .focusSlot(1))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "scroll", "direction": "UP", "amount": 99]),
                       .scroll(.up, amount: 20))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "scroll", "lines": "2"]),
                       .scroll(.down, amount: 2))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "media-key", "key": "volumeUp"]),
                       .mediaKey(.volumeUp))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "media-key", "key": "?"]),
                       .mediaKey(.playPause))
        XCTAssertEqual(InputAction.parse(configValue: ["type": "insert-text"], legacyText: "old"),
                       .insertText("old"), "a text action without text uses the key's text")
        XCTAssertNil(InputAction.parse(configValue: ["text": "no type"]))
        XCTAssertNil(InputAction.parse(configValue: 3))
        XCTAssertNil(InputAction.parse(configValue: "default"))
    }

    func testEveryKindHasPresentationAndACategory() {
        for kind in InputAction.Kind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.symbol.isEmpty)
            XCTAssertTrue(kind.category.kinds.contains(kind))
            XCTAssertEqual(kind.defaultAction.kind, kind)
        }
        XCTAssertEqual(InputAction.Category.allCases.flatMap(\.kinds).count, InputAction.Kind.allCases.count)
        XCTAssertEqual(InputAction.Category.system.kinds,
                       [.scroll, .keyboardShortcut, .mediaKey, .voice, .typeText])
        XCTAssertTrue(InputAction.Kind.scroll.requiresAccessibility)
        XCTAssertFalse(InputAction.Kind.shellCommand.requiresAccessibility)
        XCTAssertEqual(InputAction.Kind.scroll.parameters, [.direction, .amount])
    }

    func testAccessorsEditParametersInPlace() {
        var action = InputAction.scroll(.down, amount: 3)
        action.direction = .left
        action.amount = 50
        XCTAssertEqual(action, .scroll(.left, amount: 20))
        action.stringValue = "ignored"
        XCTAssertEqual(action, .scroll(.left, amount: 20), "scroll has no text")

        var prompt = InputAction.insertText("a")
        prompt.stringValue = "b"
        XCTAssertEqual(prompt, .insertText("b"))
        XCTAssertNil(prompt.direction)

        var slot = InputAction.focusSlot(2)
        slot.slot = 0
        XCTAssertEqual(slot, .focusSlot(1))

        var media = InputAction.mediaKey(.mute)
        media.mediaKey = .next
        XCTAssertEqual(media, .mediaKey(.next))
    }

    func testConvertingKeepsSharedParameters() {
        XCTAssertEqual(InputAction.insertText("hi").converted(to: .submitPrompt), .submitPrompt("hi"))
        XCTAssertEqual(InputAction.focusPane(.up).converted(to: .scroll), .scroll(.up, amount: 3))
        XCTAssertEqual(InputAction.zoomPane.converted(to: .mediaKey), .mediaKey(.playPause))
        XCTAssertEqual(InputAction.voice.converted(to: .voice), .voice)
    }

    func testSummariesMentionParameters() {
        XCTAssertEqual(InputAction.scroll(.up, amount: 3).summary, "Scroll up ×3")
        XCTAssertEqual(InputAction.submitPrompt("Go").summary, "Submit prompt: Go")
        XCTAssertEqual(InputAction.insertText("").summary, "Insert text (not set)")
        XCTAssertEqual(InputAction.focusSlot(2).summary, "Focus agent slot 2")
        XCTAssertEqual(InputAction.zoomPane.summary, "Zoom pane")
    }

    func testIdentifiersAreStable() {
        XCTAssertEqual(InputAction.zoomPane.id, "zoom-pane")
        XCTAssertEqual(InputAction.scroll(.up, amount: 3).id, InputAction.scroll(.up, amount: 3).id)
        XCTAssertNotEqual(InputAction.scroll(.up, amount: 3).id, InputAction.scroll(.up, amount: 4).id)
    }
}
