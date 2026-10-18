import Foundation

/// A Herdr CLI command line, as typed into a Herdr command action: what
/// follows `herdr` in a terminal, with placeholders filled in at press time.
///
///     tab rename {tab} {ask:New tab name={tab_label}}
///
/// The text is split into arguments with shell-like quoting **before** any
/// placeholder is substituted, and each argument is handed to the `herdr`
/// binary as-is. No shell ever sees it, so a tab label with spaces, quotes or
/// `$(…)` in it is just text.
///
/// Quoting:
///   - whitespace separates arguments;
///   - `'…'` is literal, placeholders included;
///   - `"…"` groups, with `\"`, `\\`, `\{` and `\}` escapes, placeholders on;
///   - `\x` outside quotes is a literal `x`;
///   - `{…}` is a placeholder, and may contain spaces.
///
/// A leading `herdr` is accepted and dropped.
public struct HerdrCommand: Equatable, Sendable {

    // MARK: - Model

    /// A value filled in from Herdr's state at press time.
    public enum Placeholder: String, CaseIterable, Identifiable, Hashable, Sendable {
        /// The focused pane's id.
        case pane
        /// The focused tab's id, in the focused workspace.
        case tab
        /// The focused workspace's id.
        case workspace
        /// The focused tab's label.
        case tabLabel = "tab_label"
        /// The focused workspace's label.
        case workspaceLabel = "workspace_label"
        /// The focused agent's name, else its pane id.
        case agent

        public var id: String { rawValue }
        /// As typed, braces included.
        public var token: String { "{\(rawValue)}" }

        public var summary: String {
            switch self {
            case .pane: return "the focused pane's id"
            case .tab: return "the focused tab's id"
            case .workspace: return "the focused workspace's id"
            case .tabLabel: return "the focused tab's name"
            case .workspaceLabel: return "the focused workspace's name"
            case .agent: return "the focused agent's name (or pane id)"
            }
        }

        /// What Herdr lacks when this cannot be filled in.
        var missingThing: String {
            switch self {
            case .pane: return "focused pane"
            case .tab, .tabLabel: return "focused tab"
            case .workspace, .workspaceLabel: return "focused workspace"
            case .agent: return "focused agent"
            }
        }
    }

    /// One piece of an argument.
    public enum Segment: Equatable, Sendable {
        case literal(String)
        case value(Placeholder)
        /// `{ask:Prompt}` or `{ask:Prompt=Default}`; the default may contain
        /// placeholders but not another ask.
        case ask(prompt: String, defaultValue: [Segment])
    }

    /// One argument: its segments concatenated.
    public struct Argument: Equatable, Sendable {
        public var segments: [Segment]
    }

    /// Herdr's state the placeholders are filled from.
    public struct Context: Equatable, Sendable {
        public var pane: String?
        public var tab: String?
        public var workspace: String?
        public var tabLabel: String?
        public var workspaceLabel: String?
        public var agent: String?

        public init(
            pane: String? = nil, tab: String? = nil, workspace: String? = nil,
            tabLabel: String? = nil, workspaceLabel: String? = nil, agent: String? = nil
        ) {
            self.pane = pane
            self.tab = tab
            self.workspace = workspace
            self.tabLabel = tabLabel
            self.workspaceLabel = workspaceLabel
            self.agent = agent
        }

        public subscript(placeholder: Placeholder) -> String? {
            switch placeholder {
            case .pane: return pane
            case .tab: return tab
            case .workspace: return workspace
            case .tabLabel: return tabLabel
            case .workspaceLabel: return workspaceLabel
            case .agent: return agent
            }
        }

        /// The *current* tab and workspace: the focused workspace, and the
        /// tab focused inside it (its `active_tab_id` as a fallback). Not the
        /// tab of the focused agent — a plain shell tab can have focus too.
        /// `currentPane` is `pane.current`'s answer; the focused agent's pane
        /// stands in when it is missing.
        public static func current(
            workspaces: [HerdrWorkspace],
            tabs: [HerdrTab],
            currentPane: String? = nil,
            focusedAgent: HerdrAgent? = nil
        ) -> Context {
            var context = Context()
            let workspace = workspaces.first(where: \.focused)
            if let workspace {
                context.workspace = workspace.workspaceID
                context.workspaceLabel = workspace.displayLabel
            }
            let tab: HerdrTab?
            if let workspace {
                let inWorkspace = tabs.filter { $0.workspaceID == workspace.workspaceID }
                tab = inWorkspace.first(where: \.focused)
                    ?? workspace.activeTabID.flatMap { id in tabs.first { $0.tabID == id } }
            } else {
                tab = tabs.first(where: \.focused)
            }
            if let tab {
                context.tab = tab.tabID
                context.tabLabel = tab.displayLabel
                if context.workspace == nil, !tab.workspaceID.isEmpty {
                    context.workspace = tab.workspaceID
                    context.workspaceLabel = workspaces.first { $0.workspaceID == tab.workspaceID }?.displayLabel
                }
            }
            context.pane = currentPane.flatMap { $0.isEmpty ? nil : $0 } ?? focusedAgent?.paneID
            if let focusedAgent {
                if let name = focusedAgent.name, !name.isEmpty {
                    context.agent = name
                } else {
                    context.agent = focusedAgent.paneID ?? focusedAgent.terminalID
                }
            }
            return context
        }

        /// From the bridge's last poll, for an editor's preview only: an
        /// action always reads Herdr fresh when it runs.
        public init(status: HerdrStatus, agents: [HerdrAgent]) {
            self = .current(workspaces: status.workspaces, tabs: status.tabs,
                            focusedAgent: agents.first(where: \.focused))
        }
    }

    /// What went wrong, worded for the person who typed the command.
    public enum Failure: LocalizedError, Equatable {
        case empty
        /// An old value that was a Herdr TUI keybinding.
        case keybinding(String)
        /// An old value that was an opaque `command.invoke` id.
        case commandID(String)
        case syntax(String)
        case unknownPlaceholder(String)
        /// Herdr has nothing focused to fill this placeholder from.
        case missing(Placeholder)
        /// The command asks for text but nothing in the app can ask.
        case cannotAsk
        case binaryNotFound
        case failed(status: Int32, message: String)
        case timedOut(TimeInterval)

        public static let exampleHint = "Herdr commands look like: tab rename {tab} {ask:New tab name}"

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "No Herdr command is set for this input."
            case .keybinding(let text):
                return "“\(text)” is a Herdr keybinding. \(Self.exampleHint)"
            case .commandID(let text):
                return "“\(text)” is not a Herdr command line (Herdr's internal command ids can't be run from other apps). \(Self.exampleHint)"
            case .syntax(let detail):
                return "Herdr command: \(detail)"
            case .unknownPlaceholder(let name):
                let known = Placeholder.allCases.map(\.token).joined(separator: " ")
                return "Herdr command: {\(name)} is not a placeholder. Use \(known), or {ask:Prompt}."
            case .missing(let placeholder):
                return "Herdr has no \(placeholder.missingThing) right now, so \(placeholder.token) has no value."
            case .cannotAsk:
                return "This Herdr command asks for text, but the Studio cannot show its prompt right now."
            case .binaryNotFound:
                return "Could not find the herdr program. Install Herdr, or set WL_HERDR_PATH to its full path."
            case .failed(let status, let message):
                let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? "herdr exited with status \(status)." : "Herdr: \(text)"
            case .timedOut(let seconds):
                return "herdr did not finish within \(Int(seconds)) s and was stopped."
            }
        }
    }

    /// The text as typed.
    public let source: String
    /// The arguments after `herdr`.
    public let arguments: [Argument]

    // MARK: - Parsing

    /// Parses `text`, rejecting legacy keybindings and command ids first.
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacy = Self.legacyProblem(trimmed) { throw legacy }
        var parser = Parser(Array(trimmed))
        var arguments = try parser.arguments()
        if let first = arguments.first, first.segments == [.literal("herdr")] {
            arguments.removeFirst()
        }
        guard !arguments.isEmpty else { throw Failure.empty }
        self.source = text
        self.arguments = arguments
    }

    /// Why `text` cannot be a Herdr command line, without parsing it, for
    /// the values earlier versions stored: a TUI keybinding such as
    /// `prefix+shift+t`, or a single opaque `command.invoke` id. Nil when it
    /// may be one.
    /// A leading `herdr` word, as copied from the CLI, is ignored.
    public static func legacyProblem(_ text: String) -> Failure? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("herdr"),
           let next = trimmed.dropFirst("herdr".count).first, next.isWhitespace {
            trimmed = String(trimmed.dropFirst("herdr".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty, trimmed != "herdr" else { return .empty }
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }
        // A single word. `status` and `--version` style flags are real
        // one-word Herdr commands; braces and quotes mean someone is writing
        // a command line, which the parser will judge.
        if trimmed.contains("+") { return .keybinding(trimmed) }
        if trimmed == "status" || trimmed.hasPrefix("-") { return nil }
        if trimmed.contains(where: { "{}'\"\\".contains($0) }) { return nil }
        return .commandID(trimmed)
    }

    /// A problem with `text` an editor can show as it is typed, or nil.
    public static func validate(_ text: String) -> String? {
        do {
            _ = try HerdrCommand(parsing: text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Every placeholder used, inside ask defaults too.
    public var placeholders: Set<Placeholder> {
        var found = Set<Placeholder>()
        func visit(_ segments: [Segment]) {
            for segment in segments {
                switch segment {
                case .literal: break
                case .value(let placeholder): found.insert(placeholder)
                case .ask(_, let defaultValue): visit(defaultValue)
                }
            }
        }
        arguments.forEach { visit($0.segments) }
        return found
    }

    /// Whether running this asks the user for text.
    public var asksForText: Bool {
        arguments.contains { $0.segments.contains { if case .ask = $0 { return true } else { return false } } }
    }

    // MARK: - Resolving

    /// Asks for text: the prompt and the pre-filled default, answering the
    /// text or nil when the user cancels.
    public typealias Ask = @MainActor (_ prompt: String, _ defaultText: String) async -> String?

    /// The argument list to run, or nil when the user cancelled an ask.
    /// Each `{ask:…}` prompt is asked once, in order, even if it repeats.
    @MainActor
    public func resolve(context: Context, ask: Ask?) async throws -> [String]? {
        var answers: [String: String] = [:]
        var resolved: [String] = []
        for argument in arguments {
            var text = ""
            for segment in argument.segments {
                switch segment {
                case .literal(let literal):
                    text += literal
                case .value(let placeholder):
                    text += try Self.value(placeholder, in: context)
                case .ask(let prompt, let defaultSegments):
                    if let answer = answers[prompt] {
                        text += answer
                        continue
                    }
                    guard let ask else { throw Failure.cannotAsk }
                    let defaultText = try Self.fill(defaultSegments, context: context)
                    guard let answer = await ask(prompt, defaultText) else { return nil }
                    answers[prompt] = answer
                    text += answer
                }
            }
            resolved.append(text)
        }
        return resolved
    }

    private static func value(_ placeholder: Placeholder, in context: Context) throws -> String {
        guard let value = context[placeholder], !value.isEmpty else { throw Failure.missing(placeholder) }
        return value
    }

    private static func fill(_ segments: [Segment], context: Context) throws -> String {
        try segments.map { segment -> String in
            switch segment {
            case .literal(let text): return text
            case .value(let placeholder): return try value(placeholder, in: context)
            case .ask: return ""
            }
        }.joined()
    }

    /// Parse, fetch the context the command needs, ask, and return the
    /// arguments — everything short of running it. Nil when cancelled.
    @MainActor
    public static func prepare(
        _ text: String,
        context: (Set<Placeholder>) async throws -> Context,
        ask: Ask?
    ) async throws -> [String]? {
        let command = try HerdrCommand(parsing: text)
        let needed = command.placeholders
        let current = needed.isEmpty ? Context() : try await context(needed)
        return try await command.resolve(context: current, ask: ask)
    }

    // MARK: - Preview

    /// "herdr tab rename w1:t2 ‹New tab name›" — what a press would run,
    /// with asks shown as their prompt and missing values as their token.
    public func preview(context: Context?) -> String {
        func render(_ segments: [Segment]) -> String {
            segments.map { segment -> String in
                switch segment {
                case .literal(let text): return text
                case .value(let placeholder):
                    if let value = context?[placeholder], !value.isEmpty { return value }
                    return placeholder.token
                case .ask(let prompt, _): return "‹\(prompt)›"
                }
            }.joined()
        }
        return (["herdr"] + arguments.map { argument -> String in
            // A lone ask reads better as ‹Prompt› than quoted.
            if argument.segments.count == 1, case .ask = argument.segments[0] {
                return render(argument.segments)
            }
            return Self.displayQuoted(render(argument.segments))
        }).joined(separator: " ")
    }

    /// Preview for the raw text, or the reason it would not run.
    public static func preview(_ text: String, context: Context?) -> String {
        do {
            return try HerdrCommand(parsing: text).preview(context: context)
        } catch {
            return error.localizedDescription
        }
    }

    /// Quotes an argument for display the way a shell would need it.
    static func displayQuoted(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let plain = argument.allSatisfy { !$0.isWhitespace && !"'\"\\$`;&|<>()*?!#~".contains($0) }
        if plain { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Examples

    public struct Example: Identifiable, Hashable, Sendable {
        public var title: String
        public var command: String
        public var id: String { command }
    }

    /// Ready-made commands for an editor's Examples menu. Every one's syntax
    /// is checked against Herdr 0.9.5's own usage text.
    public static let examples: [Example] = [
        Example(title: "Rename current tab", command: "tab rename {tab} {ask:New tab name={tab_label}}"),
        Example(title: "New tab", command: "tab create --focus"),
        Example(title: "Rename current workspace",
                command: "workspace rename {workspace} {ask:New workspace name={workspace_label}}"),
        Example(title: "New workspace", command: "workspace create --focus"),
        Example(title: "Rename current pane", command: "pane rename {pane} {ask:New pane name}"),
        Example(title: "Show notification", command: "notification show {ask:Notification}"),
    ]

    /// One line per placeholder, for help text.
    public static var placeholderHelp: String {
        (Placeholder.allCases.map { "\($0.token) — \($0.summary)" }
            + ["{ask:Prompt} or {ask:Prompt=Default} — asks you for text when pressed"])
            .joined(separator: "\n")
    }

    // MARK: - Tokenizer

    private struct Parser {
        let chars: [Character]
        var index = 0

        init(_ chars: [Character]) { self.chars = chars }

        mutating func arguments() throws -> [Argument] {
            var result: [Argument] = []
            var segments: [Segment] = []
            var literal = ""
            var inWord = false

            func flushLiteral() {
                if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
            }
            func endWord() {
                flushLiteral()
                if inWord { result.append(Argument(segments: segments.isEmpty ? [.literal("")] : segments)) }
                segments = []
                inWord = false
            }

            while index < chars.count {
                let ch = chars[index]
                if ch.isWhitespace {
                    endWord()
                    index += 1
                    continue
                }
                inWord = true
                switch ch {
                case "'":
                    index += 1
                    guard let close = chars[index...].firstIndex(of: "'") else {
                        throw Failure.syntax("a ' quote is not closed.")
                    }
                    literal += String(chars[index..<close])
                    index = close + 1
                case "\"":
                    index += 1
                    var closed = false
                    while index < chars.count {
                        let c = chars[index]
                        if c == "\"" { closed = true; index += 1; break }
                        if c == "\\", index + 1 < chars.count, "\"\\{}$`".contains(chars[index + 1]) {
                            literal.append(chars[index + 1]); index += 2; continue
                        }
                        if c == "{" {
                            flushLiteral()
                            segments.append(try placeholder())
                            continue
                        }
                        literal.append(c); index += 1
                    }
                    guard closed else { throw Failure.syntax("a \" quote is not closed.") }
                case "\\":
                    if index + 1 < chars.count {
                        let next = chars[index + 1]
                        // Backslash-newline continues the line.
                        if next != "\n" { literal.append(next) }
                        index += 2
                    } else {
                        literal.append("\\"); index += 1
                    }
                case "{":
                    flushLiteral()
                    segments.append(try placeholder())
                case "}":
                    throw Failure.syntax("a } has no matching {. Put literal braces in single quotes.")
                default:
                    literal.append(ch); index += 1
                }
            }
            endWord()
            return result
        }

        /// Reads `{…}` at `index`, braces balanced, and returns its segment.
        mutating func placeholder() throws -> Segment {
            let start = index
            index += 1
            var depth = 1
            var body = ""
            while index < chars.count {
                let c = chars[index]
                if c == "\\", index + 1 < chars.count {
                    body.append(c); body.append(chars[index + 1]); index += 2; continue
                }
                if c == "{" { depth += 1 }
                if c == "}" {
                    depth -= 1
                    if depth == 0 { index += 1; break }
                }
                body.append(c); index += 1
            }
            guard depth == 0 else {
                throw Failure.syntax("“\(String(chars[start...]))” is missing its closing }.")
            }
            return try Self.segment(forPlaceholder: body)
        }

        static func segment(forPlaceholder body: String) throws -> Segment {
            if body.lowercased().hasPrefix("ask:") {
                let rest = String(body.dropFirst(4))
                let prompt: String
                var defaultSegments: [Segment] = []
                if let equals = topLevelEquals(in: rest) {
                    prompt = String(rest[..<equals])
                    defaultSegments = try defaultValue(String(rest[rest.index(after: equals)...]))
                } else {
                    prompt = rest
                }
                let trimmed = prompt.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { throw Failure.syntax("{ask:…} needs a prompt, e.g. {ask:New tab name}.") }
                return .ask(prompt: trimmed, defaultValue: defaultSegments)
            }
            let name = body.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw Failure.syntax("{} is empty. Use a placeholder such as {tab}.") }
            guard let placeholder = Placeholder(rawValue: name.lowercased()) else {
                throw Failure.unknownPlaceholder(name)
            }
            return .value(placeholder)
        }

        /// The first `=` outside nested braces.
        static func topLevelEquals(in text: String) -> String.Index? {
            var depth = 0
            var escaped = false
            for index in text.indices {
                let c = text[index]
                if escaped { escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "{" { depth += 1 }
                if c == "}" { depth -= 1 }
                if c == "=", depth == 0 { return index }
            }
            return nil
        }

        /// An ask's default: literal text with placeholders, no nested ask.
        static func defaultValue(_ text: String) throws -> [Segment] {
            let chars = Array(text)
            var segments: [Segment] = []
            var literal = ""
            var index = 0
            while index < chars.count {
                let c = chars[index]
                if c == "\\", index + 1 < chars.count {
                    literal.append(chars[index + 1]); index += 2; continue
                }
                if c == "{" {
                    guard let close = chars[index...].firstIndex(of: "}") else {
                        throw Failure.syntax("a placeholder in an {ask:…} default is not closed.")
                    }
                    let body = String(chars[(index + 1)..<close])
                    let segment = try segment(forPlaceholder: body)
                    if case .ask = segment { throw Failure.syntax("an {ask:…} default cannot ask again.") }
                    if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
                    segments.append(segment)
                    index = close + 1
                    continue
                }
                literal.append(c); index += 1
            }
            if !literal.isEmpty { segments.append(.literal(literal)) }
            return segments
        }
    }
}

// MARK: - The herdr binary

/// Finds and runs the `herdr` command-line program.
public enum HerdrCLI {

    /// Where `herdr` is looked for, after `$WL_HERDR_PATH`, in order. An app
    /// launched by launchd has a minimal PATH, so the usual install places
    /// are checked by hand before asking a login shell.
    public static func candidatePaths(home: String) -> [String] {
        [
            (home as NSString).appendingPathComponent(".local/bin/herdr"),
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            (home as NSString).appendingPathComponent(".cargo/bin/herdr"),
        ]
    }

    /// The first executable `herdr`: `WL_HERDR_PATH`, the candidate paths,
    /// then `shellLookup` (a login shell's `command -v herdr`).
    public static func locate(
        environment: [String: String],
        home: String,
        isExecutable: (String) -> Bool,
        shellLookup: () -> String?
    ) -> String? {
        if let explicit = environment["WL_HERDR_PATH"], !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            if isExecutable(expanded) { return expanded }
        }
        if let found = candidatePaths(home: home).first(where: isExecutable) { return found }
        if let found = shellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
           found.hasPrefix("/"), isExecutable(found) {
            return found
        }
        return nil
    }

    private static let cache = PathCache()
    private static let discovery = Discovery()

    /// How many times discovery actually probed the disk (and maybe a login
    /// shell). For tests: rendering and previews must never move it.
    static var discoveryCount: Int { cache.discoveries }

    /// The `herdr` to run, off the caller's thread: cached after the first
    /// hit, and concurrent callers share one lookup. This is the only way
    /// the bridge finds the binary — never from a view.
    public static func resolvedBinaryPath() async -> String? {
        if let cached = cache.value { return cached }
        return await discovery.path()
    }

    /// The `herdr` to run, found once and then cached. A miss is not cached,
    /// so installing Herdr works without relaunching. Blocks — it may start
    /// a login shell — so call `resolvedBinaryPath()` instead.
    static func binaryPath() -> String? {
        if let cached = cache.value { return cached }
        cache.noteDiscovery()
        let manager = FileManager.default
        let found = locate(
            environment: ProcessInfo.processInfo.environment,
            home: NSHomeDirectory(),
            isExecutable: { manager.isExecutableFile(atPath: $0) },
            shellLookup: loginShellLookup
        )
        if let found { cache.value = found }
        return found
    }

    /// Forgets the cached path, e.g. after a run failed to spawn it.
    public static func resetCache() { cache.value = nil }

    /// `/bin/zsh -lc 'command -v herdr'`, bounded to a few seconds. Blocks.
    ///
    /// The pipe is read without blocking, while zsh runs and once more after
    /// it exits: a background job started by `.zprofile`/`.zlogin` inherits
    /// stdout and keeps the write end open, so reading to end-of-file could
    /// wait forever.
    static func loginShellLookup() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v herdr"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        do { try process.run() } catch { return nil }
        var output = Data()
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { return }
                output.append(contentsOf: buffer[0..<n])
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            drain()
            usleep(20_000)
        }
        if process.isRunning { process.terminate(); return nil }
        drain()
        try? pipe.fileHandleForReading.close()
        guard process.terminationStatus == 0 else { return nil }
        return lastPath(in: String(decoding: output, as: UTF8.self))
    }

    /// The last line that is an absolute path: login files may print a
    /// banner before `command -v` does.
    static func lastPath(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    public static let defaultTimeout: TimeInterval = 10

    /// The environment `herdr` runs with: this process's, pointed at the
    /// socket the bridge uses.
    public static func environment(
        socketPath: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["HERDR_SOCKET_PATH"] = socketPath
        return environment
    }

    /// Runs `herdr <arguments>` directly — no shell — and returns its output.
    /// Throws `HerdrCommand.Failure` with Herdr's own error message on a
    /// non-zero exit.
    /// `binary` overrides discovery (`binaryPath()`).
    @discardableResult
    public static func run(
        _ arguments: [String],
        socketPath: String = HerdrClient.socketPath(),
        binary: String? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> String {
        let path: String
        if let binary {
            path = binary
        } else {
            // Discovery may start a login shell; it runs off the caller's thread.
            guard let found = await resolvedBinaryPath() else { throw HerdrCommand.Failure.binaryNotFound }
            path = found
        }
        do {
            let result = try await SystemActions.runProcess(
                path, arguments: arguments,
                environment: environment(socketPath: socketPath),
                timeout: timeout
            )
            return result.output
        } catch let failure as SystemActions.Failure {
            switch failure {
            case .commandFailed(let status, let output):
                throw HerdrCommand.Failure.failed(status: status, message: errorMessage(fromOutput: output))
            case .commandTimedOut(let seconds):
                throw HerdrCommand.Failure.timedOut(seconds)
            default:
                throw failure
            }
        } catch let error as POSIXError where error.code == .ENOENT || error.code == .EACCES {
            if binary == nil { resetCache() }
            throw HerdrCommand.Failure.binaryNotFound
        }
    }

    /// Herdr's error message from its output: the `message` of a JSON error
    /// (`{"error":{"code":…,"message":…}}`) when there is one, else the text.
    public static func errorMessage(fromOutput output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for candidate in [output] + lines {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["error: ", "Error: "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text
    }

    /// One detached lookup at a time; callers that arrive meanwhile wait
    /// for its answer instead of starting another login shell.
    private actor Discovery {
        private var inFlight: Task<String?, Never>?

        func path() async -> String? {
            if let inFlight { return await inFlight.value }
            let task = Task.detached(priority: .userInitiated) { HerdrCLI.binaryPath() }
            inFlight = task
            let found = await task.value
            inFlight = nil
            return found
        }
    }

    private final class PathCache: @unchecked Sendable {
        private var stored: String?
        private var lookups = 0
        private let lock = NSLock()
        var discoveries: Int { lock.lock(); defer { lock.unlock() }; return lookups }
        func noteDiscovery() { lock.lock(); lookups += 1; lock.unlock() }
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }
}
