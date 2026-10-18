import Foundation

/// What one physical input does when pressed. Host-side only: actions live in
/// `config.json` and are dispatched by the bridge; nothing here is ever
/// written to the device keymap.
///
/// In `config.json` a parameterless action is its kind's name and a
/// parameterised one is an object tagged with `"type"`:
///
///     "actions": {
///       "0": "focus-agent",
///       "9": {"type": "submit-prompt", "text": "Run the test suite"},
///       "15": {"type": "scroll", "direction": "up", "amount": 3}
///     }
public enum InputAction: Hashable, Sendable {
    case none

    // Herdr / agents
    /// The key's own agent slot, or the agent Herdr has focused for an input
    /// with no slot.
    case focusAgent
    /// Agent slot 1...6, in pad reading order.
    case focusSlot(Int)
    case nextTab
    case previousTab
    case nextWorkspace
    case previousWorkspace
    /// `pane.focus_direction`.
    case focusPane(Direction)
    /// `pane.zoom`, toggled.
    case zoomPane
    /// Space-separated crossterm key names sent to the focused agent's pane,
    /// for example `"ctrl+c esc"`.
    case sendKeysToAgent(String)
    /// A Herdr CLI command line without the leading `herdr`, such as
    /// `tab rename {tab} {ask:New tab name={tab_label}}`. Placeholders are
    /// filled from Herdr's focus at press time; see `HerdrCommand`.
    case herdrCommand(String)

    // Prompts
    /// Pasted into the focused agent's prompt, not submitted.
    case insertText(String)
    /// Pasted and submitted with `agent.prompt`; Herdr rejects a blocked agent.
    case submitPrompt(String)

    // Model & effort — handed to the app's tune controller.
    case effortUp
    case effortDown
    case modelNext
    case modelPrevious
    case modelPickerConfirm
    case modelPickerCancel

    // System — synthesised events; needs Accessibility.
    case scroll(Direction, amount: Int)
    /// A chord such as `"cmd+shift+k"`, `"pageup"`, `"f5"`, `"return"`.
    case keyboardShortcut(String)
    case mediaKey(MediaKey)
    /// Taps right Command, Superwhisper's start/stop. Handed to the app.
    case voice
    /// Typed system-wide into whatever has keyboard focus.
    case typeText(String)

    // Launch
    /// A URL, a file path, an app name or a bundle id.
    case openURL(String)
    /// Run with `/bin/zsh -lc` in the background.
    case shellCommand(String)

    // MARK: - Parameter types

    public enum Direction: String, CaseIterable, Identifiable, Hashable, Sendable {
        case up, down, left, right

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
        public var symbol: String { "arrow.\(rawValue)" }
    }

    public enum MediaKey: String, CaseIterable, Identifiable, Hashable, Sendable {
        case playPause = "play-pause"
        case next
        case previous
        case volumeUp = "volume-up"
        case volumeDown = "volume-down"
        case mute
        case brightnessUp = "brightness-up"
        case brightnessDown = "brightness-down"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .playPause: return "Play / Pause"
            case .next: return "Next track"
            case .previous: return "Previous track"
            case .volumeUp: return "Volume up"
            case .volumeDown: return "Volume down"
            case .mute: return "Mute"
            case .brightnessUp: return "Brightness up"
            case .brightnessDown: return "Brightness down"
            }
        }

        public var symbol: String {
            switch self {
            case .playPause: return "playpause.fill"
            case .next: return "forward.fill"
            case .previous: return "backward.fill"
            case .volumeUp: return "speaker.wave.3.fill"
            case .volumeDown: return "speaker.wave.1.fill"
            case .mute: return "speaker.slash.fill"
            case .brightnessUp: return "sun.max.fill"
            case .brightnessDown: return "sun.min.fill"
            }
        }
    }

    /// Which editable value an action carries, for building an editor.
    public enum Parameter: String, CaseIterable, Identifiable, Sendable {
        case slot
        case direction
        case amount
        case keys
        /// A Herdr CLI command line, see `HerdrCommand`.
        case herdrCommand
        case text
        case shortcut
        case mediaKey
        case url
        case command

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .slot: return "Agent slot"
            case .direction: return "Direction"
            case .amount: return "Lines"
            case .keys: return "Keys"
            case .herdrCommand: return "Herdr command"
            case .text: return "Text"
            case .shortcut: return "Shortcut"
            case .mediaKey: return "Media key"
            case .url: return "URL, file or app"
            case .command: return "Shell command"
            }
        }

        public var placeholder: String {
            switch self {
            case .slot: return "1"
            case .direction: return "up"
            case .amount: return "3"
            case .keys: return "ctrl+c esc"
            case .herdrCommand: return "tab rename {tab} {ask:New tab name}"
            case .text: return "Prompt text"
            case .shortcut: return "cmd+shift+k"
            case .mediaKey: return "play-pause"
            case .url: return "https://… · ~/notes.md · Safari · com.apple.Terminal"
            case .command: return "say done"
            }
        }

        /// True for the free-text parameters, which all live in `stringValue`.
        public var isString: Bool {
            switch self {
            case .keys, .herdrCommand, .text, .shortcut, .url, .command: return true
            case .slot, .direction, .amount, .mediaKey: return false
            }
        }

        /// Code-like values an editor should show in a monospaced font.
        public var isMonospaced: Bool {
            switch self {
            case .keys, .herdrCommand, .shortcut, .command: return true
            default: return false
            }
        }
    }

    /// Valid ranges, shared by parsing and editors.
    public static let slotRange = 1...Pad.agentKeyIDs.count
    public static let scrollAmountRange = 1...20
    public static let defaultScrollAmount = 3

    // MARK: - Kinds

    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case general
        case herdr
        case prompts
        case tune
        case system
        case launch

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .general: return "General"
            case .herdr: return "Herdr / agents"
            case .prompts: return "Prompts"
            case .tune: return "Model & effort"
            case .system: return "System"
            case .launch: return "Launch"
            }
        }

        public var symbol: String {
            switch self {
            case .general: return "circle.dashed"
            case .herdr: return "rectangle.3.group"
            case .prompts: return "text.bubble"
            case .tune: return "slider.horizontal.3"
            case .system: return "keyboard"
            case .launch: return "arrow.up.forward.app"
            }
        }

        public var kinds: [Kind] { Kind.allCases.filter { $0.category == self } }
    }

    /// The action without its parameters. The raw value is the config name.
    public enum Kind: String, CaseIterable, Identifiable, Hashable, Sendable {
        case none
        case focusAgent = "focus-agent"
        case focusSlot = "focus-slot"
        case nextTab = "next-tab"
        case previousTab = "previous-tab"
        case nextWorkspace = "next-workspace"
        case previousWorkspace = "previous-workspace"
        case focusPane = "focus-pane"
        case zoomPane = "zoom-pane"
        case sendKeysToAgent = "send-keys"
        case herdrCommand = "herdr-command"
        case insertText = "insert-text"
        case submitPrompt = "submit-prompt"
        case effortUp = "effort-up"
        case effortDown = "effort-down"
        case modelNext = "model-next"
        case modelPrevious = "model-previous"
        case modelPickerConfirm = "model-picker-confirm"
        case modelPickerCancel = "model-picker-cancel"
        case scroll
        case keyboardShortcut = "keyboard-shortcut"
        case mediaKey = "media-key"
        case voice
        case typeText = "type-text"
        case openURL = "open-url"
        case shellCommand = "shell-command"

        public var id: String { rawValue }
        public var configName: String { rawValue }

        public var title: String {
            switch self {
            case .none: return "Do nothing"
            case .focusAgent: return "Focus agent"
            case .focusSlot: return "Focus agent slot"
            case .nextTab: return "Next tab"
            case .previousTab: return "Previous tab"
            case .nextWorkspace: return "Next workspace"
            case .previousWorkspace: return "Previous workspace"
            case .focusPane: return "Focus pane"
            case .zoomPane: return "Zoom pane"
            case .sendKeysToAgent: return "Send keys to agent"
            case .herdrCommand: return "Herdr command"
            case .insertText: return "Insert text"
            case .submitPrompt: return "Submit prompt"
            case .effortUp: return "Effort up"
            case .effortDown: return "Effort down"
            case .modelNext: return "Next model"
            case .modelPrevious: return "Previous model"
            case .modelPickerConfirm: return "Confirm model picker"
            case .modelPickerCancel: return "Cancel model picker"
            case .scroll: return "Scroll"
            case .keyboardShortcut: return "Keyboard shortcut"
            case .mediaKey: return "Media key"
            case .voice: return "Voice (Superwhisper)"
            case .typeText: return "Type text"
            case .openURL: return "Open URL, file or app"
            case .shellCommand: return "Run shell command"
            }
        }

        public var symbol: String {
            switch self {
            case .none: return "circle.slash"
            case .focusAgent: return "scope"
            case .focusSlot: return "number.square"
            case .nextTab: return "arrow.right.to.line"
            case .previousTab: return "arrow.left.to.line"
            case .nextWorkspace: return "rectangle.stack.badge.plus"
            case .previousWorkspace: return "rectangle.stack"
            case .focusPane: return "rectangle.split.2x1"
            case .zoomPane: return "arrow.up.left.and.arrow.down.right"
            case .sendKeysToAgent: return "keyboard.badge.ellipsis"
            case .herdrCommand: return "command"
            case .insertText: return "text.cursor"
            case .submitPrompt: return "paperplane"
            case .effortUp: return "gauge.high"
            case .effortDown: return "gauge.low"
            case .modelNext: return "chevron.down.circle"
            case .modelPrevious: return "chevron.up.circle"
            case .modelPickerConfirm: return "checkmark.circle"
            case .modelPickerCancel: return "xmark.circle"
            case .scroll: return "scroll"
            case .keyboardShortcut: return "command.square"
            case .mediaKey: return "playpause"
            case .voice: return "mic"
            case .typeText: return "character.cursor.ibeam"
            case .openURL: return "safari"
            case .shellCommand: return "terminal"
            }
        }

        public var category: Category {
            switch self {
            case .none: return .general
            case .focusAgent, .focusSlot, .nextTab, .previousTab, .nextWorkspace,
                 .previousWorkspace, .focusPane, .zoomPane, .sendKeysToAgent, .herdrCommand:
                return .herdr
            case .insertText, .submitPrompt: return .prompts
            case .effortUp, .effortDown, .modelNext, .modelPrevious,
                 .modelPickerConfirm, .modelPickerCancel:
                return .tune
            case .scroll, .keyboardShortcut, .mediaKey, .voice, .typeText: return .system
            case .openURL, .shellCommand: return .launch
            }
        }

        /// The values an editor should offer for this kind, in display order.
        public var parameters: [Parameter] {
            switch self {
            case .focusSlot: return [.slot]
            case .focusPane: return [.direction]
            case .scroll: return [.direction, .amount]
            case .sendKeysToAgent: return [.keys]
            case .herdrCommand: return [.herdrCommand]
            case .insertText, .submitPrompt, .typeText: return [.text]
            case .keyboardShortcut: return [.shortcut]
            case .mediaKey: return [.mediaKey]
            case .openURL: return [.url]
            case .shellCommand: return [.command]
            default: return []
            }
        }

        public var isParameterised: Bool { !parameters.isEmpty }

        /// Synthesised keyboard, scroll and media events need the
        /// Accessibility grant for the Studio app.
        public var requiresAccessibility: Bool {
            switch self {
            case .scroll, .keyboardShortcut, .mediaKey, .voice, .typeText: return true
            default: return false
            }
        }

        /// Talks to the Herdr server when it runs.
        public var usesHerdr: Bool {
            category == .herdr || category == .prompts || category == .tune
        }

        /// This kind with sensible starting parameters.
        public var defaultAction: InputAction {
            switch self {
            case .none: return .none
            case .focusAgent: return .focusAgent
            case .focusSlot: return .focusSlot(1)
            case .nextTab: return .nextTab
            case .previousTab: return .previousTab
            case .nextWorkspace: return .nextWorkspace
            case .previousWorkspace: return .previousWorkspace
            case .focusPane: return .focusPane(.right)
            case .zoomPane: return .zoomPane
            case .sendKeysToAgent: return .sendKeysToAgent("ctrl+c")
            case .herdrCommand: return .herdrCommand("")
            case .insertText: return .insertText("")
            case .submitPrompt: return .submitPrompt("")
            case .effortUp: return .effortUp
            case .effortDown: return .effortDown
            case .modelNext: return .modelNext
            case .modelPrevious: return .modelPrevious
            case .modelPickerConfirm: return .modelPickerConfirm
            case .modelPickerCancel: return .modelPickerCancel
            case .scroll: return .scroll(.down, amount: InputAction.defaultScrollAmount)
            case .keyboardShortcut: return .keyboardShortcut("")
            case .mediaKey: return .mediaKey(.playPause)
            case .voice: return .voice
            case .typeText: return .typeText("")
            case .openURL: return .openURL("")
            case .shellCommand: return .shellCommand("")
            }
        }

        /// Config names from before parameterised actions, and spelling
        /// variants, folded onto the current kinds.
        static let aliases: [String: Kind] = [
            "macro": .insertText,
            "cycle-tabs": .nextTab,
            "send-keys-to-agent": .sendKeysToAgent,
            "shortcut": .keyboardShortcut,
            "open": .openURL,
            "shell": .shellCommand,
            "media": .mediaKey,
            "prompt": .submitPrompt,
        ]

        /// Config names of actions that have been removed. An existing
        /// `config.json` may still carry them (`"stack"` and `"land"` were the
        /// GitButler panels); they read as "no override", so the input falls
        /// back to its default instead of failing to load.
        public static let retiredConfigNames: Set<String> = ["stack", "land"]

        static func isRetired(_ name: String) -> Bool {
            retiredConfigNames.contains { normalise($0) == normalise(name) }
        }

        /// Accepts the config name, an alias, or any casing/underscore
        /// variant of either (`"focus_agent"`, `"focusAgent"`).
        public init?(configName: String) {
            let wanted = Kind.normalise(configName)
            if let kind = Kind.allCases.first(where: { Kind.normalise($0.rawValue) == wanted }) {
                self = kind
                return
            }
            if let kind = Kind.aliases.first(where: { Kind.normalise($0.key) == wanted })?.value {
                self = kind
                return
            }
            return nil
        }

        static func normalise(_ name: String) -> String {
            name.lowercased().filter { $0.isLetter || $0.isNumber }
        }
    }

    // MARK: - Accessors

    public var kind: Kind {
        switch self {
        case .none: return .none
        case .focusAgent: return .focusAgent
        case .focusSlot: return .focusSlot
        case .nextTab: return .nextTab
        case .previousTab: return .previousTab
        case .nextWorkspace: return .nextWorkspace
        case .previousWorkspace: return .previousWorkspace
        case .focusPane: return .focusPane
        case .zoomPane: return .zoomPane
        case .sendKeysToAgent: return .sendKeysToAgent
        case .herdrCommand: return .herdrCommand
        case .insertText: return .insertText
        case .submitPrompt: return .submitPrompt
        case .effortUp: return .effortUp
        case .effortDown: return .effortDown
        case .modelNext: return .modelNext
        case .modelPrevious: return .modelPrevious
        case .modelPickerConfirm: return .modelPickerConfirm
        case .modelPickerCancel: return .modelPickerCancel
        case .scroll: return .scroll
        case .keyboardShortcut: return .keyboardShortcut
        case .mediaKey: return .mediaKey
        case .voice: return .voice
        case .typeText: return .typeText
        case .openURL: return .openURL
        case .shellCommand: return .shellCommand
        }
    }

    public var title: String { kind.title }
    public var symbol: String { kind.symbol }
    public var category: Category { kind.category }
    public var requiresAccessibility: Bool { kind.requiresAccessibility }

    /// The kind's title plus its parameters, for lists and tooltips:
    /// "Scroll down ×3", "Submit prompt: Run the test suite".
    public var summary: String {
        switch self {
        case .focusSlot(let slot): return "Focus agent slot \(slot)"
        case .focusPane(let direction): return "Focus pane \(direction.rawValue)"
        case .scroll(let direction, let amount): return "Scroll \(direction.rawValue) ×\(amount)"
        case .mediaKey(let key): return key.title
        default:
            guard let value = stringValue else { return title }
            return value.isEmpty ? "\(title) (not set)" : "\(title): \(value)"
        }
    }

    /// The free-text parameter — prompt text, keys, shortcut, URL, command or
    /// Herdr command line — for kinds that have one. Setting it on any other kind
    /// does nothing.
    public var stringValue: String? {
        get {
            switch self {
            case .sendKeysToAgent(let value), .herdrCommand(let value),
                 .insertText(let value), .submitPrompt(let value),
                 .keyboardShortcut(let value), .typeText(let value),
                 .openURL(let value), .shellCommand(let value):
                return value
            default:
                return nil
            }
        }
        set {
            guard let newValue else { return }
            switch self {
            case .sendKeysToAgent: self = .sendKeysToAgent(newValue)
            case .herdrCommand: self = .herdrCommand(newValue)
            case .insertText: self = .insertText(newValue)
            case .submitPrompt: self = .submitPrompt(newValue)
            case .keyboardShortcut: self = .keyboardShortcut(newValue)
            case .typeText: self = .typeText(newValue)
            case .openURL: self = .openURL(newValue)
            case .shellCommand: self = .shellCommand(newValue)
            default: break
            }
        }
    }

    /// 1...6 for `focusSlot`; clamped when set.
    public var slot: Int? {
        get { if case .focusSlot(let slot) = self { return slot }; return nil }
        set {
            guard let newValue, case .focusSlot = self else { return }
            self = .focusSlot(InputAction.clamp(newValue, InputAction.slotRange))
        }
    }

    /// For `focusPane` and `scroll`.
    public var direction: Direction? {
        get {
            switch self {
            case .focusPane(let direction), .scroll(let direction, _): return direction
            default: return nil
            }
        }
        set {
            guard let newValue else { return }
            switch self {
            case .focusPane: self = .focusPane(newValue)
            case .scroll(_, let amount): self = .scroll(newValue, amount: amount)
            default: break
            }
        }
    }

    /// Scroll lines, 1...20; clamped when set.
    public var amount: Int? {
        get { if case .scroll(_, let amount) = self { return amount }; return nil }
        set {
            guard let newValue, case .scroll(let direction, _) = self else { return }
            self = .scroll(direction, amount: InputAction.clamp(newValue, InputAction.scrollAmountRange))
        }
    }

    public var mediaKey: MediaKey? {
        get { if case .mediaKey(let key) = self { return key }; return nil }
        set {
            guard let newValue, case .mediaKey = self else { return }
            self = .mediaKey(newValue)
        }
    }

    /// This action switched to another kind, keeping the free-text value
    /// where both kinds have one (so Insert text → Submit prompt keeps the
    /// prompt).
    public func converted(to kind: Kind) -> InputAction {
        guard kind != self.kind else { return self }
        var next = kind.defaultAction
        if let value = stringValue, !value.isEmpty, next.stringValue != nil {
            next.stringValue = value
        }
        if let direction, next.direction != nil { next.direction = direction }
        return next
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    // MARK: - Defaults

    /// What an input does with no config: keys focus their agent (or the
    /// current one), the dial steps effort, the joystick works the model list
    /// and picker, and the dial push keeps the stock play/pause it had before
    /// AG19 was bound.
    public static func defaultAction(for input: Int) -> InputAction {
        switch input {
        case 0..<Pad.keyCount: return .focusAgent
        case Pad.dialUpID: return .effortUp
        case Pad.dialDownID: return .effortDown
        case Pad.joyNorthID: return .modelPrevious
        case Pad.joySouthID: return .modelNext
        case Pad.joyEastID: return .modelPickerConfirm
        case Pad.joyWestID: return .modelPickerCancel
        case Pad.dialPushID: return .mediaKey(.playPause)
        default: return .none
        }
    }

    // MARK: - Config encoding

    /// The `config.json` value: the kind's name for parameterless actions, a
    /// `"type"`-tagged object otherwise. Voice is the exception: a bare
    /// `"voice"` is the legacy form that types a key's `"keys"` text when it
    /// has one, so plain voice is written as `{"type": "voice"}`.
    public var configValue: Any {
        var object: [String: Any] = ["type": kind.configName]
        switch self {
        case .voice: return object
        case .focusSlot(let slot): object["slot"] = slot
        case .focusPane(let direction): object["direction"] = direction.rawValue
        case .scroll(let direction, let amount):
            object["direction"] = direction.rawValue
            object["amount"] = amount
        case .sendKeysToAgent(let keys): object["keys"] = keys
        case .herdrCommand(let id): object["command"] = id
        case .insertText(let text), .submitPrompt(let text), .typeText(let text):
            object["text"] = text
        case .keyboardShortcut(let shortcut): object["keys"] = shortcut
        case .mediaKey(let key): object["key"] = key.rawValue
        case .openURL(let target): object["url"] = target
        case .shellCommand(let command): object["command"] = command
        default: return kind.configName
        }
        return object
    }

    /// Reads one `actions` value. `legacyText` is the input's `"keys"` text,
    /// which the old string forms (`"macro"`, `"voice"`) and a text action
    /// without its own `"text"` fall back to. Returns nil for anything
    /// unrecognised, for `"default"`, which means "no override", and for the
    /// retired kinds in `Kind.retiredConfigNames`, which mean the same.
    public static func parse(configValue value: Any, legacyText: String? = nil) -> InputAction? {
        if let name = value as? String {
            if Kind.normalise(name) == "default" || Kind.isRetired(name) { return nil }
            // The old voice key typed its prompt text when it had one.
            if Kind.normalise(name) == "voice" {
                if let legacyText, !legacyText.isEmpty { return .insertText(legacyText) }
                return .voice
            }
            guard let kind = Kind(configName: name) else { return nil }
            var action = kind.defaultAction
            if action.stringValue != nil, kind.parameters == [.text] {
                action.stringValue = legacyText ?? ""
            }
            return action
        }

        guard let object = value as? [String: Any],
              let type = object["type"] as? String,
              !Kind.isRetired(type),
              let kind = Kind(configName: type)
        else { return nil }

        func string(_ names: String...) -> String? {
            for name in names { if let text = object[name] as? String { return text } }
            return nil
        }
        func int(_ names: String...) -> Int? {
            for name in names {
                if let number = object[name] as? Int { return number }
                if let number = object[name] as? Double { return Int(number) }
                if let text = object[name] as? String, let number = Int(text) { return number }
            }
            return nil
        }
        let direction = string("direction").flatMap { Direction(rawValue: $0.lowercased()) }

        switch kind {
        case .focusSlot:
            return .focusSlot(clamp(int("slot") ?? 1, slotRange))
        case .focusPane:
            return .focusPane(direction ?? .right)
        case .scroll:
            return .scroll(direction ?? .down,
                           amount: clamp(int("amount", "lines") ?? defaultScrollAmount, scrollAmountRange))
        case .sendKeysToAgent:
            return .sendKeysToAgent(string("keys", "text") ?? "")
        case .herdrCommand:
            return .herdrCommand(string("command", "command_id", "id") ?? "")
        case .insertText:
            return .insertText(string("text") ?? legacyText ?? "")
        case .submitPrompt:
            return .submitPrompt(string("text") ?? legacyText ?? "")
        case .typeText:
            return .typeText(string("text") ?? legacyText ?? "")
        case .keyboardShortcut:
            return .keyboardShortcut(string("keys", "shortcut") ?? "")
        case .mediaKey:
            let name = string("key", "media")?.lowercased() ?? ""
            let key = MediaKey(rawValue: name)
                ?? MediaKey.allCases.first { Kind.normalise($0.rawValue) == Kind.normalise(name) }
            return .mediaKey(key ?? .playPause)
        case .openURL:
            return .openURL(string("url", "target", "path", "app") ?? "")
        case .shellCommand:
            return .shellCommand(string("command", "cmd") ?? "")
        default:
            return kind.defaultAction
        }
    }
}

extension InputAction: Identifiable {
    /// Stable for a given action and its parameters.
    public var id: String {
        if let value = configValue as? String { return value }
        guard let data = try? JSONSerialization.data(withJSONObject: configValue, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8)
        else { return kind.rawValue }
        return text
    }
}

// MARK: - Codable

/// Codable in the same shape as `config.json`, so a typed decoder and the
/// hand-written file agree.
extension InputAction: Codable {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            guard let action = InputAction.parse(configValue: name) else {
                throw DecodingError.dataCorruptedError(
                    in: single, debugDescription: "Unknown action \(name)")
            }
            self = action
            return
        }
        let container = try decoder.container(keyedBy: AnyKey.self)
        var object: [String: Any] = [:]
        for key in container.allKeys {
            if let text = try? container.decode(String.self, forKey: key) {
                object[key.stringValue] = text
            } else if let number = try? container.decode(Int.self, forKey: key) {
                object[key.stringValue] = number
            } else if let number = try? container.decode(Double.self, forKey: key) {
                object[key.stringValue] = number
            }
        }
        guard let action = InputAction.parse(configValue: object) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Unknown action object"))
        }
        self = action
    }

    public func encode(to encoder: Encoder) throws {
        if let name = configValue as? String {
            var single = encoder.singleValueContainer()
            try single.encode(name)
            return
        }
        guard let object = configValue as? [String: Any] else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in object {
            if let number = value as? Int {
                try container.encode(number, forKey: AnyKey(stringValue: key))
            } else if let text = value as? String {
                try container.encode(text, forKey: AnyKey(stringValue: key))
            }
        }
    }
}
