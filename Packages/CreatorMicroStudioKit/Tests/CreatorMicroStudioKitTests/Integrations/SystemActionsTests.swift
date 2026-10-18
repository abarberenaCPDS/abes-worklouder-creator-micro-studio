import XCTest
@testable import CreatorMicroStudioKit

/// The parsing half of the system actions. Nothing here posts an event or
/// opens anything; the one process it runs is `/bin/sh`.
final class SystemActionsTests: XCTestCase {

    typealias Chord = SystemActions.KeyChord

    func testShortcutsParse() {
        XCTAssertEqual(Chord.parse("cmd+shift+k"), Chord(keyCode: 0x28, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(Chord.parse("Ctrl + Alt + Delete"),
                       Chord(keyCode: 0x33, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(Chord.parse("pageup"), Chord(keyCode: 0x74))
        XCTAssertEqual(Chord.parse("page-down"), Chord(keyCode: 0x79))
        XCTAssertEqual(Chord.parse("f5"), Chord(keyCode: 0x60))
        XCTAssertEqual(Chord.parse("F12"), Chord(keyCode: 0x6F))
        XCTAssertEqual(Chord.parse("return"), Chord(keyCode: 0x24))
        XCTAssertEqual(Chord.parse("left"), Chord(keyCode: 0x7B))
        XCTAssertEqual(Chord.parse("⌘+⇧+4"), Chord(keyCode: 0x15, flags: [.maskCommand, .maskShift]))
        XCTAssertEqual(Chord.parse("cmd++"), Chord(keyCode: 0x18, flags: [.maskCommand]))
        XCTAssertEqual(Chord.parse("option+space"), Chord(keyCode: 0x31, flags: [.maskAlternate]))
    }

    func testBadShortcutsAreRejected() {
        XCTAssertNil(Chord.parse(""))
        XCTAssertNil(Chord.parse("cmd+shift"), "modifiers alone")
        XCTAssertNil(Chord.parse("cmd+k+j"), "two keys")
        XCTAssertNil(Chord.parse("hyper+k"))
        XCTAssertNil(Chord.parse("f99"))
    }

    func testEveryFunctionKeyAndLetterIsKnown() {
        for number in 1...20 { XCTAssertNotNil(Chord.parse("f\(number)"), "f\(number)") }
        for letter in "abcdefghijklmnopqrstuvwxyz0123456789" {
            XCTAssertNotNil(Chord.parse(String(letter)), String(letter))
        }
    }

    func testScrollDeltas() {
        XCTAssertEqual(SystemActions.scrollDeltas(.up, lines: 3).vertical, 3)
        XCTAssertEqual(SystemActions.scrollDeltas(.down, lines: 3).vertical, -3)
        XCTAssertEqual(SystemActions.scrollDeltas(.left, lines: 2).horizontal, 2)
        XCTAssertEqual(SystemActions.scrollDeltas(.right, lines: 2).horizontal, -2)
        XCTAssertEqual(SystemActions.scrollDeltas(.down, lines: 99).vertical, -20, "clamped")
        XCTAssertEqual(SystemActions.scrollDeltas(.up, lines: 0).vertical, 1, "at least one line")
    }

    func testMediaKeysMapToSystemKeyTypes() {
        XCTAssertEqual(SystemActions.systemKeyType(.playPause), 16)
        XCTAssertEqual(SystemActions.systemKeyType(.next), 17)
        XCTAssertEqual(SystemActions.systemKeyType(.previous), 18)
        XCTAssertEqual(SystemActions.systemKeyType(.volumeUp), 0)
        XCTAssertEqual(SystemActions.systemKeyType(.volumeDown), 1)
        XCTAssertEqual(SystemActions.systemKeyType(.mute), 7)
        XCTAssertEqual(SystemActions.systemKeyType(.brightnessUp), 2)
        XCTAssertEqual(SystemActions.systemKeyType(.brightnessDown), 3)
    }

    func testTypingChunksNeverSplitASurrogatePair() {
        let text = String(repeating: "a", count: 19) + "😀" + "bc"
        let chunks = SystemActions.utf16Chunks(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 19)
        XCTAssertEqual(String(utf16CodeUnits: chunks[1], count: chunks[1].count), "😀bc")
        XCTAssertEqual(chunks.joined().count, text.utf16.count)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
    }

    func testLaunchTargets() {
        XCTAssertEqual(SystemActions.launchTarget("https://example.com/a"),
                       .url(URL(string: "https://example.com/a")!))
        XCTAssertEqual(SystemActions.launchTarget("mailto:a@b.c"), .url(URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(SystemActions.launchTarget("/Applications/Safari.app"),
                       .file(URL(fileURLWithPath: "/Applications/Safari.app")))
        XCTAssertEqual(SystemActions.launchTarget("~/notes.md"),
                       .file(URL(fileURLWithPath: (("~/notes.md") as NSString).expandingTildeInPath)))
        XCTAssertEqual(SystemActions.launchTarget("com.apple.Terminal"), .bundleIdentifier("com.apple.Terminal"))
        XCTAssertEqual(SystemActions.launchTarget("Safari"), .applicationName("Safari"))
        XCTAssertEqual(SystemActions.launchTarget("Visual Studio Code.app"), .applicationName("Visual Studio Code"))
        XCTAssertNil(SystemActions.launchTarget("   "))
    }

    // MARK: - Shell

    func testShellSuccessReturnsOutput() async throws {
        let result = try await SystemActions.runShell("echo hello", shell: "/bin/sh", arguments: ["-c"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testShellFailureCarriesStatusAndOutput() async {
        do {
            _ = try await SystemActions.runShell("echo broken >&2; exit 3", shell: "/bin/sh", arguments: ["-c"])
            XCTFail("expected a failure")
        } catch let failure as SystemActions.Failure {
            guard case .commandFailed(let status, let output) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 3)
            XCTAssertTrue(output.contains("broken"))
            XCTAssertTrue(failure.localizedDescription.contains("status 3"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testShellTimesOut() async {
        do {
            _ = try await SystemActions.runShell("sleep 5", shell: "/bin/sh", arguments: ["-c"], timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SystemActions.Failure, .commandTimedOut(0.3))
        }
    }

    /// The timeout kills the whole process group, not just the shell: a
    /// child the shell is waiting on goes too, and the error comes promptly.
    func testShellTimeoutKillsTheProcessGroup() async throws {
        let pidFile = NSTemporaryDirectory() + "shell-timeout-\(UUID().uuidString).pid"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let started = Date()
        do {
            _ = try await SystemActions.runShell(
                "sleep 30 & echo $! > '\(pidFile)'; wait; echo done",
                shell: "/bin/sh", arguments: ["-c"], timeout: 0.5, killGrace: 0.5)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SystemActions.Failure, .commandTimedOut(0.5))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let text = try String(contentsOfFile: pidFile, encoding: .utf8)
        let child = try XCTUnwrap(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Killed children are reaped by launchd; allow a moment for that.
        let deadline = Date().addingTimeInterval(3)
        while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotEqual(kill(child, 0), 0, "the background sleep survived the timeout")
    }

    /// A shell that traps SIGTERM still stops: SIGKILL follows the grace.
    func testShellTimeoutEscalatesToKill() async {
        let started = Date()
        do {
            _ = try await SystemActions.runShell(
                "trap '' TERM; while :; do sleep 0.1; done",
                shell: "/bin/sh", arguments: ["-c"], timeout: 0.3, killGrace: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? SystemActions.Failure, .commandTimedOut(0.3))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// A command that leaves a child running in the background, still holding
    /// the output pipe, finishes when the shell exits rather than when the child does.
    func testShellWithBackgroundChildFinishesPromptly() async throws {
        let started = Date()
        let result = try await SystemActions.runShell(
            "sleep 20 & echo $!", shell: "/bin/sh", arguments: ["-c"], timeout: 10)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let child = try XCTUnwrap(pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(child, 0), 0, "the background child should keep running")
        kill(child, SIGKILL)
    }

    func testEmptyParametersAreReported() async {
        do {
            _ = try await SystemActions.runShell("  ")
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? SystemActions.Failure, .emptyParameter("command"))
        }
        XCTAssertThrowsError(try SystemActions.keyboardShortcut("")) { error in
            XCTAssertEqual(error as? SystemActions.Failure, .emptyParameter("shortcut"))
        }
        XCTAssertThrowsError(try SystemActions.keyboardShortcut("cmd+nope")) { error in
            XCTAssertEqual(error as? SystemActions.Failure, .unknownShortcut("cmd+nope"))
        }
    }
}
