import Foundation
import Darwin
#if canImport(AppKit)
import AppKit
#endif

/// Picks the app to bring forward when an input focuses a Herdr agent.
///
/// Herdr's panes are drawn by whatever terminal app is running its TUI client,
/// which is not necessarily the one this app was built against. Rather than
/// trusting a single hard-coded default, the host is read from the running
/// `herdr` client: the first GUI ancestor of that process owns the window the
/// panes live in. A terminal that is not running its client is not a candidate,
/// and a headless `herdr server` (whose parent is `launchd`) never matches,
/// which is exactly the point — it has no window to raise.
public enum TerminalTarget {

    /// Terminals people actually run Herdr in, in a stable preference order.
    /// Only consulted when the owning app cannot be detected from a client.
    public static let knownBundleIDs: [String] = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
    ]

    /// The executable name a Herdr TUI client has. The binary is installed as
    /// `herdr`; the server shares the name, and is filtered out by the GUI
    /// ancestor walk rather than by name.
    static let clientNames: Set<String> = ["herdr"]

    /// One process row — as much of the table as resolving needs.
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        public var parentPID: Int32
        public var name: String

        public init(pid: Int32, parentPID: Int32, name: String) {
            self.pid = pid
            self.parentPID = parentPID
            self.name = name
        }
    }

    /// One running GUI app that could own a terminal window.
    public struct App: Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String

        public init(pid: Int32, bundleID: String) {
            self.pid = pid
            self.bundleID = bundleID
        }
    }

    /// Pure resolution, so the precedence is testable without a process table.
    ///
    /// Order: an explicit override wins; then the GUI ancestor of a running
    /// Herdr client; then the first known terminal that is running.
    public static func resolve(
        override: String?,
        processes: [Process],
        apps: [App],
        knownBundleIDs: [String] = TerminalTarget.knownBundleIDs
    ) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }

        var appByPID: [Int32: String] = [:]
        for app in apps where appByPID[app.pid] == nil { appByPID[app.pid] = app.bundleID }
        var parentByPID: [Int32: Int32] = [:]
        for process in processes where parentByPID[process.pid] == nil {
            parentByPID[process.pid] = process.parentPID
        }

        // The newest client is the most likely one a person is looking at; a
        // larger pid is the closest signal to "started last" we have without
        // reading start times.
        let clients = processes
            .filter { clientNames.contains($0.name) }
            .sorted { $0.pid > $1.pid }

        for client in clients {
            var pid = client.parentPID
            var hops = 0
            while hops < 64 {
                if let bundleID = appByPID[pid] { return bundleID }
                guard let parent = parentByPID[pid], parent != pid else { break }
                pid = parent
                hops += 1
            }
        }

        let running = Set(apps.map(\.bundleID))
        return knownBundleIDs.first { running.contains($0) }
    }

    #if canImport(AppKit)
    /// The bundle id to raise right now, or nil when nothing can be found.
    /// Reads the live process table and the running GUI apps once per call.
    public static func hostBundleID(
        override: String? = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
    ) -> String? {
        resolve(override: override, processes: liveProcesses(), apps: liveApps())
    }

    private static func liveApps() -> [App] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return App(pid: app.processIdentifier, bundleID: bundleID)
        }
    }

    /// The process name and parent pid of everything running, via `sysctl`.
    /// Same-user processes are always readable; other users' names come back
    /// truncated, which does not matter for matching `herdr`.
    private static func liveProcesses() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = buffer.count * stride
        let listed = buffer.withUnsafeMutableBytes { raw -> Int in
            guard sysctl(&mib, 3, raw.baseAddress, &size, nil, 0) == 0 else { return 0 }
            return size / stride
        }
        guard listed > 0 else { return [] }
        return (0..<min(listed, buffer.count)).map { index in
            let proc = buffer[index]
            return Process(
                pid: proc.kp_proc.p_pid,
                parentPID: proc.kp_eproc.e_ppid,
                name: commandName(proc)
            )
        }
    }

    /// `kp_proc.p_comm` is a fixed-size C string; read up to its NUL.
    private static func commandName(_ proc: kinfo_proc) -> String {
        var comm = proc.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
    #endif
}
