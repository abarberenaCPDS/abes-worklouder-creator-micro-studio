import XCTest
@testable import CreatorMicroStudioKit

/// Herdr command lines: parsing, placeholders, asks, legacy values, binary
/// discovery and execution. Nothing here talks to Herdr; execution uses fake
/// `herdr` scripts in a temporary folder.
@MainActor
final class HerdrCommandTests: XCTestCase {

    private typealias Segment = HerdrCommand.Segment

    private func args(_ text: String) throws -> [[Segment]] {
        try HerdrCommand(parsing: text).arguments.map(\.segments)
    }

    private func literalArgs(_ text: String) throws -> [String] {
        try HerdrCommand(parsing: text).arguments.map { argument in
            argument.segments.map { segment -> String in
                if case .literal(let text) = segment { return text }
                XCTFail("not literal: \(segment)")
                return ""
            }.joined()
        }
    }

    private let context = HerdrCommand.Context(
        pane: "w1:p3", tab: "w1:t2", workspace: "w1",
        tabLabel: "api work", workspaceLabel: "abes-work-louder", agent: "worker"
    )

    // MARK: - Tokenizer

    func testSplitsOnWhitespace() throws {
        XCTAssertEqual(try literalArgs("tab   create\t--focus"), ["tab", "create", "--focus"])
    }

    func testSingleQuotesAreLiteralIncludingBracesAndBackslashes() throws {
        XCTAssertEqual(try literalArgs(#"notification show 'a {tab} \n b'"#),
                       ["notification", "show", #"a {tab} \n b"#])
    }

    func testDoubleQuotesGroupAndHonourEscapes() throws {
        XCTAssertEqual(try literalArgs(#"notification show "say \"hi\" \\ \{x\}""#),
                       ["notification", "show", #"say "hi" \ {x}"#])
        // Other backslashes inside double quotes are kept, as in a shell.
        XCTAssertEqual(try literalArgs(#"notification show "a\nb""#), ["notification", "show", #"a\nb"#])
    }

    func testBackslashEscapesOutsideQuotes() throws {
        XCTAssertEqual(try literalArgs(#"notification show hello\ world \{tab\}"#),
                       ["notification", "show", "hello world", "{tab}"])
    }

    func testAdjacentPiecesJoinIntoOneArgument() throws {
        XCTAssertEqual(try literalArgs(#"tab create --label=a'b c'"d e""#),
                       ["tab", "create", "--label=ab cd e"])
    }

    func testEmptyQuotedArgumentIsKept() throws {
        XCTAssertEqual(try literalArgs(#"notification show "" --body ''"#),
                       ["notification", "show", "", "--body", ""])
    }

    func testLeadingHerdrIsDropped() throws {
        XCTAssertEqual(try literalArgs("herdr tab create --focus"), ["tab", "create", "--focus"])
    }

    func testEmptyAndBlankAreRejected() {
        for text in ["", "   ", "herdr"] {
            XCTAssertThrowsError(try HerdrCommand(parsing: text), text) { error in
                XCTAssertEqual(error as? HerdrCommand.Failure, .empty, text)
            }
        }
    }

    func testUnclosedQuotesAndBracesAreSyntaxErrors() {
        for text in ["tab rename 'oops", #"tab rename "oops"#, "tab rename {tab", "tab rename tab}",
                     "tab rename {}", "tab rename {ask:}"] {
            XCTAssertThrowsError(try HerdrCommand(parsing: text), text) { error in
                guard case .syntax = error as? HerdrCommand.Failure else {
                    return XCTFail("\(text): \(error)")
                }
            }
        }
    }

    // MARK: - Placeholders

    func testPlaceholdersParse() throws {
        XCTAssertEqual(try args("tab rename {tab} {tab_label}-copy"), [
            [.literal("tab")], [.literal("rename")], [.value(.tab)], [.value(.tabLabel), .literal("-copy")],
        ])
        XCTAssertEqual(try HerdrCommand(parsing: "x {pane} {workspace} {workspace_label} {agent}").placeholders,
                       [.pane, .workspace, .workspaceLabel, .agent])
    }

    func testPlaceholdersWorkInDoubleQuotesButNotSingle() throws {
        XCTAssertEqual(try args(#"notification show "on {tab_label}!" '{tab}'"#), [
            [.literal("notification")], [.literal("show")],
            [.literal("on "), .value(.tabLabel), .literal("!")], [.literal("{tab}")],
        ])
    }

    func testUnknownPlaceholderIsNamed() {
        XCTAssertThrowsError(try HerdrCommand(parsing: "tab rename {tabb} x")) { error in
            XCTAssertEqual(error as? HerdrCommand.Failure, .unknownPlaceholder("tabb"))
            XCTAssertTrue(error.localizedDescription.contains("{tab_label}"))
        }
    }

    func testAskWithSpacesAndDefaultContainingPlaceholder() throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} {ask:New tab name={tab_label}}")
        XCTAssertEqual(command.arguments.map(\.segments), [
            [.literal("tab")], [.literal("rename")], [.value(.tab)],
            [.ask(prompt: "New tab name", defaultValue: [.value(.tabLabel)])],
        ])
        XCTAssertEqual(command.placeholders, [.tab, .tabLabel])
        XCTAssertTrue(command.asksForText)
    }

    func testAskDefaultMixesTextAndPlaceholders() throws {
        XCTAssertEqual(try args("x {ask:Name=copy of {tab_label} (2)}"), [
            [.literal("x")],
            [.ask(prompt: "Name", defaultValue: [.literal("copy of "), .value(.tabLabel), .literal(" (2)")])],
        ])
    }

    func testAskCannotNestAnotherAsk() {
        XCTAssertThrowsError(try HerdrCommand(parsing: "x {ask:A={ask:B}}"))
    }

    // MARK: - Resolving

    func testResolveSubstitutesAsSingleArguments() async throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} {ask:New tab name={tab_label}}")
        var asked: [(String, String)] = []
        let resolved = try await command.resolve(context: context) { prompt, defaultText in
            asked.append((prompt, defaultText))
            return "it's $(rm -rf ~); `x` \"y\""
        }
        XCTAssertEqual(resolved, ["tab", "rename", "w1:t2", "it's $(rm -rf ~); `x` \"y\""])
        XCTAssertEqual(asked.map(\.0), ["New tab name"])
        XCTAssertEqual(asked.map(\.1), ["api work"], "the default has its placeholder filled in")
    }

    func testCancelledAskReturnsNil() async throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} {ask:New tab name}")
        let resolved = try await command.resolve(context: context) { _, _ in nil }
        XCTAssertNil(resolved)
    }

    func testRepeatedAskPromptIsAskedOnce() async throws {
        let command = try HerdrCommand(parsing: "x {ask:Name} --label {ask:Name}")
        var count = 0
        let resolved = try await command.resolve(context: context) { _, _ in count += 1; return "n" }
        XCTAssertEqual(resolved, ["x", "n", "--label", "n"])
        XCTAssertEqual(count, 1)
    }

    func testAskWithoutAskerFails() async throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} {ask:New tab name}")
        do {
            _ = try await command.resolve(context: context, ask: nil)
            XCTFail("expected cannotAsk")
        } catch {
            XCTAssertEqual(error as? HerdrCommand.Failure, .cannotAsk)
        }
    }

    func testMissingFocusFailsClearly() async throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} x")
        do {
            _ = try await command.resolve(context: HerdrCommand.Context(), ask: nil)
            XCTFail("expected missing")
        } catch {
            XCTAssertEqual(error as? HerdrCommand.Failure, .missing(.tab))
            XCTAssertEqual(error.localizedDescription, "Herdr has no focused tab right now, so {tab} has no value.")
        }
    }

    func testPrepareOnlyFetchesWhenPlaceholdersAreUsed() async throws {
        var fetches: [Set<HerdrCommand.Placeholder>] = []
        let provider: (Set<HerdrCommand.Placeholder>) async throws -> HerdrCommand.Context = { needs in
            fetches.append(needs)
            return self.context
        }
        let plain = try await HerdrCommand.prepare("tab create --focus", context: provider, ask: nil)
        XCTAssertEqual(plain, ["tab", "create", "--focus"])
        XCTAssertTrue(fetches.isEmpty)

        let renamed = try await HerdrCommand.prepare("workspace rename {workspace} {ask:Name={workspace_label}}",
                                                     context: provider) { _, value in value + "!" }
        XCTAssertEqual(renamed, ["workspace", "rename", "w1", "abes-work-louder!"])
        XCTAssertEqual(fetches, [[.workspace, .workspaceLabel]])
    }

    // MARK: - The current tab

    func testCurrentTabIsTheFocusedTabOfTheFocusedWorkspaceNotTheAgentsTab() {
        let workspaces = [
            HerdrWorkspace(workspaceID: "w1", number: 1, label: "one", activeTabID: "w1:t1"),
            HerdrWorkspace(workspaceID: "w2", number: 2, label: "two", focused: true, activeTabID: "w2:t3"),
        ]
        let tabs = [
            HerdrTab(tabID: "w1:t1", workspaceID: "w1", number: 1, focused: true, label: "stale"),
            HerdrTab(tabID: "w2:t1", workspaceID: "w2", number: 1, label: "a"),
            HerdrTab(tabID: "w2:t3", workspaceID: "w2", number: 2, focused: true, label: "shell"),
        ]
        // The focused agent lives in another tab.
        let agent = HerdrAgent(status: "idle", paneID: "w1:p1", tabID: "w1:t1", workspaceID: "w1", focused: true)
        let current = HerdrCommand.Context.current(workspaces: workspaces, tabs: tabs,
                                                   currentPane: "w2:p9", focusedAgent: agent)
        XCTAssertEqual(current.tab, "w2:t3")
        XCTAssertEqual(current.tabLabel, "shell")
        XCTAssertEqual(current.workspace, "w2")
        XCTAssertEqual(current.workspaceLabel, "two")
        XCTAssertEqual(current.pane, "w2:p9", "pane.current wins over the agent's pane")
        XCTAssertEqual(current.agent, "w1:p1", "an unnamed agent is its pane id")
    }

    func testCurrentTabFallsBackToActiveTabAndLabelsDefault() {
        let workspaces = [HerdrWorkspace(workspaceID: "w1", number: 3, focused: true, activeTabID: "w1:t2")]
        let tabs = [HerdrTab(tabID: "w1:t2", workspaceID: "w1", number: 2)]
        let named = HerdrAgent(status: "idle", paneID: "w1:p1", focused: true, name: "reviewer")
        let current = HerdrCommand.Context.current(workspaces: workspaces, tabs: tabs, focusedAgent: named)
        XCTAssertEqual(current.tab, "w1:t2")
        XCTAssertEqual(current.tabLabel, "Tab 2")
        XCTAssertEqual(current.workspaceLabel, "Workspace 3")
        XCTAssertEqual(current.pane, "w1:p1", "the agent's pane stands in without pane.current")
        XCTAssertEqual(current.agent, "reviewer")
    }

    func testNothingFocusedGivesAnEmptyContext() {
        let current = HerdrCommand.Context.current(
            workspaces: [HerdrWorkspace(workspaceID: "w1", number: 1)],
            tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", number: 1)]
        )
        XCTAssertEqual(current, HerdrCommand.Context())
    }

    // MARK: - Legacy values

    func testKeybindingValueGetsTheHelpfulError() {
        XCTAssertThrowsError(try HerdrCommand(parsing: "prefix+shift+t")) { error in
            XCTAssertEqual(error as? HerdrCommand.Failure, .keybinding("prefix+shift+t"))
            XCTAssertEqual(error.localizedDescription,
                           "“prefix+shift+t” is a Herdr keybinding. Herdr commands look like: tab rename {tab} {ask:New tab name}")
        }
    }

    func testKeybindingAfterALeadingHerdrWordIsStillDetected() {
        XCTAssertEqual(HerdrCommand.legacyProblem("herdr prefix+shift+t"), .keybinding("prefix+shift+t"))
        XCTAssertEqual(HerdrCommand.legacyProblem("  herdr   workspace.new "), .commandID("workspace.new"))
        XCTAssertEqual(HerdrCommand.legacyProblem("herdr"), .empty)
        XCTAssertNil(HerdrCommand.legacyProblem("herdr status"))
        XCTAssertNil(HerdrCommand.legacyProblem("herdr tab rename {tab} x"))
        XCTAssertThrowsError(try HerdrCommand(parsing: "herdr prefix+shift+t")) { error in
            XCTAssertEqual(error as? HerdrCommand.Failure, .keybinding("prefix+shift+t"))
        }
    }

    func testOpaqueCommandIDIsRejected() {
        for text in ["workspace.new", "rename_tab", "abc123"] {
            XCTAssertEqual(HerdrCommand.legacyProblem(text), .commandID(text), text)
            XCTAssertTrue(HerdrCommand.validate(text)?.contains("tab rename {tab}") == true, text)
        }
    }

    func testRealCommandLinesAreNotLegacy() {
        for text in ["tab rename {tab} x", "status", "--version", "notification show 'a+b'", "pane send-keys {pane} ctrl+c"] {
            XCTAssertNil(HerdrCommand.legacyProblem(text), text)
        }
        XCTAssertNil(HerdrCommand.validate("tab rename {tab} {ask:New tab name={tab_label}}"))
    }

    func testLegacyValuesStillRoundTripThroughConfig() {
        let legacy = InputAction.parse(configValue: ["type": "herdr-command", "command_id": "prefix+shift+t"])
        XCTAssertEqual(legacy, .herdrCommand("prefix+shift+t"))
        let current = InputAction.herdrCommand("tab rename {tab} {ask:New tab name}")
        XCTAssertEqual(InputAction.parse(configValue: current.configValue), current)
        XCTAssertEqual(InputAction.Kind.herdrCommand.parameters, [.herdrCommand])
        XCTAssertEqual(InputAction.Parameter.herdrCommand.label, "Herdr command")
        XCTAssertTrue(InputAction.Parameter.herdrCommand.isMonospaced)
    }

    // MARK: - Preview and examples

    func testPreviewShowsResolvedValuesAndAsks() throws {
        let command = try HerdrCommand(parsing: "tab rename {tab} {ask:New tab name={tab_label}}")
        XCTAssertEqual(command.preview(context: context), "herdr tab rename w1:t2 ‹New tab name›")
        XCTAssertEqual(command.preview(context: nil), "herdr tab rename {tab} ‹New tab name›")
        XCTAssertEqual(HerdrCommand.preview("notification show {tab_label}", context: context),
                       "herdr notification show 'api work'")
        XCTAssertEqual(HerdrCommand.preview("prefix+shift+t", context: context),
                       HerdrCommand.Failure.keybinding("prefix+shift+t").errorDescription)
    }

    /// What the Controls editor calls while rendering: preview, validation,
    /// the legacy check and the context built from cached status. All of it
    /// must be pure string work — no binary discovery, no login shell, no
    /// socket — and give the same answer every time.
    func testPreviewAndValidationArePure() throws {
        let before = HerdrCLI.discoveryCount
        let status = HerdrStatus(
            socketPath: "/nonexistent/herdr.sock", socketSource: .defaultPath,
            workspaces: [HerdrWorkspace(workspaceID: "w1", number: 1, label: "main", focused: true)],
            tabs: [HerdrTab(tabID: "w1:t2", workspaceID: "w1", number: 2, focused: true, label: "api work")]
        )
        let lines = [
            "tab rename {tab} {ask:New tab name={tab_label}}",
            "workspace rename {workspace} {ask:New workspace name={workspace_label}}",
            "prefix+shift+t", "", "tab rename {nope}", "'unclosed",
        ]
        for _ in 0..<50 {
            let context = HerdrCommand.Context(status: status, agents: [])
            for line in lines {
                let first = HerdrCommand.preview(line, context: context)
                XCTAssertEqual(first, HerdrCommand.preview(line, context: context))
                _ = HerdrCommand.validate(line)
                _ = HerdrCommand.legacyProblem(line)
            }
        }
        XCTAssertEqual(HerdrCLI.discoveryCount, before, "rendering never looks for the herdr binary")
        XCTAssertEqual(HerdrCommand.preview(lines[0], context: HerdrCommand.Context(status: status, agents: [])),
                       "herdr tab rename w1:t2 ‹New tab name›")
    }

    func testDisplayQuoting() {
        XCTAssertEqual(HerdrCommand.displayQuoted("plain"), "plain")
        XCTAssertEqual(HerdrCommand.displayQuoted(""), "''")
        XCTAssertEqual(HerdrCommand.displayQuoted("it's"), #"'it'\''s'"#)
    }

    func testEveryExampleParsesAndIsNotLegacy() throws {
        XCTAssertEqual(HerdrCommand.examples.first?.command, "tab rename {tab} {ask:New tab name={tab_label}}")
        for example in HerdrCommand.examples {
            XCTAssertNoThrow(try HerdrCommand(parsing: example.command), example.title)
        }
        XCTAssertTrue(HerdrCommand.placeholderHelp.contains("{ask:Prompt}"))
    }

    // MARK: - Binary discovery

    func testLoginShellOutputTakesTheLastPathLine() {
        XCTAssertEqual(HerdrCLI.lastPath(in: "Welcome back!\n/Users/test/bin/herdr\n"), "/Users/test/bin/herdr")
        XCTAssertEqual(HerdrCLI.lastPath(in: "/etc/motd says hi\nnot a path\n/opt/x/herdr"), "/opt/x/herdr")
        XCTAssertNil(HerdrCLI.lastPath(in: "herdr not found\n"))
        XCTAssertNil(HerdrCLI.lastPath(in: ""))
    }

    func testDiscoveryOrder() {
        let home = "/Users/test"
        let all: Set<String> = [
            "/opt/wl/herdr", "/Users/test/.local/bin/herdr", "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr", "/Users/test/.cargo/bin/herdr", "/nix/herdr",
        ]
        var shellCalls = 0
        func locate(_ present: Set<String>, env: [String: String] = [:]) -> String? {
            HerdrCLI.locate(environment: env, home: home, isExecutable: { present.contains($0) },
                            shellLookup: { shellCalls += 1; return "/nix/herdr\n" })
        }
        XCTAssertEqual(locate(all, env: ["WL_HERDR_PATH": "/opt/wl/herdr"]), "/opt/wl/herdr")
        XCTAssertEqual(locate(all), "/Users/test/.local/bin/herdr")
        var rest = all.subtracting(["/Users/test/.local/bin/herdr"])
        XCTAssertEqual(locate(rest), "/opt/homebrew/bin/herdr")
        rest.remove("/opt/homebrew/bin/herdr")
        XCTAssertEqual(locate(rest), "/usr/local/bin/herdr")
        rest.remove("/usr/local/bin/herdr")
        XCTAssertEqual(locate(rest), "/Users/test/.cargo/bin/herdr")
        XCTAssertEqual(shellCalls, 0, "the login shell is the last resort")
        XCTAssertEqual(locate(["/nix/herdr"]), "/nix/herdr")
        XCTAssertEqual(shellCalls, 1)
        XCTAssertNil(locate([]))
        // A WL_HERDR_PATH that is not executable falls through.
        XCTAssertEqual(locate(["/usr/local/bin/herdr"], env: ["WL_HERDR_PATH": "/missing"]), "/usr/local/bin/herdr")
    }

    func testEnvironmentPointsAtTheBridgeSocket() {
        let env = HerdrCLI.environment(socketPath: "/tmp/h.sock", base: ["PATH": "/usr/bin", "HERDR_SOCKET_PATH": "/old"])
        XCTAssertEqual(env, ["PATH": "/usr/bin", "HERDR_SOCKET_PATH": "/tmp/h.sock"])
    }

    func testErrorMessageExtraction() {
        XCTAssertEqual(HerdrCLI.errorMessage(fromOutput: #"{"id":"x","error":{"code":"tab_not_found","message":"tab w9:t9 not found"}}"#),
                       "tab w9:t9 not found")
        XCTAssertEqual(HerdrCLI.errorMessage(fromOutput: "warming up\n{\"error\":\"bad target\"}\n"), "bad target")
        XCTAssertEqual(HerdrCLI.errorMessage(fromOutput: "error: usage: herdr tab rename <tab_id> <label>\n"),
                       "usage: herdr tab rename <tab_id> <label>")
    }

    // MARK: - Execution

    private func fakeHerdr(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wl-herdr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("herdr").path
        try ("#!/bin/sh\n" + body + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testArgumentsReachTheBinaryVerbatimWithoutAShell() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("wl-injected-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: marker) }
        let binary = try fakeHerdr(#"printf '%s\n' "$HERDR_SOCKET_PATH"; for a in "$@"; do printf '[%s]\n' "$a"; done"#)
        let hostile = "$(touch \(marker)); `touch \(marker)` && touch \(marker) | x > y 'q' \"d\""
        let output = try await HerdrCLI.run(["tab", "rename", "w1:t2", hostile, ""],
                                            socketPath: "/tmp/test herdr.sock", binary: binary)
        XCTAssertEqual(output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                       ["/tmp/test herdr.sock", "[tab]", "[rename]", "[w1:t2]", "[\(hostile)]", "[]", ""])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "nothing in an argument ran")
    }

    func testNonZeroExitSurfacesHerdrsMessage() async throws {
        let binary = try fakeHerdr(#"echo '{"error":{"code":"tab_not_found","message":"tab w9:t9 not found"}}' >&2; exit 3"#)
        do {
            try await HerdrCLI.run(["tab", "rename", "w9:t9", "x"], socketPath: "/tmp/s", binary: binary)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? HerdrCommand.Failure, .failed(status: 3, message: "tab w9:t9 not found"))
            XCTAssertEqual(error.localizedDescription, "Herdr: tab w9:t9 not found")
        }
    }

    func testTimeoutStopsTheBinary() async throws {
        let binary = try fakeHerdr("sleep 5")
        do {
            try await HerdrCLI.run(["tab", "list"], socketPath: "/tmp/s", binary: binary, timeout: 0.2)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? HerdrCommand.Failure, .timedOut(0.2))
        }
    }

    func testMissingBinaryIsReported() async {
        do {
            try await HerdrCLI.run(["tab", "list"], socketPath: "/tmp/s", binary: "/nonexistent/herdr")
            XCTFail("expected binaryNotFound")
        } catch {
            XCTAssertEqual(error as? HerdrCommand.Failure, .binaryNotFound)
        }
    }

    // MARK: - Bridge

    private func makeBridge() -> BridgeController {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wl-bridge-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return BridgeController(store: StudioConfigStore(path: directory.appendingPathComponent("config.json").path))
    }

    func testBridgeRunsTheResolvedCommandForTheCurrentTab() async {
        let bridge = makeBridge()
        var ran: [[String]] = []
        var asked: [String] = []
        bridge.herdrContextProvider = { _ in self.context }
        bridge.herdrCommandRunner = { ran.append($0) }
        bridge.onAsk = { prompt, defaultText in asked.append("\(prompt)|\(defaultText)"); return "renamed" }
        await bridge.runHerdrCommand("tab rename {tab} {ask:New tab name={tab_label}}")
        XCTAssertEqual(ran, [["tab", "rename", "w1:t2", "renamed"]])
        XCTAssertEqual(asked, ["New tab name|api work"])
        XCTAssertNil(bridge.lastActionError)
    }

    func testBridgeCancelledAskIsSilent() async {
        let bridge = makeBridge()
        var ran = 0
        bridge.herdrContextProvider = { _ in self.context }
        bridge.herdrCommandRunner = { _ in ran += 1 }
        bridge.onAsk = { _, _ in nil }
        await bridge.runHerdrCommand("tab rename {tab} {ask:New tab name}")
        XCTAssertEqual(ran, 0)
        XCTAssertNil(bridge.lastActionError)
    }

    func testBridgeReportsLegacyKeybindingWithoutRunningAnything() async {
        let bridge = makeBridge()
        var touched = false
        bridge.herdrContextProvider = { _ in touched = true; return self.context }
        bridge.herdrCommandRunner = { _ in touched = true }
        await bridge.runHerdrCommand("prefix+shift+t")
        XCTAssertFalse(touched)
        XCTAssertEqual(bridge.lastActionError,
                       "“prefix+shift+t” is a Herdr keybinding. Herdr commands look like: tab rename {tab} {ask:New tab name}")
    }

    func testBridgeReportsRunnerFailure() async {
        let bridge = makeBridge()
        bridge.herdrContextProvider = { _ in HerdrCommand.Context() }
        bridge.herdrCommandRunner = { _ in throw HerdrCommand.Failure.failed(status: 1, message: "nope") }
        await bridge.runHerdrCommand("tab create --focus")
        XCTAssertEqual(bridge.lastActionError, "Herdr: nope")
        await bridge.runHerdrCommand("tab rename {tab} x")
        XCTAssertEqual(bridge.lastActionError, "Herdr has no focused tab right now, so {tab} has no value.")
    }
}
