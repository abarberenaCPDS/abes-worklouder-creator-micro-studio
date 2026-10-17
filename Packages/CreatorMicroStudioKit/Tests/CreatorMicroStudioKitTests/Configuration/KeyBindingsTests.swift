import XCTest
@testable import CreatorMicroStudioKit

final class KeyBindingsTests: XCTestCase {

    private func parse(_ json: String) -> KeyBindings {
        KeyBindings.parse(Data(json.utf8))
    }

    func testMissingFileMeansDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertNil(bindings.text(for: 10), "the paired voice key defaults to voice, not text")
        XCTAssertNil(bindings.text(for: 11))
    }

    /// The fallback prompt strings stay limited to the keys that have stock
    /// prompt suggestions, independently of each key's default action.
    func testDefaultsSitOnTheMacroKeys() {
        XCTAssertEqual(KeyBindings.defaults.keys.sorted(), Pad.macroKeyIDs.sorted())
        XCTAssertFalse(Pad.macroKeyIDs.contains(Pad.landKeyID),
                       "the land key answers before any macro on it would")
    }

    func testFileOverridesAKeyAndKeepsTheOtherDefault() {
        let bindings = parse(#"{"keys": {"9": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 9), "Ship it")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
    }

    /// "10+11" binds the paired voice keycaps together.
    func testPairedVoiceKeysBindTogether() {
        let bindings = parse(#"{"keys": {"10+11": "Summarise your progress"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "Summarise your progress")
        XCTAssertEqual(bindings.text(for: 11), "Summarise your progress")
    }

    func testPairedVoiceKeysCanDiffer() {
        let bindings = parse(#"{"keys": {"10": "left half", "11": "right half"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "left half")
        XCTAssertEqual(bindings.text(for: 11), "right half")
    }

    /// An empty string unbinds: the key goes dark rather than typing nothing.
    func testEmptyStringUnbindsADefault() {
        let bindings = parse(#"{"keys": {"12": ""}}"#)
        XCTAssertNil(bindings.text(for: 12))
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches")
    }

    func testMalformedFileFallsBackToDefaults() {
        XCTAssertEqual(parse("not json"), KeyBindings())
        XCTAssertEqual(parse(#"{"keys": "nope"}"#), KeyBindings())
    }

    func testClaudeModelAndEffortListsHaveDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.claudeModels, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeListsAreOverridable() {
        let bindings = parse(#"{"claude": {"models": ["opus", "sonnet"], "efforts": ["low", "high"]}}"#)
        XCTAssertEqual(bindings.claudeModels, ["opus", "sonnet"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.text(for: 9), "Open PRs for all active GitButler branches",
                       "key defaults survive a claude-only config")
    }

    func testEmptyClaudeListsFallBackToDefaults() {
        let bindings = parse(#"{"claude": {"models": []}}"#)
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels)
    }

    /// Codex's list has no default to fall back on: it is a copy of what that
    /// TUI offers, and guessing it would put wrong names next to the numbers.
    func testCodexModelsAreEmptyUntilConfigured() {
        XCTAssertEqual(KeyBindings().codexModels, [])
        XCTAssertEqual(parse(#"{"codex": {"models": []}}"#).codexModels, [])
    }

    func testCodexModelsComeFromTheFile() {
        let bindings = parse(#"{"codex": {"models": ["gpt-5.6-sol", "gpt-5.6-codex"]}}"#)
        XCTAssertEqual(bindings.codexModels, ["gpt-5.6-sol", "gpt-5.6-codex"])
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels,
                       "a codex-only config leaves the claude side alone")
    }

    func testEveryPhysicalKeyDefaultsToFocusAgent() {
        let defaults = KeyBindings()
        for key in Pad.configurableActionKeyIDs {
            XCTAssertEqual(defaults.action(for: key), .focusAgent, "key \(key) defaults to Focus Agent")
        }

        let edited = parse(#"{"actions":{"0":"stack","6":"cycle-tabs","7":"land","8":"macro","9":"voice","10":"none","12":"focus-agent"}}"#)
        XCTAssertEqual(edited.action(for: 0), .stack)
        XCTAssertEqual(edited.action(for: 6), .cycleTabs)
        XCTAssertEqual(edited.action(for: 7), .land)
        XCTAssertEqual(edited.action(for: 8), .macro)
        XCTAssertEqual(edited.action(for: 9), .voice)
        XCTAssertEqual(edited.action(for: 10), .none)
        XCTAssertEqual(edited.action(for: 12), .focusAgent)
        XCTAssertEqual(edited.action(for: 11), .focusAgent)
    }

    func testEveryPhysicalKeyAcceptsEveryAction() {
        for key in Pad.configurableActionKeyIDs {
            for action in KeyAction.configurable where action != .defaultAction {
                let json = #"{"actions":{"\#(key)":"\#(action.rawValue)"}}"#
                XCTAssertEqual(parse(json).action(for: key), action, "key \(key) accepts \(action.title)")
            }
        }
    }

    func testInvalidActionOverridesAreIgnored() {
        let bindings = parse(#"{"actions":{"0":"land","6":"unknown","13":"stack","8":"default"}}"#)
        XCTAssertEqual(bindings.action(for: 0), .land)
        XCTAssertEqual(bindings.action(for: 6), .focusAgent)
        XCTAssertEqual(bindings.action(for: 8), .focusAgent)
    }
}
