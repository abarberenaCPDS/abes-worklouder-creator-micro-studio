import Foundation
import SwiftUI

/// Maps a set of Herdr agents to device lighting.
///
/// Keys are individually addressable, so each agent gets its own key. The
/// underglow keeps a worst-state-wins aggregate, which is the part you can read
/// from across the room without counting keys.
///
/// Kept in step with `lib/status.js`; the defaults below are that file's.
public struct BridgeConfig: Sendable {
    /// Highest priority first: the first state present across all agents wins
    /// the underglow.
    public var priority: [String] = ["blocked", "working", "unknown", "idle", "done"]
    public var colors: [String: Int] = [
        "blocked": 0xFF2D2D,
        "working": 0xFFA000,
        // Herdr reports "done" for an agent that has finished and that you
        // have not looked at yet, and "idle" once it is focused. That is a
        // real difference - one is waiting to be read, the other is just
        // quiet - so give them different colours.
        "done": 0x00B0FF,
        "idle": 0x00C853,
        "unknown": 0x00C853,
    ]
    public var effects: [String: OAI.Effect] = [
        "blocked": .breath,
        "working": .solid,
        "idle": .solid,
        "done": .solid,
        "unknown": .solid,
    ]
    /// Herdr navigation keys (tabs, workspaces, panes) are not agents, so they
    /// get a colour of their own rather than borrowing a status colour.
    public var tabCycleColor: Int = 0x00BFA5
    /// The voice key: white at rest, recording-red while a take is open.
    public var voiceColor: Int = 0xECEFF1
    public var voiceActiveColor: Int = 0xFF3B30
    /// Text-macro keys: a quiet steel blue — bound, but not status-bearing.
    public var macroColor: Int = 0x90A4AE
    /// A key that returns focus to Herdr's currently selected agent, or to a
    /// fixed slot.
    public var focusAgentColor: Int = 0x4C9AFF
    /// Model and effort actions.
    public var tuneColor: Int = 0xEA80FC
    /// Synthesised system input: scroll, shortcuts, media keys, typing.
    public var systemColor: Int = 0xFFEB3B
    /// Opening things and running shell commands.
    public var launchColor: Int = 0xFF6E40
    public var brightness: Double = 1
    public var speed: Double = 0.5
    /// Paint the key-backlight ZONE with the aggregate status when the user's
    /// backlight preference is off. Off by default: keys are painted per-agent
    /// instead, and a zone colour would only compete with them.
    public var driveBacklight = false
    /// The user's saved lighting. `apply(_:)` keeps the status tables above
    /// in step with it; the zone and per-key looks are read from here.
    public private(set) var lighting = LightingPreferences()
    /// Bind the keys this app drives to `KV_OAI_AG*` on startup. Required for
    /// per-key colour to work at all.
    public var manageKeymap = true
    public var pollInterval: TimeInterval = 2.5
    public var debounce: TimeInterval = 0.1

    public init() {}

    /// The built-in config with the user's lighting merged in.
    public init(lighting: LightingPreferences) {
        self.init()
        apply(lighting)
    }

    /// Takes the status colours, effects, global brightness and speed from
    /// the preferences, and keeps them for the zones and per-key looks.
    public mutating func apply(_ prefs: LightingPreferences) {
        lighting = prefs
        brightness = prefs.brightness
        speed = prefs.speed
        for (state, look) in prefs.status {
            colors[state] = look.color
            effects[state] = look.effect
        }
        if prefs.status["unknown"] == nil {
            let idle = prefs.look(forStatus: "idle")
            colors["unknown"] = idle.color
            effects["unknown"] = idle.effect
        }
    }

    public func color(for state: String) -> Int { colors[state] ?? 0xFFFFFF }
    public func effect(for state: String) -> OAI.Effect { effects[state] ?? .solid }
    /// Global brightness times the state's own, when the preferences set one.
    public func brightness(for state: String) -> Double {
        brightness * (lighting.status[state]?.brightness ?? 1)
    }
    public func speed(for state: String) -> Double {
        lighting.status[state]?.speed ?? speed
    }
    /// The saved at-rest look for a key, as a thread, or nil.
    public func keyLook(for key: Int) -> OAI.Thread? {
        lighting.keys[key]?.thread(id: key, brightness: brightness, speed: speed)
    }
}

/// The app-side states that light action keys more brightly than at rest.
public struct ActionLightState: Equatable, Sendable {
    public var voiceActive: Bool

    public init(voiceActive: Bool = false) {
        self.voiceActive = voiceActive
    }
}

public enum StatusMapper {

    /// The winning state across all agents, or nil when none are running.
    public static func aggregate(_ agents: [HerdrAgent], _ cfg: BridgeConfig = BridgeConfig()) -> String? {
        guard !agents.isEmpty else { return nil }
        let present = Set(agents.map(\.status))
        for state in cfg.priority where present.contains(state) { return state }
        return "unknown"
    }

    /// One thread entry per agent key: agent slot N takes `Pad.agentKeyIDs[N]`
    /// — reading order on the pad — and unused keys go dark. Always returns
    /// exactly `Pad.agentKeyIDs.count` entries, so a vanished agent actively
    /// clears its key rather than leaving it stale.
    public static func threads(
        for agents: [HerdrAgent],
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> [OAI.Thread] {
        Pad.agentKeyIDs.enumerated().map { slot, id in
            guard slot < agents.count else {
                // An empty slot shows the key's saved look, if it has one.
                return cfg.keyLook(for: id) ?? OAI.Thread(id: id, brightness: 0, effect: .off)
            }
            let state = agents[slot].status
            return OAI.Thread(
                id: id,
                color: cfg.color(for: state),
                brightness: cfg.brightness(for: state),
                effect: cfg.effect(for: state),
                speed: cfg.speed(for: state)
            )
        }
    }

    /// The light for a key's action, or nil for an agent slot key that is
    /// showing its agent (`threads(for:)` paints those).
    ///
    /// Active states — a voice take recording — always win.
    /// Otherwise a saved per-key look wins, and otherwise the action's
    /// category colour, dimmed so a bound key reads as bound without
    /// competing with agent status. Inputs without LEDs get nil.
    public static func actionThread(
        for action: InputAction,
        key: Int,
        state: ActionLightState = ActionLightState(),
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread? {
        guard Pad.configurableActionKeyIDs.contains(key) else { return nil }
        switch action {
        case .voice where state.voiceActive:
            return voiceThread(id: key, active: true, cfg)
        case .focusAgent where Pad.agentSlot(for: key) != nil:
            return nil
        default:
            break
        }
        if let look = cfg.keyLook(for: key) { return look }

        switch action {
        case .none:
            return OAI.Thread(id: key, brightness: 0, effect: .off)
        case .voice:
            return voiceThread(id: key, active: false, cfg)
        case .focusAgent, .focusSlot:
            return focusAgentThread(id: key, cfg)
        case .insertText(let text), .submitPrompt(let text):
            // Nothing to send reads as unbound.
            guard !text.isEmpty else { return OAI.Thread(id: key, brightness: 0, effect: .off) }
            return macroThread(id: key, cfg)
        default:
            break
        }
        let color: Int
        switch action.category {
        case .herdr: color = cfg.tabCycleColor
        case .tune: color = cfg.tuneColor
        case .system: color = cfg.systemColor
        case .launch: color = cfg.launchColor
        case .prompts: color = cfg.macroColor
        case .general: return OAI.Thread(id: key, brightness: 0, effect: .off)
        }
        return OAI.Thread(id: key, color: color, brightness: cfg.brightness * 0.3,
                          effect: .solid, speed: cfg.speed)
    }

    /// The tab-cycle key's thread. Dimly lit whenever the bridge runs:
    /// binding it to an AG keycode took away the keystroke it used to send,
    /// so a bound-but-dark key would just read as broken.
    public static func tabCycleThread(
        _ cfg: BridgeConfig = BridgeConfig(),
        id: Int = Pad.tabCycleKeyID
    ) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: cfg.tabCycleColor,
            brightness: cfg.brightness * 0.3,
            effect: .solid,
            speed: cfg.speed
        )
    }

    /// One of the paired voice keys. The callers paint both physical keycaps
    /// identically so the shared action reads as one state. Dim white at rest;
    /// breathing red while a Claude voice take is open.
    public static func voiceThread(
        id: Int,
        active: Bool,
        _ cfg: BridgeConfig = BridgeConfig()
    ) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: active ? cfg.voiceActiveColor : cfg.voiceColor,
            brightness: active ? cfg.brightness : cfg.brightness * 0.25,
            effect: active ? .breath : .solid,
            speed: cfg.speed
        )
    }

    /// A text-macro key's thread: dimly lit so it reads as bound, in a colour
    /// that stays out of the status conversation.
    public static func macroThread(id: Int, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: cfg.macroColor,
            brightness: cfg.brightness * 0.25,
            effect: .solid,
            speed: cfg.speed
        )
    }

    /// Focus-agent actions on keys outside the six agent slots get a quiet
    /// blue light. The six dedicated agent keys keep their live status colors.
    public static func focusAgentThread(id: Int, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Thread {
        OAI.Thread(
            id: id,
            color: cfg.focusAgentColor,
            brightness: cfg.brightness * 0.25,
            effect: .solid,
            speed: cfg.speed
        )
    }

    /// The status zone for an aggregate state, or nil to switch it off.
    public static func zone(for state: String?, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Zone? {
        guard let state else { return nil }
        return OAI.Zone(
            effect: cfg.effect(for: state),
            brightness: cfg.brightness(for: state),
            speed: cfg.speed(for: state),
            magic: 1,
            color: cfg.color(for: state)
        )
    }

    /// What the underglow shows, honouring the saved mode. Custom and off do
    /// not depend on Herdr at all, so they paint even while it is down.
    public static func ambientZone(for state: String?, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Zone {
        switch cfg.lighting.underglow.mode {
        case .status: return zone(for: state, cfg) ?? .dark
        case .custom: return cfg.lighting.underglow.look.zone(brightness: cfg.brightness, speed: cfg.speed)
        case .off: return .dark
        }
    }

    /// What the keys-plate zone shows, honouring the saved mode.
    public static func backlightZone(for state: String?, _ cfg: BridgeConfig = BridgeConfig()) -> OAI.Zone {
        switch cfg.lighting.backlight.mode {
        case .custom: return cfg.lighting.backlight.look.zone(brightness: cfg.brightness, speed: cfg.speed)
        case .off: return cfg.driveBacklight ? (zone(for: state, cfg) ?? .dark) : .dark
        }
    }
}
