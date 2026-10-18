import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The system and launch actions: synthesised scroll, keyboard and media
/// events, typing, opening things and running shell commands.
///
/// Every synthesised event needs the **Accessibility** grant for the Studio
/// app, separate from the Input Monitoring grant the pad needs; the first
/// attempt raises the system prompt. Opening things and shell commands need no
/// grant of their own (though whatever a script touches may).
///
/// The parsing is pure and tested; the posting is not, since it would drive
/// the machine the tests run on.
public enum SystemActions {

    public enum Failure: LocalizedError, Equatable {
        case accessibilityDenied
        case eventFailed(String)
        case unknownShortcut(String)
        case emptyParameter(String)
        case cannotOpen(String)
        case commandFailed(status: Int32, output: String)
        case commandTimedOut(TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "This action needs the Accessibility permission: System Settings → "
                    + "Privacy & Security → Accessibility → turn the Studio on."
            case .eventFailed(let what):
                return "Could not synthesise \(what)."
            case .unknownShortcut(let text):
                return "“\(text)” is not a shortcut this app knows. Use names like cmd+shift+k, pageup, f5 or return."
            case .emptyParameter(let what):
                return "No \(what) is set for this action."
            case .cannotOpen(let target):
                return "Could not open “\(target)”."
            case .commandFailed(let status, let output):
                let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Shell command exited with status \(status)" + (tail.isEmpty ? "." : ": \(tail)")
            case .commandTimedOut(let seconds):
                return "Shell command was stopped after \(Int(seconds)) s."
            }
        }
    }

    // MARK: - Accessibility

    /// Whether the Studio may post events, without prompting.
    public static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Raises the system Accessibility prompt if the grant is missing, and
    /// returns whether it is granted now.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// System Settings → Privacy & Security → Accessibility.
    public static let accessibilitySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static func ensureAccessibility() throws {
        guard requestAccessibility() else { throw Failure.accessibilityDenied }
    }

    // MARK: - Scroll

    /// Scrolls whatever is under the pointer, in lines.
    public static func scroll(_ direction: InputAction.Direction, lines: Int) throws {
        try ensureAccessibility()
        let (vertical, horizontal) = scrollDeltas(direction, lines: lines)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        ) else { throw Failure.eventFailed("a scroll") }
        event.post(tap: .cghidEventTap)
    }

    /// Wheel deltas for a direction: positive vertical scrolls up, positive
    /// horizontal scrolls left — the CGEvent convention.
    static func scrollDeltas(_ direction: InputAction.Direction, lines: Int) -> (vertical: Int32, horizontal: Int32) {
        let amount = Int32(InputAction.clamp(lines, InputAction.scrollAmountRange))
        switch direction {
        case .up: return (amount, 0)
        case .down: return (-amount, 0)
        case .left: return (0, amount)
        case .right: return (0, -amount)
        }
    }

    // MARK: - Keyboard shortcuts

    /// A key plus modifiers, parsed from `"cmd+shift+k"`.
    public struct KeyChord: Equatable, Sendable {
        public var keyCode: CGKeyCode
        public var flags: CGEventFlags

        public init(keyCode: CGKeyCode, flags: CGEventFlags = []) {
            self.keyCode = keyCode
            self.flags = flags
        }

        public static func == (lhs: KeyChord, rhs: KeyChord) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.flags.rawValue == rhs.flags.rawValue
        }

        /// `+`-separated, case-insensitive: modifiers (`cmd`/`command`/`⌘`,
        /// `shift`/`⇧`, `alt`/`opt`/`option`/`⌥`, `ctrl`/`control`/`⌃`, `fn`)
        /// and exactly one key. Nil when the key is unknown or missing.
        public static func parse(_ text: String) -> KeyChord? {
            let parts = text.lowercased()
                .split(separator: "+", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // "cmd++" means command and the plus key.
            var tokens: [String] = []
            for (index, part) in parts.enumerated() {
                if part.isEmpty {
                    if index == parts.count - 1, !tokens.isEmpty { tokens.append("+") }
                    continue
                }
                tokens.append(part)
            }
            guard !tokens.isEmpty else { return nil }
            var flags: CGEventFlags = []
            var key: CGKeyCode?
            for token in tokens {
                if let modifier = modifiers[token] {
                    flags.insert(modifier)
                } else if let code = keyCodes[token] {
                    guard key == nil else { return nil }
                    key = code
                } else {
                    return nil
                }
            }
            guard let key else { return nil }
            return KeyChord(keyCode: key, flags: flags)
        }

        static let modifiers: [String: CGEventFlags] = [
            "cmd": .maskCommand, "command": .maskCommand, "⌘": .maskCommand, "super": .maskCommand,
            "shift": .maskShift, "⇧": .maskShift,
            "alt": .maskAlternate, "opt": .maskAlternate, "option": .maskAlternate, "⌥": .maskAlternate,
            "ctrl": .maskControl, "control": .maskControl, "⌃": .maskControl,
            "fn": .maskSecondaryFn,
        ]

        /// ANSI virtual key codes (Carbon `kVK_*`).
        static let keyCodes: [String: CGKeyCode] = {
            var codes: [String: CGKeyCode] = [
                "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06,
                "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E,
                "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
                "6": 0x16, "5": 0x17, "=": 0x18, "equal": 0x18, "+": 0x18, "9": 0x19, "7": 0x1A,
                "-": 0x1B, "minus": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "rightbracket": 0x1E,
                "o": 0x1F, "u": 0x20, "[": 0x21, "leftbracket": 0x21, "i": 0x22, "p": 0x23,
                "l": 0x25, "j": 0x26, "'": 0x27, "quote": 0x27, "k": 0x28, ";": 0x29,
                "semicolon": 0x29, "\\": 0x2A, "backslash": 0x2A, ",": 0x2B, "comma": 0x2B,
                "/": 0x2C, "slash": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "period": 0x2F,
                "`": 0x32, "grave": 0x32, "backtick": 0x32,
                "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
                "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
                "forwarddelete": 0x75, "del": 0x75,
                "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
                "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
                "help": 0x72, "keypadenter": 0x4C,
            ]
            let functionKeys: [CGKeyCode] = [
                0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
                0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
            ]
            for (index, code) in functionKeys.enumerated() { codes["f\(index + 1)"] = code }
            for alias in ["page-up": "pageup", "page_up": "pageup", "page-down": "pagedown",
                          "page_down": "pagedown", "arrowup": "up", "arrowdown": "down",
                          "arrowleft": "left", "arrowright": "right", "forward-delete": "forwarddelete"] {
                codes[alias.key] = codes[alias.value]
            }
            return codes
        }()
    }

    /// Presses and releases a chord in the frontmost app.
    public static func keyboardShortcut(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Failure.emptyParameter("shortcut")
        }
        guard let chord = KeyChord.parse(text) else { throw Failure.unknownShortcut(text) }
        try ensureAccessibility()
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: chord.keyCode, keyDown: false)
        else { throw Failure.eventFailed("the shortcut \(text)") }
        // Modifier flags ride on the key events and are cleared on the way
        // up, or listeners see modifiers that never release.
        down.flags = chord.flags
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - Media keys

    /// `NX_KEYTYPE_*` codes from IOKit's `ev_keymap.h`.
    static func systemKeyType(_ key: InputAction.MediaKey) -> Int {
        switch key {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    /// Posts the same system-defined event the keyboard's media keys send.
    public static func mediaKey(_ key: InputAction.MediaKey) throws {
        try ensureAccessibility()
        let type = systemKeyType(key)
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (type << 16) | (state << 8),
                data2: -1
            )?.cgEvent else { throw Failure.eventFailed("the \(key.title) key") }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Typing

    /// Types `text` into whatever has keyboard focus, as Unicode — layout
    /// independent, and nothing is pressed afterwards.
    public static func typeText(_ text: String) throws {
        guard !text.isEmpty else { throw Failure.emptyParameter("text") }
        try ensureAccessibility()
        let source = CGEventSource(stateID: .hidSystemState)
        for chunk in utf16Chunks(text) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw Failure.eventFailed("typing") }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// CGEvent carries at most 20 UTF-16 units per event; never split a
    /// surrogate pair across two.
    static func utf16Chunks(_ text: String, size: Int = 20) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if current.count + units.count > size, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current += units
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Open

    /// What an `openURL` parameter names.
    public enum LaunchTarget: Equatable, Sendable {
        case url(URL)
        case file(URL)
        case bundleIdentifier(String)
        case applicationName(String)
    }

    /// Reads a URL (`https://…`, `mailto:…`, `x-apple…:`), a path (`/…`,
    /// `~/…`), a bundle id (`com.apple.Terminal`) or an app name (`Safari`).
    public static func launchTarget(_ text: String) -> LaunchTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return .file(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
        }
        if let scheme = trimmed.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression),
           !trimmed[scheme].contains("."), let url = URL(string: trimmed) {
            return .url(url)
        }
        if trimmed.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil,
           trimmed.lowercased().hasSuffix(".app") == false {
            // A dotted name is a bundle id when an app claims it, else a web
            // address ("example.com").
            return .bundleIdentifier(trimmed)
        }
        let name = trimmed.lowercased().hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        return .applicationName(name)
    }

    public static func open(_ text: String) throws {
        guard let target = launchTarget(text) else { throw Failure.emptyParameter("URL, file or app") }
        let workspace = NSWorkspace.shared
        switch target {
        case .url(let url), .file(let url):
            guard workspace.open(url) else { throw Failure.cannotOpen(text) }
        case .bundleIdentifier(let identifier):
            if let app = workspace.urlForApplication(withBundleIdentifier: identifier) {
                workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } else if let url = URL(string: "https://\(identifier)"), workspace.open(url) {
                return
            } else {
                throw Failure.cannotOpen(text)
            }
        case .applicationName(let name):
            guard let app = applicationURL(named: name) else { throw Failure.cannotOpen(text) }
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func applicationURL(named name: String) -> URL? {
        let manager = FileManager.default
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/Applications/Utilities", (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for folder in folders {
            let path = (folder as NSString).appendingPathComponent("\(name).app")
            if manager.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        // Case-insensitive match as a fallback.
        for folder in folders {
            guard let entries = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            if let match = entries.first(where: { $0.lowercased() == "\(name.lowercased()).app" }) {
                return URL(fileURLWithPath: (folder as NSString).appendingPathComponent(match))
            }
        }
        return nil
    }

    // MARK: - Shell

    public struct ShellResult: Equatable, Sendable {
        public var status: Int32
        public var output: String
    }

    public static let defaultShellTimeout: TimeInterval = 30

    /// How long a timed-out command gets after SIGTERM before SIGKILL.
    public static let shellKillGrace: TimeInterval = 2

    /// Runs `command` with `/bin/zsh -lc` — a login shell, so PATH matches
    /// the user's terminal rather than launchd's — off the main thread.
    /// Throws with the output's tail on a non-zero exit.
    ///
    /// The shell runs in its own process group. After `timeout` the whole
    /// group gets SIGTERM, then SIGKILL after `killGrace`, so a timeout stops
    /// the work and not just the shell. The result is reported as soon as the
    /// shell exits: output is collected as it arrives, never by waiting for
    /// end-of-file, so a command that leaves something in the background
    /// (`my-server &`) still finishes. Whatever such a child writes later is
    /// read and discarded, so it never blocks on a full pipe.
    @discardableResult
    public static func runShell(
        _ command: String,
        shell: String = "/bin/zsh",
        arguments: [String] = ["-lc"],
        timeout: TimeInterval = defaultShellTimeout,
        killGrace: TimeInterval = shellKillGrace
    ) async throws -> ShellResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.emptyParameter("command")
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try ShellRun.start(
                    path: shell,
                    arguments: arguments + [command],
                    environment: nil,
                    timeout: timeout,
                    killGrace: killGrace
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Runs the executable at `path` directly with `arguments` — no shell, so
    /// nothing in an argument is ever interpreted — with the same process
    /// group, timeout and output handling as `runShell`. `environment`
    /// replaces this process's environment when given. Throws
    /// `Failure.commandFailed` with the combined stdout/stderr tail on a
    /// non-zero exit, `Failure.commandTimedOut` on timeout, and a
    /// `POSIXError` when the executable cannot be spawned.
    @discardableResult
    public static func runProcess(
        _ path: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = defaultShellTimeout,
        killGrace: TimeInterval = shellKillGrace
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try ShellRun.start(
                    path: path,
                    arguments: arguments,
                    environment: environment,
                    timeout: timeout,
                    killGrace: killGrace
                ) { continuation.resume(with: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// One spawned shell: its process group, its output pipe and its timers.
    /// All state lives on `queue`.
    private final class ShellRun: @unchecked Sendable {
        private let pid: pid_t
        private let readFD: Int32
        private let timeout: TimeInterval
        private let queue = DispatchQueue(label: "dev.abeisonai.worklouder.shell")
        private let collector = OutputCollector()
        private var readSource: DispatchSourceRead?
        private var completion: ((Result<ShellResult, Error>) -> Void)?
        private var exited = false
        private var timedOut = false

        private init(pid: pid_t, readFD: Int32, timeout: TimeInterval,
                     completion: @escaping (Result<ShellResult, Error>) -> Void) {
            self.pid = pid
            self.readFD = readFD
            self.timeout = timeout
            self.completion = completion
        }

        static func start(
            path: String,
            arguments: [String],
            environment: [String: String]?,
            timeout: TimeInterval,
            killGrace: TimeInterval,
            completion: @escaping (Result<ShellResult, Error>) -> Void
        ) throws {
            var fds: [Int32] = [-1, -1]
            guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let readFD = fds[0], writeFD = fds[1]
            _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

            var actions: posix_spawn_file_actions_t?
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
            posix_spawn_file_actions_adddup2(&actions, writeFD, 2)

            var attributes: posix_spawnattr_t?
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Own process group (pgid = pid), only the fds above inherited,
            // default signal handling and an empty mask whatever this app uses.
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
            posix_spawnattr_setflags(&attributes, Int16(flags))
            posix_spawnattr_setpgroup(&attributes, 0)
            var defaults = sigset_t()
            sigemptyset(&defaults)
            for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, signal) }
            posix_spawnattr_setsigdefault(&attributes, &defaults)
            var mask = sigset_t()
            sigemptyset(&mask)
            posix_spawnattr_setsigmask(&attributes, &mask)

            let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            let envp: [UnsafeMutablePointer<CChar>?]? = environment.map { values in
                values.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
            }
            defer { envp?.forEach { free($0) } }
            var pid: pid_t = 0
            let status: Int32
            if let envp {
                status = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
            } else {
                status = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
            }
            close(writeFD)
            guard status == 0 else {
                close(readFD)
                throw POSIXError(.init(rawValue: status) ?? .EIO)
            }
            _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

            let run = ShellRun(pid: pid, readFD: readFD, timeout: timeout, completion: completion)
            run.begin(killGrace: killGrace)
        }

        private func begin(killGrace: TimeInterval) {
            let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: queue)
            source.setEventHandler { [self] in drain() }
            source.setCancelHandler { [readFD] in close(readFD) }
            readSource = source
            source.resume()

            // Reap on a plain thread: waitpid blocks, and only for the
            // shell's own lifetime, which the timeout bounds.
            let pid = self.pid
            Thread.detachNewThread { [self] in
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                queue.async { self.finish(waitStatus: status) }
            }

            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                guard !exited else { return }
                timedOut = true
                kill(-pid, SIGTERM)
                queue.asyncAfter(deadline: .now() + killGrace) { [pid] in
                    // Anything still in the group — the shell trapping
                    // SIGTERM, or children it left behind — goes now.
                    if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                }
            }
        }

        /// Reads whatever the pipe has without blocking. After the result is
        /// reported, output from background children is read and dropped.
        private func drain() {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = read(readFD, &buffer, buffer.count)
                if count > 0 {
                    if completion != nil { collector.append(Data(buffer[0..<count])) }
                    continue
                }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                // End of file (every writer is gone) or a real error.
                readSource?.cancel()
                readSource = nil
                return
            }
        }

        private func finish(waitStatus: Int32) {
            exited = true
            // Everything the shell wrote before exiting is in the pipe now.
            if readSource != nil { drain() }
            guard let completion else { return }
            self.completion = nil

            let output = collector.tail()
            let exitedNormally = (waitStatus & 0x7F) == 0
            let code = exitedNormally ? (waitStatus >> 8) & 0xFF : 128 + (waitStatus & 0x7F)
            if timedOut {
                completion(.failure(Failure.commandTimedOut(timeout)))
            } else if code != 0 {
                completion(.failure(Failure.commandFailed(status: code, output: output)))
            } else {
                completion(.success(ShellResult(status: 0, output: output)))
            }
        }
    }

    /// Output gathered from a pipe on a background queue.
    private final class OutputCollector: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            // Keep the end; that is where errors are.
            if data.count > 64 * 1024 { data = data.suffix(16 * 1024) }
        }

        func tail(maxCharacters: Int = 400) -> String {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: data, as: UTF8.self)
            return text.count > maxCharacters ? "…" + text.suffix(maxCharacters) : text
        }
    }
}
