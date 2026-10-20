import XCTest
@testable import CreatorMicroStudioKit

final class TerminalTargetTests: XCTestCase {

    private let iterm = "com.googlecode.iterm2"
    private let ghostty = "com.mitchellh.ghostty"

    // MARK: - Override

    func testExplicitOverrideWins() {
        let resolved = TerminalTarget.resolve(
            override: ghostty,
            processes: [.init(pid: 2, parentPID: 1, name: "herdr")],
            apps: [.init(pid: 1, bundleID: iterm)],
            knownBundleIDs: [iterm]
        )
        XCTAssertEqual(resolved, ghostty)
    }

    func testBlankOverrideIsIgnored() {
        let resolved = TerminalTarget.resolve(
            override: "   ",
            processes: [],
            apps: [.init(pid: 1, bundleID: iterm)],
            knownBundleIDs: [iterm]
        )
        XCTAssertEqual(resolved, iterm)
    }

    // MARK: - Detection from the client

    func testFindsTheGuiAncestorOfTheHerdrClient() {
        // herdr → zsh → login → iTermServer → iTerm2, as on a real machine.
        let processes: [TerminalTarget.Process] = [
            .init(pid: 500, parentPID: 490, name: "herdr"),
            .init(pid: 490, parentPID: 480, name: "zsh"),
            .init(pid: 480, parentPID: 470, name: "login"),
            .init(pid: 470, parentPID: 400, name: "iTermServer"),
            .init(pid: 400, parentPID: 1, name: "iTerm2"),
        ]
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: processes,
            apps: [.init(pid: 400, bundleID: iterm)],
            knownBundleIDs: [ghostty, iterm]
        )
        XCTAssertEqual(resolved, iterm)
    }

    func testSkipsTheHeadlessServerAndFindsTheClient() {
        // The server's parent is launchd (no GUI app); the client's is not.
        let processes: [TerminalTarget.Process] = [
            .init(pid: 300, parentPID: 1, name: "herdr"),     // server
            .init(pid: 500, parentPID: 490, name: "herdr"),   // client
            .init(pid: 490, parentPID: 400, name: "zsh"),
            .init(pid: 400, parentPID: 1, name: "Ghostty"),
        ]
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: processes,
            apps: [.init(pid: 400, bundleID: ghostty)],
            knownBundleIDs: [iterm]
        )
        XCTAssertEqual(resolved, ghostty)
    }

    func testPrefersTheNewestClientWhenSeveralEachHaveAHost() {
        let processes: [TerminalTarget.Process] = [
            .init(pid: 200, parentPID: 150, name: "herdr"),   // older
            .init(pid: 150, parentPID: 100, name: "zsh"),
            .init(pid: 100, parentPID: 1, name: "Ghostty"),
            .init(pid: 900, parentPID: 850, name: "herdr"),   // newer
            .init(pid: 850, parentPID: 800, name: "zsh"),
            .init(pid: 800, parentPID: 1, name: "iTerm2"),
        ]
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: processes,
            apps: [
                .init(pid: 100, bundleID: ghostty),
                .init(pid: 800, bundleID: iterm),
            ],
            knownBundleIDs: [ghostty, iterm]
        )
        XCTAssertEqual(resolved, iterm)
    }

    func testFallsThroughAClientWithNoHostToARealOne() {
        let processes: [TerminalTarget.Process] = [
            .init(pid: 900, parentPID: 890, name: "herdr"),   // detached, no app
            .init(pid: 890, parentPID: 1, name: "zsh"),
            .init(pid: 500, parentPID: 490, name: "herdr"),   // in Ghostty
            .init(pid: 490, parentPID: 400, name: "zsh"),
            .init(pid: 400, parentPID: 1, name: "Ghostty"),
        ]
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: processes,
            apps: [.init(pid: 400, bundleID: ghostty)],
            knownBundleIDs: [iterm]
        )
        XCTAssertEqual(resolved, ghostty)
    }

    func testSurvivesAParentCycle() {
        let processes: [TerminalTarget.Process] = [
            .init(pid: 500, parentPID: 490, name: "herdr"),
            .init(pid: 490, parentPID: 490, name: "zsh"),
        ]
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: processes,
            apps: [.init(pid: 400, bundleID: ghostty)],
            knownBundleIDs: [ghostty]
        )
        XCTAssertEqual(resolved, ghostty, "a broken ancestry still falls back to a running terminal")
    }

    // MARK: - Fallback

    func testFallsBackToTheFirstRunningKnownTerminal() {
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: [],
            apps: [
                .init(pid: 1, bundleID: iterm),
                .init(pid: 2, bundleID: ghostty),
            ],
            knownBundleIDs: [ghostty, iterm]
        )
        XCTAssertEqual(resolved, ghostty, "known order decides, not the app table order")
    }

    func testReturnsNilWhenNothingCanBeFound() {
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: [.init(pid: 500, parentPID: 490, name: "herdr")],
            apps: [.init(pid: 42, bundleID: "com.apple.finder")],
            knownBundleIDs: [ghostty, iterm]
        )
        XCTAssertNil(resolved)
    }

    func testReturnsNilWhenOnlyAnUnknownAppRuns() {
        let resolved = TerminalTarget.resolve(
            override: nil,
            processes: [.init(pid: 10, parentPID: 1, name: "zsh")],
            apps: [.init(pid: 10, bundleID: iterm)],
            knownBundleIDs: [ghostty]
        )
        XCTAssertNil(resolved, "an app outside the known list is not raised")
    }
}
