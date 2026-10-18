import Foundation

/// Client for the Herdr socket API: newline-delimited JSON over a Unix socket.
///
/// The server handles **exactly one request per connection** and then closes,
/// with one exception: `events.subscribe` takes over the stream and pushes
/// events until the client disconnects. So a request opens a short-lived
/// connection, and each subscription owns a dedicated long-lived one. A client
/// that reuses a connection for a second request simply never hears back.

public struct HerdrAgent: Equatable, Sendable {
    public var terminalID: String?
    public var paneID: String?
    public var tabID: String?
    public var workspaceID: String?
    public var agent: String
    public var status: String
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool
    /// The user-given agent name (`agent.rename`), when there is one.
    public var name: String?
    /// Herdr's display label for the harness, e.g. "Claude Code".
    public var displayAgent: String?
    /// The harness's own session title, when it reports one.
    public var title: String?

    /// The target to hand to `agent.focus`, which resolves **pane ids only**:
    /// a `terminal_id` comes back as `agent_not_found` (Herdr 0.7.5). Herdr
    /// reports a terminal id for every agent, so preferring it here meant every
    /// jump failed while the read-only paths — which never call `agent.focus` —
    /// kept working. Terminal id stays as a fallback for a Herdr that omits
    /// `pane_id`.
    public var focusTarget: String? { paneID ?? terminalID }

    /// Where the agent is actually working. `foreground_cwd` follows a `cd`
    /// inside the pane; `cwd` is only where the pane started.
    public var workingDirectory: String? {
        [foregroundCwd, cwd].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Last path component of the working directory, which is what a person
    /// recognises the agent by.
    public var shortName: String {
        guard let directory = workingDirectory else { return agent }
        return (directory as NSString).lastPathComponent
    }

    /// The best label for a list: the agent's name, else its directory.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return shortName
    }

    /// The harness, as Herdr labels it.
    public var harnessName: String {
        if let displayAgent, !displayAgent.isEmpty { return displayAgent }
        return agent
    }

    init(json: [String: Any]) {
        terminalID = json["terminal_id"] as? String
        paneID = json["pane_id"] as? String
        tabID = json["tab_id"] as? String
        workspaceID = json["workspace_id"] as? String
        agent = json["agent"] as? String ?? "agent"
        status = json["agent_status"] as? String ?? "unknown"
        cwd = json["cwd"] as? String
        foregroundCwd = json["foreground_cwd"] as? String
        focused = json["focused"] as? Bool ?? false
        name = json["name"] as? String
        displayAgent = json["display_agent"] as? String
        title = (json["title"] as? String) ?? (json["terminal_title_stripped"] as? String)
    }

    /// For tests and previews.
    public init(
        agent: String = "claude",
        status: String,
        paneID: String? = nil,
        tabID: String? = nil,
        workspaceID: String? = nil,
        terminalID: String? = nil,
        cwd: String? = nil,
        foregroundCwd: String? = nil,
        focused: Bool = false,
        name: String? = nil,
        displayAgent: String? = nil,
        title: String? = nil
    ) {
        self.name = name
        self.displayAgent = displayAgent
        self.title = title
        self.agent = agent
        self.status = status
        self.paneID = paneID
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.focused = focused
    }

}

public struct HerdrTab: Equatable, Sendable, Identifiable {
    public var tabID: String
    public var workspaceID: String
    /// Display position within the workspace, which is the order tabs cycle in.
    public var number: Int
    public var focused: Bool
    public var label: String
    public var paneCount: Int
    public var agentStatus: String?

    public var id: String { tabID }

    init(json: [String: Any]) {
        tabID = json["tab_id"] as? String ?? ""
        workspaceID = json["workspace_id"] as? String ?? ""
        number = json["number"] as? Int ?? 0
        focused = json["focused"] as? Bool ?? false
        label = json["label"] as? String ?? ""
        paneCount = json["pane_count"] as? Int ?? 0
        agentStatus = json["agent_status"] as? String
    }

    /// For tests and previews.
    public init(
        tabID: String,
        workspaceID: String = "ws",
        number: Int,
        focused: Bool = false,
        label: String = "",
        paneCount: Int = 0,
        agentStatus: String? = nil
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.number = number
        self.focused = focused
        self.label = label
        self.paneCount = paneCount
        self.agentStatus = agentStatus
    }

    /// "label" or "Tab N" when the label is empty.
    public var displayLabel: String { label.isEmpty ? "Tab \(number)" : label }
}

public struct HerdrWorkspace: Equatable, Sendable, Identifiable {
    public var workspaceID: String
    /// Display position, which is the order workspaces cycle in.
    public var number: Int
    public var label: String
    public var focused: Bool
    public var activeTabID: String?
    public var tabCount: Int
    public var paneCount: Int
    public var agentStatus: String?

    public var id: String { workspaceID }

    init(json: [String: Any]) {
        workspaceID = json["workspace_id"] as? String ?? ""
        number = json["number"] as? Int ?? 0
        label = json["label"] as? String ?? ""
        focused = json["focused"] as? Bool ?? false
        activeTabID = json["active_tab_id"] as? String
        tabCount = json["tab_count"] as? Int ?? 0
        paneCount = json["pane_count"] as? Int ?? 0
        agentStatus = json["agent_status"] as? String
    }

    /// For tests and previews.
    public init(
        workspaceID: String,
        number: Int,
        label: String = "",
        focused: Bool = false,
        activeTabID: String? = nil,
        tabCount: Int = 0,
        paneCount: Int = 0,
        agentStatus: String? = nil
    ) {
        self.workspaceID = workspaceID
        self.number = number
        self.label = label
        self.focused = focused
        self.activeTabID = activeTabID
        self.tabCount = tabCount
        self.paneCount = paneCount
        self.agentStatus = agentStatus
    }

    /// "label" or "Workspace N" when the label is empty.
    public var displayLabel: String { label.isEmpty ? "Workspace \(number)" : label }
}

/// The server's answer to `ping`.
public struct HerdrPing: Equatable, Sendable {
    public var version: String
    public var protocolVersion: Int

    public init(version: String, protocolVersion: Int) {
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

/// Where the socket path came from, for the connection panel.
public enum HerdrSocketSource: String, Equatable, Sendable {
    /// `$HERDR_SOCKET_PATH`.
    case environment
    /// `$XDG_CONFIG_HOME/herdr/herdr.sock`.
    case xdgConfigHome
    /// `~/.config/herdr/herdr.sock`.
    case defaultPath

    public var title: String {
        switch self {
        case .environment: return "HERDR_SOCKET_PATH"
        case .xdgConfigHome: return "XDG_CONFIG_HOME"
        case .defaultPath: return "Default (~/.config)"
        }
    }
}

public enum HerdrError: LocalizedError {
    case cannotConnect(String, String)
    case timeout(String)
    case api(String)
    case closed(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConnect(let path, let reason):
            return "Cannot reach the Herdr server at \(path): \(reason)"
        case .timeout(let method): return "Timed out waiting for \(method)."
        case .api(let message): return message
        case .closed(let method): return "Connection closed before \(method) responded."
        case .badResponse(let detail): return "Bad response: \(detail)"
        }
    }
}

public enum HerdrClient {

    public static func socketPath() -> String { socketLocation().path }

    /// The socket path and which setting chose it.
    public static func socketLocation(
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> (path: String, source: HerdrSocketSource) {
        if let explicit = env["HERDR_SOCKET_PATH"], !explicit.isEmpty { return (explicit, .environment) }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return ((xdg as NSString).appendingPathComponent("herdr/herdr.sock"), .xdgConfigHome)
        }
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return ((base as NSString).appendingPathComponent("herdr/herdr.sock"), .defaultPath)
    }

    // MARK: - Requests

    public static func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 5
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let conn = SocketConnection(path: socketPath())
            // The reply, the close and the timeout race on different queues;
            // only the first may resume the continuation.
            let once = OnceFlag()
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                guard once.claim() else { return }
                conn.close()
                continuation.resume(with: result)
            }

            conn.onLine = { line in
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    finish(.failure(HerdrError.badResponse(line)))
                    return
                }
                if let error = object["error"] as? [String: Any] {
                    finish(.failure(HerdrError.api(error["message"] as? String ?? "api error")))
                } else {
                    finish(.success(object["result"] as? [String: Any] ?? [:]))
                }
            }
            conn.onClosed = { error in
                finish(.failure(error ?? HerdrError.closed(method)))
            }

            do {
                try conn.open()
            } catch {
                finish(.failure(error))
                return
            }

            let envelope: [String: Any] = ["id": nextID(), "method": method, "params": params]
            guard let payload = try? JSONSerialization.data(withJSONObject: envelope) else {
                finish(.failure(HerdrError.badResponse("could not encode params")))
                return
            }
            conn.write(payload + Data("\n".utf8))

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(HerdrError.timeout(method)))
            }
        }
    }

    /// Agents in the server's own order — workspace, then tab, then pane —
    /// which is exactly how Herdr's agent panel lists them in grouped mode.
    /// Slot N is element N, so the pad reads like the sidebar. Do not re-sort:
    /// an earlier version ordered by ID strings here, and IDs do not sort the
    /// way the sidebar displays.
    public static func listAgents() async throws -> [HerdrAgent] {
        let result = try await request("agent.list")
        let raw = result["agents"] as? [[String: Any]] ?? []
        return raw.map(HerdrAgent.init(json:))
    }

    /// The agent whose pane has focus in Herdr, if any. Fetched fresh rather
    /// than read off the bridge's poll, since focus is exactly the thing that
    /// changes between polls.
    public static func focusedAgent() async throws -> HerdrAgent? {
        try await listAgents().first(where: \.focused)
    }

    public static func focusAgent(_ target: String) async throws {
        _ = try await request("agent.focus", params: ["target": target])
    }

    public static func listTabs(workspaceID: String? = nil) async throws -> [HerdrTab] {
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let result = try await request("tab.list", params: params)
        let raw = result["tabs"] as? [[String: Any]] ?? []
        return raw.map(HerdrTab.init(json:))
    }

    public static func focusTab(_ tabID: String) async throws {
        _ = try await request("tab.focus", params: ["tab_id": tabID])
    }

    /// Injects key chords into a pane, crossterm-style names ("ctrl+alt+v",
    /// "f13", "enter"). The pane's terminal encodes them as if typed.
    public static func sendKeys(paneID: String, keys: [String]) async throws {
        _ = try await request("pane.send_keys", params: ["pane_id": paneID, "keys": keys])
    }

    /// Types a string into a pane — bracketed-pasted when the pane supports
    /// it, so multi-word text lands as one block and nothing auto-submits.
    public static func sendText(paneID: String, text: String) async throws {
        _ = try await request("pane.send_text", params: ["pane_id": paneID, "text": text])
    }

    /// Focuses the tab after the focused one in its workspace, wrapping at the
    /// end. Tabs in other workspaces are left alone: cycling is a
    /// within-window gesture, not a window switcher.
    public static func cycleTabs() async throws {
        try await cycleTabs(by: 1)
    }

    /// `+1` for the next tab, `-1` for the previous one, wrapping.
    public static func cycleTabs(by offset: Int) async throws {
        guard let next = adjacentTab(in: try await listTabs(), offset: offset) else { return }
        try await focusTab(next.tabID)
    }

    /// The tab `cycleTabs` would focus, or nil when there is nothing to do —
    /// no focused tab, or a workspace with a single tab.
    public static func nextTab(in tabs: [HerdrTab]) -> HerdrTab? {
        adjacentTab(in: tabs, offset: 1)
    }

    /// The tab `offset` places from the focused one, within its workspace,
    /// in `number` order, wrapping.
    public static func adjacentTab(in tabs: [HerdrTab], offset: Int) -> HerdrTab? {
        guard let focused = tabs.first(where: \.focused) else { return nil }
        let siblings = tabs
            .filter { $0.workspaceID == focused.workspaceID }
            .sorted { $0.number < $1.number }
        guard siblings.count > 1,
              let index = siblings.firstIndex(of: focused)
        else { return nil }
        return siblings[wrap(index + offset, siblings.count)]
    }

    public static func listWorkspaces() async throws -> [HerdrWorkspace] {
        let result = try await request("workspace.list")
        let raw = result["workspaces"] as? [[String: Any]] ?? []
        return raw.map(HerdrWorkspace.init(json:))
    }

    public static func focusWorkspace(_ workspaceID: String) async throws {
        _ = try await request("workspace.focus", params: ["workspace_id": workspaceID])
    }

    /// `+1` for the next workspace, `-1` for the previous one, wrapping.
    public static func cycleWorkspaces(by offset: Int) async throws {
        guard let next = adjacentWorkspace(in: try await listWorkspaces(), offset: offset) else { return }
        try await focusWorkspace(next.workspaceID)
    }

    /// The workspace `offset` places from the focused one, in `number`
    /// order, wrapping; nil with no focused workspace or only one.
    public static func adjacentWorkspace(in workspaces: [HerdrWorkspace], offset: Int) -> HerdrWorkspace? {
        let ordered = workspaces.sorted { $0.number < $1.number }
        guard ordered.count > 1,
              let index = ordered.firstIndex(where: \.focused)
        else { return nil }
        return ordered[wrap(index + offset, ordered.count)]
    }

    private static func wrap(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }

    /// Server version and protocol: the cheapest health check there is.
    public static func ping(timeout: TimeInterval = 2) async throws -> HerdrPing {
        let result = try await request("ping", timeout: timeout)
        return HerdrPing(
            version: result["version"] as? String ?? "?",
            protocolVersion: result["protocol"] as? Int ?? 0
        )
    }

    /// Moves focus to the neighbouring pane: "left", "right", "up", "down".
    public static func focusPane(direction: String) async throws {
        _ = try await request("pane.focus_direction", params: ["direction": direction])
    }

    /// Toggles zoom on the focused pane.
    public static func zoomPane() async throws {
        _ = try await request("pane.zoom", params: ["mode": "toggle"])
    }

    /// Pastes `text` and presses Enter as one submission. Herdr refuses a
    /// blocked agent (`agent_blocked`) rather than typing into its question.
    public static func promptAgent(target: String, text: String) async throws {
        _ = try await request("agent.prompt", params: ["target": target, "text": text])
    }

    /// The pane Herdr has focused (`pane.current`), agent or not.
    public static func currentPaneID() async throws -> String? {
        let result = try await request("pane.current")
        let pane = result["pane"] as? [String: Any]
        return (pane?["pane_id"] as? String) ?? (result["pane_id"] as? String)
    }

    /// Herdr's focus right now, read fresh, for a Herdr command's
    /// placeholders. Only what `needs` asks for is fetched. The tab is the
    /// one focused in the focused workspace — the *current* tab — not the
    /// tab of the focused agent.
    public static func commandContext(needs: Set<HerdrCommand.Placeholder>) async throws -> HerdrCommand.Context {
        let needsTabs = !needs.isDisjoint(with: [.tab, .tabLabel, .workspace, .workspaceLabel])

        var workspaces: [HerdrWorkspace] = []
        var tabs: [HerdrTab] = []
        if needsTabs {
            workspaces = try await listWorkspaces()
            let focused = workspaces.first(where: \.focused)?.workspaceID
            tabs = try await listTabs(workspaceID: focused)
        }
        var currentPane: String?
        if needs.contains(.pane) {
            // An older Herdr without pane.current falls back to the agent.
            currentPane = try? await currentPaneID()
        }
        let needsAgent = needs.contains(.agent) || (needs.contains(.pane) && currentPane == nil)
        let agent = needsAgent ? try await focusedAgent() : nil
        return .current(workspaces: workspaces, tabs: tabs, currentPane: currentPane, focusedAgent: agent)
    }

    /// Splits a `"ctrl+c esc"` style string into the key list
    /// `pane.send_keys` takes.
    public static func keyList(_ keys: String) -> [String] {
        keys.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" })
            .map(String.init)
    }

    private static let counter = Counter()
    private static func nextID() -> String { "wl_\(counter.next())" }

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }
}

/// A flag that can be claimed once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private var claimed = false
    private let lock = NSLock()
    /// True exactly once.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    var isClaimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return claimed
    }
}

// MARK: - Event streams

/// One subscription, on its own connection. The first line is the
/// acknowledgement; everything after it is a pushed event.
public final class HerdrEventStream {
    public var onReady: (() -> Void)?
    public var onEvent: (([String: Any]) -> Void)?
    public var onClosed: ((Error?) -> Void)?

    private let subscriptions: [[String: Any]]
    private let conn: SocketConnection
    /// Only touched on the connection's read queue.
    private var ready = false
    /// Written on main by stop(), read on the read queue.
    private let stopFlag = OnceFlag()
    private var stopped: Bool { stopFlag.isClaimed }

    public init(subscriptions: [[String: Any]]) {
        self.subscriptions = subscriptions
        self.conn = SocketConnection(path: HerdrClient.socketPath())
    }

    @discardableResult
    public func start() -> HerdrEventStream {
        conn.onLine = { [weak self] line in
            guard let self, !self.stopped else { return }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            if !self.ready {
                self.ready = true
                // The first line answers events.subscribe; an error there
                // means no events will ever come, so say so rather than
                // sitting "subscribed" on a dead stream.
                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? "events.subscribe failed"
                    self.conn.close()
                    DispatchQueue.main.async { self.onClosed?(HerdrError.api(message)) }
                    return
                }
                DispatchQueue.main.async { self.onReady?() }
                return
            }
            DispatchQueue.main.async { self.onEvent?(object) }
        }
        conn.onClosed = { [weak self] error in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.async { self.onClosed?(error) }
        }

        do {
            try conn.open()
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onClosed?(error) }
            return self
        }

        let envelope: [String: Any] = [
            "id": "wl_sub",
            "method": "events.subscribe",
            "params": ["subscriptions": subscriptions],
        ]
        if let payload = try? JSONSerialization.data(withJSONObject: envelope) {
            conn.write(payload + Data("\n".utf8))
        }
        return self
    }

    public func stop() {
        _ = stopFlag.claim()
        conn.close()
    }

    deinit { conn.close() }
}

// MARK: - Socket plumbing

/// A blocking read loop on its own queue. Deliberately plain POSIX: the
/// alternative is Network.framework, which adds ceremony for no benefit on a
/// local Unix socket.
final class SocketConnection: @unchecked Sendable {
    /// The handlers usually capture whoever owns this connection, which owns
    /// it back; `close()` drops them to break that cycle, so every request's
    /// connection (and its queue) is freed once it is done.
    var onLine: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return lineHandler }
        set { lock.lock(); lineHandler = newValue; lock.unlock() }
    }
    var onClosed: ((Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return closedHandler }
        set { lock.lock(); closedHandler = newValue; lock.unlock() }
    }
    private var lineHandler: ((String) -> Void)?
    private var closedHandler: ((Error?) -> Void)?

    private let path: String
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "dev.abeisonai.worklouder.herdr-socket")
    private var buffer = Data()
    private var closed = false
    private let lock = NSLock()

    init(path: String) { self.path = path }

    func open() throws {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else {
            throw HerdrError.cannotConnect(path, String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self), source, maxLength - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(handle, $0, size) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(handle)
            throw HerdrError.cannotConnect(path, reason)
        }

        fd = handle
        queue.async { [weak self] in self?.readLoop() }
    }

    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, !closed else { return }
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    /// Wakes the reader and stops further writes. The descriptor itself is
    /// released only by the read loop (or deinit when no loop ever ran):
    /// closing it here, while the loop may be about to `read` it, could let
    /// a new connection reuse the number and the old loop read its reply.
    func close() {
        lock.lock()
        let handle = fd
        closed = true
        lineHandler = nil
        closedHandler = nil
        if handle >= 0 { Darwin.shutdown(handle, SHUT_RDWR) }
        lock.unlock()
    }

    deinit {
        // A running loop holds a strong reference, so reaching here means no
        // loop owns the descriptor any more.
        if fd >= 0 { Darwin.close(fd) }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        defer {
            lock.lock()
            let handle = fd
            fd = -1
            lock.unlock()
            if handle >= 0 { Darwin.close(handle) }
        }
        while true {
            lock.lock(); let handle = fd; let isClosed = closed; lock.unlock()
            guard handle >= 0, !isClosed else { break }

            let n = Darwin.read(handle, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.prefix(upTo: index)
                buffer = buffer.suffix(from: buffer.index(after: index))
                if let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                    // Read under the lock; a concurrent close() may clear it.
                    onLine?(line)
                }
            }
        }
        lock.lock()
        let wasClosed = closed
        let handler = closedHandler
        lock.unlock()
        if !wasClosed { handler?(nil) }
    }
}
