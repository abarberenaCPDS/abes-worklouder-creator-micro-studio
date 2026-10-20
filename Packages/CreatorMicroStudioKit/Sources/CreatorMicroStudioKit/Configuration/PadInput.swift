import Foundation

// MARK: - Configurable inputs

/// Every physical control that reports a `v.oai.hid` event and so can carry a
/// host-side action. An input's id is its AG thread id: keys are 0...12, the
/// dial is 13 (right), 14 (left) and 19 (push), the joystick's cardinal
/// sectors are 15...18.
///
/// Joystick diagonals and the joystick's centre press are deliberately absent:
/// the firmware's AG table stops at AG19, which the dial push now uses, and the
/// keymap schema has no slot for a centre press at all.
extension Pad {

    /// The dial's click, bound to `KV_OAI_AG19` — the last free AG id.
    public static let dialPushID = 19

    /// Every input id an action can be bound to, keys and controls alike.
    /// `configurableActionKeyIDs` stays the keys-with-LEDs subset.
    public static let configurableInputIDs = Array(0...maxThreadID)

    public enum InputGroup: String, CaseIterable, Identifiable, Sendable {
        case keys
        case dial
        case joystick

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .keys: return "Keys"
            case .dial: return "Dial"
            case .joystick: return "Joystick"
            }
        }

        public var symbol: String {
            switch self {
            case .keys: return "square.grid.3x3"
            case .dial: return "dial.medium"
            case .joystick: return "dpad"
            }
        }

        /// This group's inputs, in the order a list should show them.
        public var inputs: [Input] { Pad.inputs.filter { $0.group == self } }
    }

    /// One configurable physical input.
    public struct Input: Hashable, Identifiable, Sendable {
        /// The AG thread id, which is also the config key (written as a
        /// numeric string).
        public let id: Int
        public let group: InputGroup
        /// "Key 3", "Dial right", "Joystick up".
        public let name: String
        /// Compact label for tight layouts: "3", "Dial →", "Joy ↑".
        public let shortName: String
        /// Readable config key accepted alongside the numeric id, for example
        /// `"dial-push"`. Keys have none.
        public let configAlias: String?
        /// SF Symbol name.
        public let symbol: String

        /// Only keycaps have LEDs; controls never take a lighting thread.
        public var hasLight: Bool { group == .keys }
        /// Legacy/default-layout metadata for existing UI. Runtime slot
        /// resolution uses the active `KeyBindings` layout instead.
        @available(*, deprecated, message: "Default layout only; use KeyBindings.agentSlot(for:) for configured layouts.")
        public var agentSlot: Int? { Pad.agentKeyIDs.firstIndex(of: id) }
        public var joystickDirection: JoystickDirection? { JoystickDirection(keyID: id) }
    }

    /// All 20 inputs: keys 0...12, then the dial (right, left, push), then the
    /// joystick (up, down, left, right).
    public static let inputs: [Input] = {
        var all = (0..<keyCount).map { key in
            Input(id: key, group: .keys, name: "Key \(key)", shortName: "\(key)",
                  configAlias: nil, symbol: "square")
        }
        all += [
            Input(id: dialUpID, group: .dial, name: "Dial right", shortName: "Dial →",
                  configAlias: "dial-right", symbol: "arrow.clockwise"),
            Input(id: dialDownID, group: .dial, name: "Dial left", shortName: "Dial ←",
                  configAlias: "dial-left", symbol: "arrow.counterclockwise"),
            Input(id: dialPushID, group: .dial, name: "Dial push", shortName: "Dial ●",
                  configAlias: "dial-push", symbol: "smallcircle.filled.circle"),
            Input(id: joyNorthID, group: .joystick, name: "Joystick up", shortName: "Joy ↑",
                  configAlias: "joy-up", symbol: "arrow.up"),
            Input(id: joySouthID, group: .joystick, name: "Joystick down", shortName: "Joy ↓",
                  configAlias: "joy-down", symbol: "arrow.down"),
            Input(id: joyWestID, group: .joystick, name: "Joystick left", shortName: "Joy ←",
                  configAlias: "joy-left", symbol: "arrow.left"),
            Input(id: joyEastID, group: .joystick, name: "Joystick right", shortName: "Joy →",
                  configAlias: "joy-right", symbol: "arrow.right"),
        ]
        return all
    }()

    public static func input(_ id: Int) -> Input? {
        inputs.first { $0.id == id }
    }

    /// Older names some hand-written configs may use, mapped to the same ids.
    static let extraInputAliases: [String: Int] = [
        "dial-cw": dialUpID, "dial-up": dialUpID, "dial-clockwise": dialUpID,
        "dial-ccw": dialDownID, "dial-down": dialDownID, "dial-counter-clockwise": dialDownID,
        "dial-press": dialPushID, "dial-click": dialPushID,
        "joy-north": joyNorthID, "joystick-up": joyNorthID,
        "joy-west": joyWestID, "joystick-left": joyWestID,
        "joy-south": joySouthID, "joystick-down": joySouthID,
        "joy-east": joyEastID, "joystick-right": joyEastID,
    ]

    /// The input ids a config key names: a numeric id, a readable alias such
    /// as `"dial-push"`, or `"10+11"` for both bottom-row voice keys. Unknown
    /// or out-of-range names give an empty list.
    public static func inputIDs(forConfigKey key: String) -> [Int] {
        let name = key.trimmingCharacters(in: .whitespaces).lowercased()
        if name == "10+11" { return voiceKeyIDs }
        if let id = Int(name) {
            return configurableInputIDs.contains(id) ? [id] : []
        }
        if let input = inputs.first(where: { $0.configAlias == name }) { return [input.id] }
        if let id = extraInputAliases[name] { return [id] }
        return []
    }
}

extension Pad.JoystickDirection: CaseIterable {
    public static var allCases: [Pad.JoystickDirection] { [.north, .south, .west, .east] }

    /// The input id of this sector.
    public var inputID: Int {
        switch self {
        case .north: return Pad.joyNorthID
        case .south: return Pad.joySouthID
        case .east: return Pad.joyEastID
        case .west: return Pad.joyWestID
        }
    }
}
