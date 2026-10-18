import Foundation

/// Host-side actions for every physical input, plus the tune lists.
///
/// Read from `config.json` (see `StudioConfigStore` for the path):
///
///     {
///       "actions": {
///         "0": "focus-agent",
///         "6": "next-tab",
///         "9": {"type": "submit-prompt", "text": "Run the test suite"},
///         "13": "effort-up",
///         "15": {"type": "scroll", "direction": "up", "amount": 3},
///         "dial-push": {"type": "media-key", "key": "play-pause"}
///       },
///       "keys": { "12": "Run the test suite", "10+11": "Summarise what you are working on" },
///       "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
///       "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
///     }
///
/// Input names are numeric ids or the readable aliases in `Pad.inputs`
/// (`"dial-right"`, `"joy-up"`, …); saves always write numeric ids. A numeric
/// id beats an alias for the same input, and either beats `"10+11"`.
///
/// `"keys"` is the older prompt-text map. It still feeds the string forms
/// `"macro"` (insert that text) and `"voice"` (insert it when present,
/// otherwise tap Superwhisper), and any text action saved without its own
/// `"text"`. Keys 9 and 12 carry suggested texts for those legacy forms; an
/// empty string removes one.
public struct KeyBindings: Sendable, Equatable {

    /// Explicit per-input overrides; inputs absent here use
    /// `InputAction.defaultAction(for:)`.
    public private(set) var actions: [Int: InputAction]
    /// The legacy `"keys"` text, after defaults and `"10+11"` expansion.
    public private(set) var texts: [Int: String]
    /// The models the model actions cycle through in Claude Code, in order.
    /// Overridable with a top-level `"claude": {"models": [...]}` object.
    public private(set) var claudeModels: [String]
    /// The effort ladder the effort actions climb in Claude Code.
    public private(set) var claudeEfforts: [String]
    /// Codex's own `/model` menu, in the order it lists them, from a
    /// `"codex": {"models": [...]}` object. The model actions steer that menu
    /// rather than owning it, so this is the user's copy of what it offers —
    /// there is nothing to read it from, and no sensible default. Empty means
    /// the panel shows the steering guide alone.
    public private(set) var codexModels: [String]

    /// Suggested prompts for the legacy `"macro"` form on keys 9 and 12.
    public static let defaults: [Int: String] = [
        9: "Open a pull request for this branch",
        12: "Run the test suite",
    ]
    public static let defaultClaudeModels = ["fable", "opus", "sonnet", "haiku"]
    public static let defaultClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init(
        actions: [Int: InputAction] = [:],
        texts: [Int: String] = KeyBindings.defaults,
        claudeModels: [String] = KeyBindings.defaultClaudeModels,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        codexModels: [String] = []
    ) {
        self.actions = actions.filter { Pad.configurableInputIDs.contains($0.key) }
        self.texts = texts
        self.claudeModels = claudeModels
        self.claudeEfforts = claudeEfforts
        self.codexModels = codexModels
    }

    // MARK: - Lookup

    /// The action an input runs: its override, or the default.
    public func action(for input: Int) -> InputAction {
        actions[input] ?? InputAction.defaultAction(for: input)
    }

    /// The configured override, or nil when the input runs its default.
    public func actionOverride(for input: Int) -> InputAction? { actions[input] }

    /// Whether the input differs from its default.
    public func isCustomised(_ input: Int) -> Bool {
        guard let action = actions[input] else { return false }
        return action != InputAction.defaultAction(for: input)
    }

    /// The legacy `"keys"` prompt string for an input, or nil.
    public func text(for input: Int) -> String? {
        guard let text = texts[input], !text.isEmpty else { return nil }
        return text
    }

    /// Inputs whose action needs the Accessibility grant.
    public var inputsRequiringAccessibility: [Int] {
        Pad.configurableInputIDs.filter { action(for: $0).requiresAccessibility }
    }

    /// Inputs bound to an action of the given kind, in id order.
    public func inputs(boundTo kind: InputAction.Kind) -> [Int] {
        Pad.configurableInputIDs.filter { action(for: $0).kind == kind }
    }

    // MARK: - Loading

    public static func configPath() -> String { StudioConfigStore.standard.path }

    public static func load(from store: StudioConfigStore = .standard) -> KeyBindings {
        guard let data = store.readData() else { return KeyBindings() }
        return parse(data)
    }

    /// A malformed file falls back to the defaults rather than a dead pad.
    public static func parse(_ data: Data) -> KeyBindings {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KeyBindings() }
        return parse(json)
    }

    public static func parse(_ json: [String: Any]) -> KeyBindings {
        var texts = defaults
        if let keys = json["keys"] as? [String: Any] {
            for (id, text) in resolveInputMap(keys) {
                guard let text = text as? String else { continue }
                if text.isEmpty { texts.removeValue(forKey: id) } else { texts[id] = text }
            }
        }

        var actions: [Int: InputAction] = [:]
        if let configured = json["actions"] as? [String: Any] {
            for (id, value) in resolveInputMap(configured) {
                if let action = InputAction.parse(configValue: value, legacyText: texts[id]) {
                    actions[id] = action
                }
            }
        }

        let claude = json["claude"] as? [String: Any]
        let models = (claude?["models"] as? [String])?.filter { !$0.isEmpty }
        let efforts = (claude?["efforts"] as? [String])?.filter { !$0.isEmpty }
        let codex = json["codex"] as? [String: Any]
        let codexModels = (codex?["models"] as? [String])?.filter { !$0.isEmpty }
        return KeyBindings(
            actions: actions,
            texts: texts,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? []
        )
    }

    /// Flattens an input-keyed map with a fixed precedence, so the result
    /// never depends on dictionary order: `"10+11"` first, then aliases, then
    /// numeric ids, each overwriting the last.
    static func resolveInputMap(_ map: [String: Any]) -> [Int: Any] {
        func rank(_ name: String) -> Int {
            if name == "10+11" { return 0 }
            return Int(name) == nil ? 1 : 2
        }
        var out: [Int: Any] = [:]
        let names = map.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        for name in names {
            for id in Pad.inputIDs(forConfigKey: name) { out[id] = map[name] }
        }
        return out
    }

    // MARK: - Saving

    public enum EditError: LocalizedError, Equatable {
        case notConfigurable(Int)

        public var errorDescription: String? {
            switch self {
            case .notConfigurable(let input):
                return "Input \(input) is not a physical control that can be remapped."
            }
        }
    }

    /// Saves one input's action without touching the pad keymap or the rest
    /// of the file. `nil`, or the input's own default, removes the override.
    public static func setAction(
        _ action: InputAction?,
        for input: Int,
        store: StudioConfigStore = .standard
    ) throws {
        try setActions([input: action], store: store)
    }

    /// The same action for several inputs, in one write.
    public static func setAction(
        _ action: InputAction?,
        for inputs: [Int],
        store: StudioConfigStore = .standard
    ) throws {
        try setActions(Dictionary(inputs.map { ($0, action) }, uniquingKeysWith: { _, last in last }),
                       store: store)
    }

    /// Several inputs at once, in one write; a nil value resets that input.
    public static func setActions(
        _ changes: [Int: InputAction?],
        store: StudioConfigStore = .standard
    ) throws {
        for input in changes.keys where !Pad.configurableInputIDs.contains(input) {
            throw EditError.notConfigurable(input)
        }
        try store.update { json in
            var values = json["actions"] as? [String: Any] ?? [:]
            for (input, action) in changes.sorted(by: { $0.key < $1.key }) {
                // Split a shared voice-key entry first, so editing one half
                // keeps the other half's value.
                if Pad.voiceKeyIDs.contains(input), let paired = values.removeValue(forKey: "10+11") {
                    for key in Pad.voiceKeyIDs where values[String(key)] == nil {
                        values[String(key)] = paired
                    }
                }
                // Aliases for this input would shadow nothing once a numeric
                // id is written, but they would read as the live value.
                for name in values.keys where Int(name) == nil && name != "10+11"
                    && Pad.inputIDs(forConfigKey: name) == [input] {
                    values.removeValue(forKey: name)
                }
                if let action, action != InputAction.defaultAction(for: input) {
                    values[String(input)] = action.configValue
                } else {
                    values.removeValue(forKey: String(input))
                }
            }
            if values.isEmpty { json.removeValue(forKey: "actions") }
            else { json["actions"] = values }
        }
    }

    /// Returns inputs to their defaults.
    public static func resetActions(
        for inputs: [Int],
        store: StudioConfigStore = .standard
    ) throws {
        try setAction(nil, for: inputs, store: store)
    }

    /// Removes every action override. Prompt text and tune lists stay.
    public static func resetAllActions(store: StudioConfigStore = .standard) throws {
        try store.update { json in json.removeValue(forKey: "actions") }
    }
}
