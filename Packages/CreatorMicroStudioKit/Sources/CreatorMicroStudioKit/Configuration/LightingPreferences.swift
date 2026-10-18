import Foundation

/// Studio-owned lighting, persisted in `config.json` under `"lighting"`.
///
/// The Inspector paints the pad live and forgets; this is what the bridge
/// paints and keeps painting. Host-side only — none of it goes into the device
/// keymap or flash.
///
///     "lighting": {
///       "brightness": 1.0,
///       "speed": 0.5,
///       "status": {"blocked": {"c": "#FF2D2D", "e": "breath"}, "working": {"c": "#FFA000"}},
///       "underglow": {"mode": "status", "c": "#00C853", "e": "rainbow", "b": 1, "s": 0.5},
///       "backlight": {"mode": "off", "c": "#FFA000", "e": "solid", "b": 0.3, "s": 0.5},
///       "keys": {"7": {"c": "#FFA000", "e": "solid", "b": 0.6, "s": 0.5}}
///     }
///
/// Colours are `"#RRGGBB"` (or a packed int), effects a name (`"breath"`) or
/// the wire int. Anything missing or malformed falls back to its default, field
/// by field, so one typo never blanks the pad.
public struct LightingPreferences: Equatable, Sendable {

    /// One colour/effect/brightness/speed. `brightness` and `speed` are nil
    /// when the file leaves them out: brightness then means full (before the
    /// global multiplier) and speed means the global speed.
    public struct Look: Equatable, Hashable, Sendable {
        public var color: Int
        public var effect: OAI.Effect
        public var brightness: Double?
        public var speed: Double?

        public init(color: Int, effect: OAI.Effect = .solid, brightness: Double? = nil, speed: Double? = nil) {
            self.color = color & 0xFFFFFF
            self.effect = effect
            self.brightness = brightness.map(LightingPreferences.unit)
            self.speed = speed.map(LightingPreferences.unit)
        }

        /// The thread that paints this look on key `id`.
        public func thread(id: Int, brightness global: Double, speed defaultSpeed: Double) -> OAI.Thread {
            OAI.Thread(
                id: id,
                color: color,
                brightness: global * (brightness ?? 1),
                effect: effect,
                speed: speed ?? defaultSpeed
            )
        }

        /// The zone that paints this look.
        public func zone(brightness global: Double, speed defaultSpeed: Double) -> OAI.Zone {
            OAI.Zone(
                effect: effect,
                brightness: global * (brightness ?? 1),
                speed: speed ?? defaultSpeed,
                magic: 1,
                color: color
            )
        }

        var jsonObject: [String: Any] {
            var out: [String: Any] = ["c": hexString(color), "e": effect.configName]
            if let brightness { out["b"] = brightness }
            if let speed { out["s"] = speed }
            return out
        }

        /// Fields present in `json` replace this look's.
        func merged(with json: Any?) -> Look {
            guard let json = json as? [String: Any] else { return self }
            var next = self
            if let color = LightingPreferences.color(json["c"] ?? json["color"]) { next.color = color }
            if let effect = OAI.Effect(configValue: json["e"] ?? json["effect"]) { next.effect = effect }
            if let value = LightingPreferences.number(json["b"] ?? json["brightness"]) {
                next.brightness = LightingPreferences.unit(value)
            }
            if let value = LightingPreferences.number(json["s"] ?? json["speed"]) {
                next.speed = LightingPreferences.unit(value)
            }
            return next
        }
    }

    public enum UnderglowMode: String, CaseIterable, Identifiable, Sendable {
        /// Worst agent state wins, in the status colours — the default.
        case status
        /// A fixed look, whatever the agents are doing.
        case custom
        case off

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .status: return "Agent status"
            case .custom: return "Custom"
            case .off: return "Off"
            }
        }
    }

    public enum BacklightMode: String, CaseIterable, Identifiable, Sendable {
        /// Keys are painted per key only — the default.
        case off
        /// A fixed keys-plate zone under the per-key colours.
        case custom

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .off: return "Off"
            case .custom: return "Custom"
            }
        }
    }

    public struct Underglow: Equatable, Sendable {
        public var mode: UnderglowMode
        /// Used in `.custom` mode.
        public var look: Look
        public init(mode: UnderglowMode, look: Look) { self.mode = mode; self.look = look }
    }

    public struct Backlight: Equatable, Sendable {
        public var mode: BacklightMode
        /// Used in `.custom` mode.
        public var look: Look
        public init(mode: BacklightMode, look: Look) { self.mode = mode; self.look = look }
    }

    /// The states the status table can set. `"unknown"` follows `"idle"`
    /// unless it is set explicitly.
    public static let statusStates = ["blocked", "working", "done", "idle"]

    /// Multiplies every thread and zone, 0...1.
    public var brightness: Double
    /// The effect speed for looks that do not set their own, 0...1.
    public var speed: Double
    /// Agent-state looks, keyed by Herdr status.
    public var status: [String: Look]
    public var underglow: Underglow
    public var backlight: Backlight
    /// At-rest looks for keys that are not showing an agent, by key id
    /// (0...12). An agent slot key still showing its agent ignores its entry
    /// except while that slot is empty. Panel-open and recording states still
    /// override.
    public var keys: [Int: Look]

    public static let defaultStatus: [String: Look] = [
        "blocked": Look(color: 0xFF2D2D, effect: .breath),
        "working": Look(color: 0xFFA000, effect: .solid),
        "done": Look(color: 0x00B0FF, effect: .solid),
        "idle": Look(color: 0x00C853, effect: .solid),
    ]
    public static let defaultUnderglow = Underglow(
        mode: .status, look: Look(color: 0x00C853, effect: .rainbow, brightness: 1, speed: 0.5))
    public static let defaultBacklight = Backlight(
        mode: .off, look: Look(color: 0xFFA000, effect: .solid, brightness: 0.3, speed: 0.5))

    public init(
        brightness: Double = 1,
        speed: Double = 0.5,
        status: [String: Look] = LightingPreferences.defaultStatus,
        underglow: Underglow = LightingPreferences.defaultUnderglow,
        backlight: Backlight = LightingPreferences.defaultBacklight,
        keys: [Int: Look] = [:]
    ) {
        self.brightness = LightingPreferences.unit(brightness)
        self.speed = LightingPreferences.unit(speed)
        self.status = status
        self.underglow = underglow
        self.backlight = backlight
        self.keys = keys.filter { Pad.configurableActionKeyIDs.contains($0.key) }
    }

    public static let defaults = LightingPreferences()

    /// The look for a Herdr status, with `"unknown"` and unrecognised states
    /// falling back to idle.
    public func look(forStatus state: String) -> Look {
        status[state] ?? status["idle"] ?? LightingPreferences.defaultStatus["idle"]!
    }

    // MARK: - Parsing

    /// Reads the `"lighting"` object out of a whole `config.json`.
    public static func parse(_ data: Data) -> LightingPreferences {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return LightingPreferences() }
        return parse(lighting: json["lighting"])
    }

    /// Reads a `"lighting"` value; anything unusable keeps its default.
    public static func parse(lighting value: Any?) -> LightingPreferences {
        var prefs = LightingPreferences()
        guard let json = value as? [String: Any] else { return prefs }

        if let value = number(json["brightness"]) { prefs.brightness = unit(value) }
        if let value = number(json["speed"]) { prefs.speed = unit(value) }

        if let table = json["status"] as? [String: Any] {
            // Fixed order: the known states first (so "idle" is final), then
            // the rest sorted, so a state that falls back to idle always
            // builds on the merged idle look whatever the dictionary order.
            let known = statusStates.filter { table[$0] != nil }
            let others = table.keys.filter { !statusStates.contains($0) }.sorted()
            for state in known + others {
                let base = prefs.status[state] ?? prefs.look(forStatus: "idle")
                prefs.status[state] = base.merged(with: table[state])
            }
        }

        if let entry = json["underglow"] as? [String: Any] {
            if let mode = (entry["mode"] as? String).flatMap({ UnderglowMode(rawValue: $0.lowercased()) }) {
                prefs.underglow.mode = mode
            }
            prefs.underglow.look = prefs.underglow.look.merged(with: entry)
        }
        if let entry = json["backlight"] as? [String: Any] {
            if let mode = (entry["mode"] as? String).flatMap({ BacklightMode(rawValue: $0.lowercased()) }) {
                prefs.backlight.mode = mode
            }
            prefs.backlight.look = prefs.backlight.look.merged(with: entry)
        }

        if let table = json["keys"] as? [String: Any] {
            // Same deterministic precedence as actions: specific ids win.
            for (key, entry) in KeyBindings.resolveInputMap(table)
            where Pad.configurableActionKeyIDs.contains(key) {
                // A per-key look needs a colour to mean anything.
                guard let object = entry as? [String: Any],
                      color(object["c"] ?? object["color"]) != nil
                else { continue }
                prefs.keys[key] = Look(color: 0, effect: .solid).merged(with: object)
            }
        }
        return prefs
    }

    /// The `"lighting"` value, fully spelled out.
    public var jsonObject: [String: Any] {
        var statusTable: [String: Any] = [:]
        for (state, look) in status { statusTable[state] = look.jsonObject }
        var underglowEntry = underglow.look.jsonObject
        underglowEntry["mode"] = underglow.mode.rawValue
        var backlightEntry = backlight.look.jsonObject
        backlightEntry["mode"] = backlight.mode.rawValue
        var keyTable: [String: Any] = [:]
        for (key, look) in keys { keyTable[String(key)] = look.jsonObject }
        var out: [String: Any] = [
            "brightness": brightness,
            "speed": speed,
            "status": statusTable,
            "underglow": underglowEntry,
            "backlight": backlightEntry,
        ]
        if !keyTable.isEmpty { out["keys"] = keyTable }
        return out
    }

    // MARK: - Storage

    public static func load(from store: StudioConfigStore = .standard) -> LightingPreferences {
        guard let data = store.readData() else { return LightingPreferences() }
        return parse(data)
    }

    /// Writes the whole `"lighting"` object, leaving the rest of the file be.
    public static func save(_ prefs: LightingPreferences, to store: StudioConfigStore = .standard) throws {
        try store.update { json in json["lighting"] = prefs.jsonObject }
    }

    /// Read-modify-write against what is on disk now, for small edits made
    /// outside the Studio's own editor — the Inspector's "Save to Studio".
    public static func update(
        in store: StudioConfigStore = .standard,
        _ body: (inout LightingPreferences) -> Void
    ) throws {
        try store.update { json in
            var prefs = parse(lighting: json["lighting"])
            body(&prefs)
            json["lighting"] = prefs.jsonObject
        }
    }

    /// Saves an editor's draft as a merge against what is on disk now: only
    /// the fields where `draft` differs from `baseline` (the prefs the draft
    /// was loaded from) are applied, so anything another writer — the
    /// standalone Inspector, a hand edit — changed in the meantime survives.
    /// Returns what was written.
    @discardableResult
    public static func save(
        _ draft: LightingPreferences,
        baseline: LightingPreferences,
        to store: StudioConfigStore = .standard
    ) throws -> LightingPreferences {
        var written = draft
        try store.update { json in
            let disk = parse(lighting: json["lighting"])
            written = draft.rebased(onto: disk, from: baseline)
            json["lighting"] = written.jsonObject
        }
        return written
    }

    /// `disk` with the edits that turn `baseline` into `self` applied on top.
    public func rebased(onto disk: LightingPreferences, from baseline: LightingPreferences) -> LightingPreferences {
        var out = disk
        if brightness != baseline.brightness { out.brightness = brightness }
        if speed != baseline.speed { out.speed = speed }
        for state in Set(status.keys).union(baseline.status.keys) where status[state] != baseline.status[state] {
            out.status[state] = status[state]
        }
        if underglow.mode != baseline.underglow.mode { out.underglow.mode = underglow.mode }
        if underglow.look != baseline.underglow.look { out.underglow.look = underglow.look }
        if backlight.mode != baseline.backlight.mode { out.backlight.mode = backlight.mode }
        if backlight.look != baseline.backlight.look { out.backlight.look = backlight.look }
        for key in Set(keys.keys).union(baseline.keys.keys) where keys[key] != baseline.keys[key] {
            out.keys[key] = keys[key]
        }
        return out
    }

    /// Back to the built-in look: removes `"lighting"` from the file.
    public static func reset(in store: StudioConfigStore = .standard) throws {
        try store.update { json in json.removeValue(forKey: "lighting") }
    }

    // MARK: - Value helpers

    static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func color(_ value: Any?) -> Int? {
        if let text = value as? String { return packedRGB(fromHex: text) }
        if let number = value as? Int, (0...0xFFFFFF).contains(number) { return number }
        return nil
    }
}

// MARK: - Effect names

extension OAI.Effect {
    /// The name used in `config.json`.
    public var configName: String {
        switch self {
        case .off: return "off"
        case .solid: return "solid"
        case .snake: return "snake"
        case .rainbow: return "rainbow"
        case .breath: return "breath"
        case .gradient: return "gradient"
        case .shallowBreath: return "shallow-breath"
        }
    }

    /// A name (`"breath"`, `"Breathing"`, `"shallow_breath"`) or the wire int.
    public init?(configValue value: Any?) {
        if let number = value as? Int {
            self.init(rawValue: number)
            return
        }
        guard let text = value as? String else { return nil }
        if let number = Int(text) {
            self.init(rawValue: number)
            return
        }
        let wanted = text.lowercased().filter(\.isLetter)
        guard let match = OAI.Effect.allCases.first(where: {
            $0.configName.filter(\.isLetter) == wanted || $0.label.lowercased().filter(\.isLetter) == wanted
        }) else { return nil }
        self = match
    }
}

// MARK: - Codable

/// Codable in the `config.json` shape, for anything that prefers typed coding.
extension LightingPreferences: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(JSONData.self).data
        let object = try? JSONSerialization.jsonObject(with: data)
        self = LightingPreferences.parse(lighting: object)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: .sortedKeys)
        try container.encode(JSONData(data: data))
    }

    /// Carries an arbitrary JSON subtree through `Codable`.
    private struct JSONData: Codable {
        let data: Data
        init(data: Data) { self.data = data }

        init(from decoder: Decoder) throws {
            data = try JSONSerialization.data(withJSONObject: try JSONValue(from: decoder).any,
                                              options: .fragmentsAllowed)
        }

        func encode(to encoder: Encoder) throws {
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            try JSONValue(any: object).encode(to: encoder)
        }
    }
}

/// A minimal JSON tree for bridging `Codable` and `JSONSerialization`.
enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(any: Any) {
        switch any {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else { self = .number(value.doubleValue) }
        case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
        case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
        default: self = .null
        }
    }

    var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.any)
        case .array(let value): return value.map(\.any)
        case .null: return NSNull()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
