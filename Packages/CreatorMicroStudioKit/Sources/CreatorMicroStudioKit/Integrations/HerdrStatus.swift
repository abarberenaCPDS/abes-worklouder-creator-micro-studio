import Foundation

/// What the bridge knows about its Herdr connection, for the Studio's Herdr
/// page. Published by `BridgeController.herdr`; updated on every refresh.
public struct HerdrStatus: Equatable, Sendable {

    public enum Reachability: Equatable, Sendable {
        /// Not asked yet — the bridge is off or has not refreshed.
        case unknown
        case connected
        /// The socket could not be opened: Herdr is not running, or the path
        /// is wrong.
        case unreachable(String)
        /// The socket answered badly: a timeout, a protocol or API error.
        case error(String)

        public var title: String {
            switch self {
            case .unknown: return "Not checked"
            case .connected: return "Connected"
            case .unreachable: return "Unreachable"
            case .error: return "Error"
            }
        }

        public var message: String? {
            switch self {
            case .unreachable(let message), .error(let message): return message
            case .unknown, .connected: return nil
            }
        }
    }

    public var socketPath: String
    public var socketSource: HerdrSocketSource
    public var reachability: Reachability
    /// From `ping`; nil until the first successful ping.
    public var version: String?
    public var protocolVersion: Int?
    /// When `agent.list` last succeeded.
    public var lastRefreshAt: Date?
    /// When the bridge last tried, successful or not.
    public var lastAttemptAt: Date?
    /// Whether the lifecycle event stream (panes appearing and going) is
    /// subscribed. Without it the pad only updates on the poll.
    public var lifecycleSubscribed: Bool
    /// Open per-pane status streams.
    public var statusStreamCount: Int
    /// The bridge's poll interval, for "refreshes every N s".
    public var pollInterval: TimeInterval
    public var workspaces: [HerdrWorkspace]
    public var tabs: [HerdrTab]

    public init(
        socketPath: String = HerdrClient.socketLocation().path,
        socketSource: HerdrSocketSource = HerdrClient.socketLocation().source,
        reachability: Reachability = .unknown,
        version: String? = nil,
        protocolVersion: Int? = nil,
        lastRefreshAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        lifecycleSubscribed: Bool = false,
        statusStreamCount: Int = 0,
        pollInterval: TimeInterval = 2.5,
        workspaces: [HerdrWorkspace] = [],
        tabs: [HerdrTab] = []
    ) {
        self.socketPath = socketPath
        self.socketSource = socketSource
        self.reachability = reachability
        self.version = version
        self.protocolVersion = protocolVersion
        self.lastRefreshAt = lastRefreshAt
        self.lastAttemptAt = lastAttemptAt
        self.lifecycleSubscribed = lifecycleSubscribed
        self.statusStreamCount = statusStreamCount
        self.pollInterval = pollInterval
        self.workspaces = workspaces
        self.tabs = tabs
    }

    public var isConnected: Bool { reachability == .connected }

    /// The last attempt, only when it failed: nil while Herdr answers, so a
    /// "Last attempt" row never shadows a successful refresh.
    public var lastFailedAttemptAt: Date? {
        guard let attempt = lastAttemptAt,
              reachability != .connected, reachability != .unknown
        else { return nil }
        return attempt
    }
    /// The error to show, if any.
    public var errorMessage: String? { reachability.message }

    public func workspace(id: String?) -> HerdrWorkspace? {
        guard let id else { return nil }
        return workspaces.first { $0.workspaceID == id }
    }

    public func tab(id: String?) -> HerdrTab? {
        guard let id else { return nil }
        return tabs.first { $0.tabID == id }
    }

    /// "workspace › tab" for an agent, using labels when Herdr has them.
    public func location(of agent: HerdrAgent) -> String? {
        let workspace = workspace(id: agent.workspaceID)?.displayLabel
        let tab = tab(id: agent.tabID)?.displayLabel
        switch (workspace, tab) {
        case let (workspace?, tab?): return "\(workspace) › \(tab)"
        case let (workspace?, nil): return workspace
        case let (nil, tab?): return tab
        default: return nil
        }
    }

    /// Maps a thrown error onto unreachable (could not connect) or error.
    public static func reachability(for error: Error) -> Reachability {
        if case HerdrError.cannotConnect = error {
            return .unreachable(error.localizedDescription)
        }
        return .error(error.localizedDescription)
    }
}

/// One input as the Herdr page shows it: what it does and, for agent keys,
/// which agent it reaches right now.
public struct HerdrInputMapping: Equatable, Sendable, Identifiable {
    public var input: Pad.Input
    public var action: InputAction
    /// 0-based agent slot the input reaches: its own slot for an agent key
    /// on Focus agent, or the slot a Focus agent slot N action names.
    public var slot: Int?
    /// The agent in that slot, if one is running.
    public var agent: HerdrAgent?

    public var id: Int { input.id }

    public init(input: Pad.Input, action: InputAction, slot: Int?, agent: HerdrAgent?) {
        self.input = input
        self.action = action
        self.slot = slot
        self.agent = agent
    }

    /// The 0-based slot an input reaches with this action, if any. The stock
    /// layout default is for compatibility; mappings pass active bindings.
    public static func slot(
        for action: InputAction,
        input: Int,
        agentKeyIDs: [Int] = Pad.agentKeyIDs
    ) -> Int? {
        switch action {
        case .focusAgent: return agentKeyIDs.firstIndex(of: input)
        case .focusSlot(let slot): return slot - 1
        default: return nil
        }
    }

    /// Every input, with the agent it reaches.
    public static func mappings(bindings: KeyBindings, agents: [HerdrAgent]) -> [HerdrInputMapping] {
        Pad.inputs.map { input in
            let action = bindings.action(for: input.id)
            let slot = slot(for: action, input: input.id, agentKeyIDs: bindings.agentKeyIDs)
            let agent = slot.flatMap { $0 >= 0 && $0 < agents.count ? agents[$0] : nil }
            return HerdrInputMapping(input: input, action: action, slot: slot, agent: agent)
        }
    }

    /// Agents no input reaches: beyond the configured slots, or in a slot whose key
    /// was remapped and that no Focus agent slot action names.
    public static func unassignedAgentIndices(
        bindings: KeyBindings, agents: [HerdrAgent], unavailableInputs: Set<Int> = []
    ) -> [Int] {
        let reached = Set(mappings(bindings: bindings, agents: agents)
            .filter { !unavailableInputs.contains($0.input.id) }.compactMap(\.slot))
        return agents.indices.filter { !reached.contains($0) }
    }
}
