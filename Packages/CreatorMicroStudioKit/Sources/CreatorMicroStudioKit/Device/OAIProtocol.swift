import Foundation
import SwiftUI

/// The Work Louder vendor lighting API, recovered from
/// `@worklouder/device-kit-oai` (which ships inside the Codex desktop app —
/// not the Input configurator, whose SDK only knows `lights.preview`).
///
/// Two details are easy to get wrong, and both fail *silently* because the
/// firmware answers `{"ok":1}` to any payload it is handed:
///
///   1. Field names are abbreviated on the wire: `c b e s m`, not the full
///      names `lights.preview` uses.
///   2. `effect` is an integer here, not one of the effect strings.
public enum OAI {

    /// Per-key lighting. Params are a bare ARRAY, one entry per key.
    public static let methodThreads = "v.oai.thstatus"
    /// Zone lighting: the keys plate and the ambient ring.
    public static let methodRGBConfig = "v.oai.rgbcfg"
    /// The documented two-surface call, kept for comparison.
    public static let methodPreview = "lights.preview"

    /// Device → host notification channels. These are pushed by the device and
    /// are not callable methods; calling them returns "Method not found".
    public static let notifyHID = "v.oai.hid"
    public static let notifyJoystick = "v.oai.rad"

    public enum Effect: Int, CaseIterable, Identifiable, Sendable {
        case off = 0
        case solid = 1
        case snake = 2
        case rainbow = 3
        case breath = 4
        case gradient = 5
        case shallowBreath = 6

        public var id: Int { rawValue }

        public var label: String {
            switch self {
            case .off: return "Off"
            case .solid: return "Solid"
            case .snake: return "Snake"
            case .rainbow: return "Rainbow"
            case .breath: return "Breathing"
            case .gradient: return "Gradient"
            case .shallowBreath: return "Shallow breath"
            }
        }
    }

    /// One key. `id` is a key index: 0-based, row-major over the pad's
    /// [2, 4, 4, 3] matrix, so the top two rows are ids 0...5.
    public struct Thread: Equatable, Sendable {
        public var id: Int
        public var color: Int?
        public var brightness: Double?
        public var effect: Effect?
        public var speed: Double?
        public var syncKeys: Bool?
        public var syncAmbient: Bool?

        public init(
            id: Int,
            color: Int? = nil,
            brightness: Double? = nil,
            effect: Effect? = nil,
            speed: Double? = nil,
            syncKeys: Bool? = nil,
            syncAmbient: Bool? = nil
        ) {
            self.id = id
            self.color = color
            self.brightness = brightness
            self.effect = effect
            self.speed = speed
            self.syncKeys = syncKeys
            self.syncAmbient = syncAmbient
        }

        /// Only `id` is required; omitted fields leave that aspect unchanged.
        public var wire: [String: Any] {
            var out: [String: Any] = ["id": id]
            if let color { out["c"] = color }
            if let brightness { out["b"] = brightness }
            if let effect { out["e"] = effect.rawValue }
            if let speed { out["s"] = speed }
            if let syncKeys { out["sk"] = syncKeys ? 1 : 0 }
            if let syncAmbient { out["sa"] = syncAmbient ? 1 : 0 }
            return out
        }
    }

    /// One zone.
    public struct Zone: Equatable, Sendable {
        public var effect: Effect = .solid
        public var brightness: Double = 1
        public var speed: Double = 0.5
        public var magic: Double = 1
        public var color: Int = 0

        public init(
            effect: Effect = .solid,
            brightness: Double = 1,
            speed: Double = 0.5,
            magic: Double = 1,
            color: Int = 0
        ) {
            self.effect = effect
            self.brightness = brightness
            self.speed = speed
            self.magic = magic
            self.color = color
        }

        public var wire: [String: Any] {
            ["e": effect.rawValue, "b": brightness, "s": speed, "m": magic, "c": color]
        }

        public static let dark = Zone(effect: .off, brightness: 0, speed: 0.5, magic: 1, color: 0)
    }

    /// An AG key reports itself by name, "AG00".."AG19"; the number is the key
    /// index, the same one used as a thread id for lighting.
    public static func agIndex(_ name: String?) -> Int? {
        guard let name, name.hasPrefix("AG") else { return nil }
        return Int(name.dropFirst(2))
    }

    public static func threadsParams(_ threads: [Thread]) -> [[String: Any]] {
        threads.map(\.wire)
    }

    public static func rgbConfigParams(keys: Zone, ambient: Zone) -> [String: Any] {
        ["keys": keys.wire, "ambient": ambient.wire]
    }
}

// MARK: - Pad geometry

/// The pad's physical key rows, matching the firmware's [2, 4, 4, 3] matrix.
/// Key index runs row-major from 0; the default agent layout uses keycaps 0...5.
public enum Pad {
    /// Visual positions in the physical device drawing. The dial and joystick
    /// flank the two top keycaps; the bottom-left circle is a case mark, not a key.
    public enum DisplayCell: Hashable, Identifiable {
        case dial
        case key(Int)
        case joystick
        case caseMark

        public var id: String {
            switch self {
            case .dial: return "dial"
            case .key(let index): return "key-\(index)"
            case .joystick: return "joystick"
            case .caseMark: return "case-mark"
            }
        }
    }

    public static let rows: [[Int]] = [
        [0, 1],
        [2, 3, 4, 5],
        [6, 7, 8, 9],
        [10, 11, 12],
    ]
    public static let keyCount = 13
    /// The firmware's keycode table goes to AG19, so clear the whole id space
    /// when turning everything off, not just the visible keys.
    public static let maxThreadID = 19
    /// Legacy/default agent layout. Runtime assignments come from `KeyBindings`.
    /// Slot N lights and answers to `agentKeyIDs[N]`, in READING order:
    /// left to right, top to bottom as you look at the pad. The firmware's top
    /// row is wired right to left — key 0 is the top-RIGHT key — so reading
    /// order starts 1, 0. The other rows run left to right in index order.
    public static let agentKeyIDs = [1, 0, 2, 3, 4, 5]
    /// The rows as you look at the pad, for on-screen mirrors. `rows` stays in
    /// firmware order because the keymap file is addressed that way.
    public static let displayRows: [[Int]] = [
        [1, 0],
        [2, 3, 4, 5],
        [6, 7, 8, 9],
        [10, 11, 12],
    ]
    /// Maker-accurate physical surface layout, including controls outside the
    /// key matrix and the non-key circular case mark in the bottom-left slot.
    public static let physicalDisplayRows: [[DisplayCell]] = [
        [.dial, .key(1), .key(0), .joystick],
        [.key(2), .key(3), .key(4), .key(5)],
        [.key(6), .key(7), .key(8), .key(9)],
        [.caseMark, .key(10), .key(11), .key(12)],
    ]

    /// The default-layout slot a key answers for, or nil for other keycaps.
    /// Use `KeyBindings.agentSlot(for:)` for the active configured layout.
    @available(*, deprecated, message: "Default layout only; use KeyBindings.agentSlot(for:) for configured layouts.")
    public static func agentSlot(for key: Int) -> Int? {
        agentKeyIDs.firstIndex(of: key)
    }
    /// Cycles the tabs of the focused tab's workspace in Herdr. Second key of
    /// row 3.
    public static let tabCycleKeyID = 7
    /// The keycaps — the inputs with LEDs, and so the only ids lighting ever
    /// paints. Every input, keys and controls, takes a host-side action; see
    /// `configurableInputIDs`. The hardware keymap stays unchanged either way.
    public static let configurableActionKeyIDs = Array(0..<keyCount)
    /// The paired voice keys on the bottom row. They are two separate physical
    /// keycaps with one default action, and can still be configured separately.
    public static let voiceKeyIDs = [10, 11]
    /// Text-macro keys: inject a configured string into the focused agent's
    /// prompt. Key 9 is the last key of row 3; key 12 is the bottom-right
    /// corner.
    public static let macroKeyIDs = [9, 12]
    /// The keys bound to `KV_OAI_AG*`, and so the only ones that can be lit.
    /// With the macro and voice keys this is now the whole pad.
    public static let boundKeyIDs =
        agentKeyIDs + [6, tabCycleKeyID, 8] + voiceKeyIDs + macroKeyIDs

    // MARK: Dial and joystick

    /// The dial and joystick emit keycodes like the keys do, so binding them
    /// to the AG codes above 12 turns rotations, the dial push (`dialPushID`,
    /// 19) and deflections into the same `v.oai.hid` reports. These IDs never
    /// light — nothing is under them.
    public static let dialUpID = 13     // encoder, clockwise detent
    public static let dialDownID = 14   // encoder, counter-clockwise detent
    /// The joystick's four cardinal sectors, named by the angle fraction at
    /// their centre in the radial map (0 = east, counter-clockwise).
    public static let joyNorthID = 15   // sector centred on 0.25
    public static let joyWestID = 16    // sector centred on 0.5
    public static let joySouthID = 17   // sector centred on 0.75
    public static let joyEastID = 18    // sector centred on 0.0

    public enum JoystickDirection: Sendable {
        case north, south, east, west

        public init?(keyID: Int) {
            switch keyID {
            case Pad.joyNorthID: self = .north
            case Pad.joySouthID: self = .south
            case Pad.joyEastID: self = .east
            case Pad.joyWestID: self = .west
            default: return nil
            }
        }
    }

    public static func row(of key: Int) -> Int? {
        rows.firstIndex { $0.contains(key) }
    }

    /// Where a key sits in `rows`, which is the shape the device keymap uses.
    public static func position(of key: Int) -> (row: Int, column: Int)? {
        for (row, keys) in rows.enumerated() {
            if let column = keys.firstIndex(of: key) { return (row, column) }
        }
        return nil
    }
}

// MARK: - Colour helpers

extension Color {
    /// Packed 0xRRGGBB, which is how colours go on the wire.
    public var packedRGB: Int {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }

    public init(packedRGB: Int) {
        self.init(
            .sRGB,
            red: Double((packedRGB >> 16) & 0xFF) / 255,
            green: Double((packedRGB >> 8) & 0xFF) / 255,
            blue: Double(packedRGB & 0xFF) / 255
        )
    }
}

public func hexString(_ packed: Int) -> String {
    String(format: "#%06X", packed & 0xFFFFFF)
}

/// `"#RRGGBB"` / `"#RGB"` → packed int. Mirrors `toColorInt` in lib/oai.js.
public func packedRGB(fromHex hex: String) -> Int? {
    var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard text.count == 6 else { return nil }
    return Int(text, radix: 16)
}
