import Foundation

/// What a key does in the Studio. `.defaultAction` removes a user override.
public enum KeyAction: String, CaseIterable, Hashable, Identifiable, Sendable {
    case defaultAction = "default"
    case focusAgent = "focus-agent"
    case stack
    case cycleTabs = "cycle-tabs"
    case land
    case macro
    case voice
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .defaultAction: return "Default"
        case .focusAgent: return "Focus Agent"
        case .stack: return "GitButler stack"
        case .cycleTabs: return "Cycle tabs"
        case .land: return "Land branches"
        case .macro: return "Prompt macro"
        case .voice: return "Voice control"
        case .none: return "Do nothing"
        }
    }

    public static let configurable: [KeyAction] = [
        .defaultAction, .focusAgent, .stack, .cycleTabs, .land, .macro, .voice, .none,
    ]

    public static func defaultAction(for key: Int) -> KeyAction {
        Pad.configurableActionKeyIDs.contains(key) ? .focusAgent : .none
    }
}

/// User-configurable actions and optional prompt text for physical keys.
///
/// Read from `$XDG_CONFIG_HOME/creator-micro-studio/config.json`
/// (`~/.config/creator-micro-studio/config.json` by default):
///
///     {
///       "keys": {
///         "9": "Open PRs for all active GitButler branches",
///         "12": "Run but pull",
///         "10+11": "Summarise what you are working on"
///       },
///       "actions": { "0": "focus-agent", "6": "stack", "7": "cycle-tabs", "8": "land" },
///       "claude": { "models": ["fable", "opus"], "efforts": ["low", "high"] },
///       "codex":  { "models": ["gpt-5.6-sol", "gpt-5.6-codex"] }
///     }
///
/// A bound string is injected into the focused agent's prompt, unsubmitted.
/// `"10+11"` binds both paired voice keys; `"10"` and `"11"` address either
/// physical keycap separately. All keys default to Focus Agent; optional prompt
/// strings are used when a key is assigned Prompt Macro or Voice Control. Empty
/// strings remove a suggested or configured prompt.
public struct KeyBindings: Sendable, Equatable {

    public private(set) var texts: [Int: String]
    public private(set) var actions: [Int: KeyAction]
    /// The models the joystick cycles through in Claude Code, in order.
    /// Overridable with a top-level `"claude": {"models": [...]}` object.
    public private(set) var claudeModels: [String]
    /// The effort ladder the dial climbs in Claude Code.
    public private(set) var claudeEfforts: [String]
    /// Codex's own `/model` menu, in the order it lists them, from a
    /// `"codex": {"models": [...]}` object. The joystick steers that menu
    /// rather than owning it, so this is the user's copy of what it offers —
    /// there is nothing to read it from, and no sensible default. Empty means
    /// the panel shows the steering guide alone.
    public private(set) var codexModels: [String]

    public static let defaults: [Int: String] = [
        9: "Open PRs for all active GitButler branches",
        12: "Run but pull",
    ]
    public static let defaultClaudeModels = ["fable", "opus", "sonnet", "haiku"]
    public static let defaultClaudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init(
        texts: [Int: String] = KeyBindings.defaults,
        actions: [Int: KeyAction] = [:],
        claudeModels: [String] = KeyBindings.defaultClaudeModels,
        claudeEfforts: [String] = KeyBindings.defaultClaudeEfforts,
        codexModels: [String] = []
    ) {
        self.texts = texts
        self.actions = actions
        self.claudeModels = claudeModels
        self.claudeEfforts = claudeEfforts
        self.codexModels = codexModels
    }

    /// The optional prompt string bound to a key, or nil when none is configured.
    public func text(for key: Int) -> String? {
        guard let text = texts[key], !text.isEmpty else { return nil }
        return text
    }

    public func actionOverride(for key: Int) -> KeyAction? { actions[key] }

    public func action(for key: Int) -> KeyAction {
        guard Pad.configurableActionKeyIDs.contains(key),
              let action = actions[key], action != .defaultAction else {
            return KeyAction.defaultAction(for: key)
        }
        return action
    }

    public static func configPath() -> String {
        let base = configBasePath()
        return (base as NSString).appendingPathComponent("creator-micro-studio/config.json")
    }

    public static func load() -> KeyBindings {
        let fileManager = FileManager.default
        let data = fileManager.contents(atPath: configPath())
            ?? fileManager.contents(atPath: legacyConfigPath())
        guard let data else {
            return KeyBindings()
        }
        return parse(data)
    }

    /// Persist an action override without touching the pad keymap or other config.
    public static func setAction(_ action: KeyAction, for key: Int) throws {
        guard Pad.configurableActionKeyIDs.contains(key) else { throw EditError.notConfigurable(key) }
        var json = try editableConfig()
        var values = json["actions"] as? [String: Any] ?? [:]
        if action == .defaultAction {
            values.removeValue(forKey: String(key))
        } else {
            values[String(key)] = action.rawValue
        }
        if values.isEmpty { json.removeValue(forKey: "actions") }
        else { json["actions"] = values }
        try write(json)
    }

    /// Save prompt text for an individual key. Splitting an existing `10+11`
    /// pair first preserves its value on the other physical voice key.
    public static func setText(_ text: String?, for key: Int) throws {
        guard (0..<Pad.keyCount).contains(key) else { throw EditError.invalidKey(key) }
        var json = try editableConfig()
        var values = json["keys"] as? [String: Any] ?? [:]
        if (key == 10 || key == 11), let paired = values.removeValue(forKey: "10+11") as? String {
            values["10"] = paired
            values["11"] = paired
        }
        if let text { values[String(key)] = text }
        else { values.removeValue(forKey: String(key)) }
        if values.isEmpty { json.removeValue(forKey: "keys") }
        else { json["keys"] = values }
        try write(json)
    }

    private enum EditError: LocalizedError {
        case malformedConfig
        case invalidKey(Int)
        case notConfigurable(Int)

        var errorDescription: String? {
            switch self {
            case .malformedConfig:
                return "The existing config.json is not valid JSON. Fix it before saving key actions."
            case .invalidKey(let key):
                return "Key \(key) is outside the Creator Micro 2 key range."
            case .notConfigurable(let key):
                return "Key \(key) is not a physical keycap that can be remapped."
            }
        }
    }

    private static func editableConfig() throws -> [String: Any] {
        let manager = FileManager.default
        guard let data = manager.contents(atPath: configPath())
                ?? manager.contents(atPath: legacyConfigPath())
        else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EditError.malformedConfig
        }
        return json
    }

    private static func write(_ json: [String: Any]) throws {
        let url = URL(fileURLWithPath: configPath())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func configBasePath() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
    }

    /// Keep reading the pre-rename location so existing user macros still work.
    private static func legacyConfigPath() -> String {
        (configBasePath() as NSString).appendingPathComponent("micromanager/config.json")
    }

    /// A malformed file falls back to the defaults rather than a dead pad.
    static func parse(_ data: Data) -> KeyBindings {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KeyBindings() }

        var texts = defaults
        if let keys = json["keys"] as? [String: Any] {
            for (name, value) in keys {
                guard let text = value as? String else { continue }
                for key in keyIDs(for: name) {
                    if text.isEmpty {
                        texts.removeValue(forKey: key)
                    } else {
                        texts[key] = text
                    }
                }
            }
        }

        let claude = json["claude"] as? [String: Any]
        let models = (claude?["models"] as? [String])?.filter { !$0.isEmpty }
        let efforts = (claude?["efforts"] as? [String])?.filter { !$0.isEmpty }
        let codex = json["codex"] as? [String: Any]
        let codexModels = (codex?["models"] as? [String])?.filter { !$0.isEmpty }
        var actions: [Int: KeyAction] = [:]
        if let configured = json["actions"] as? [String: Any] {
            for (keyString, value) in configured {
                guard let key = Int(keyString),
                      Pad.configurableActionKeyIDs.contains(key),
                      let raw = value as? String,
                      let action = KeyAction(rawValue: raw),
                      action != .defaultAction
                else { continue }
                actions[key] = action
            }
        }
        return KeyBindings(
            texts: texts,
            actions: actions,
            claudeModels: models?.isEmpty == false ? models! : defaultClaudeModels,
            claudeEfforts: efforts?.isEmpty == false ? efforts! : defaultClaudeEfforts,
            codexModels: codexModels ?? []
        )
    }

    private static func keyIDs(for name: String) -> [Int] {
        if name == "10+11" { return Pad.voiceKeyIDs }
        guard let id = Int(name) else { return [] }
        return [id]
    }
}
