import XCTest
@testable import CreatorMicroStudioKit

/// The Herdr page's model, from fixed data — nothing here opens the socket.
final class HerdrStatusTests: XCTestCase {

    private func agents(_ count: Int) -> [HerdrAgent] {
        (0..<count).map { HerdrAgent(status: "idle", paneID: "w1:p\($0)", tabID: "w1:t1", workspaceID: "w1") }
    }

    func testAgentJSONKeepsNamesAndTitles() {
        let agent = HerdrAgent(json: [
            "agent": "claude", "agent_status": "working", "pane_id": "w1:p2",
            "name": "reviewer", "display_agent": "Claude Code", "title": "Fix the build",
            "cwd": "/tmp/api",
        ])
        XCTAssertEqual(agent.name, "reviewer")
        XCTAssertEqual(agent.displayAgent, "Claude Code")
        XCTAssertEqual(agent.title, "Fix the build")
        XCTAssertEqual(agent.displayName, "reviewer")
        XCTAssertEqual(agent.harnessName, "Claude Code")
        XCTAssertEqual(HerdrAgent(status: "idle", cwd: "/tmp/web").displayName, "web")
    }

    func testTabAndWorkspaceJSON() {
        let tab = HerdrTab(json: ["tab_id": "w1:t2", "workspace_id": "w1", "number": 2,
                                  "label": "review", "focused": true, "pane_count": 3, "agent_status": "done"])
        XCTAssertEqual(tab.label, "review")
        XCTAssertEqual(tab.paneCount, 3)
        XCTAssertEqual(tab.agentStatus, "done")
        XCTAssertEqual(HerdrTab(tabID: "t", number: 4).displayLabel, "Tab 4")

        let workspace = HerdrWorkspace(json: ["workspace_id": "w1", "number": 1, "label": "api",
                                              "focused": true, "tab_count": 2, "active_tab_id": "w1:t2"])
        XCTAssertEqual(workspace.label, "api")
        XCTAssertEqual(workspace.tabCount, 2)
        XCTAssertEqual(workspace.activeTabID, "w1:t2")
        XCTAssertEqual(HerdrWorkspace(workspaceID: "w", number: 3).displayLabel, "Workspace 3")
    }

    func testLocationReadsWorkspaceThenTab() {
        let status = HerdrStatus(
            workspaces: [HerdrWorkspace(workspaceID: "w1", number: 1, label: "api")],
            tabs: [HerdrTab(tabID: "w1:t1", workspaceID: "w1", number: 1, label: "main")]
        )
        let agent = HerdrAgent(status: "idle", tabID: "w1:t1", workspaceID: "w1")
        XCTAssertEqual(status.location(of: agent), "api › main")
        XCTAssertNil(status.location(of: HerdrAgent(status: "idle")))
    }

    func testSocketPathSources() {
        let explicit = HerdrClient.socketLocation(environment: ["HERDR_SOCKET_PATH": "/tmp/h.sock",
                                                                "XDG_CONFIG_HOME": "/x"])
        XCTAssertEqual(explicit.path, "/tmp/h.sock")
        XCTAssertEqual(explicit.source, .environment)

        let xdg = HerdrClient.socketLocation(environment: ["XDG_CONFIG_HOME": "/x"])
        XCTAssertEqual(xdg.path, "/x/herdr/herdr.sock")
        XCTAssertEqual(xdg.source, .xdgConfigHome)

        let fallback = HerdrClient.socketLocation(environment: ["HERDR_SOCKET_PATH": ""])
        XCTAssertTrue(fallback.path.hasSuffix("/.config/herdr/herdr.sock"))
        XCTAssertEqual(fallback.source, .defaultPath)
    }

    func testReachabilityDistinguishesDownFromBroken() {
        XCTAssertEqual(HerdrStatus.reachability(for: HerdrError.cannotConnect("/s", "No such file")),
                       .unreachable("Cannot reach the Herdr server at /s: No such file"))
        XCTAssertEqual(HerdrStatus.reachability(for: HerdrError.timeout("agent.list")),
                       .error("Timed out waiting for agent.list."))
        XCTAssertFalse(HerdrStatus().isConnected)
        XCTAssertTrue(HerdrStatus(reachability: .connected).isConnected)
        XCTAssertNil(HerdrStatus(reachability: .connected).errorMessage)
    }

    // MARK: - Mapping

    func testMappingsCoverEveryInputWithTheirAgents() {
        let bindings = KeyBindings(actions: [6: .focusSlot(3), 13: .focusSlot(6)])
        let mappings = HerdrInputMapping.mappings(bindings: bindings, agents: agents(4))
        XCTAssertEqual(mappings.count, 20)
        let byID = Dictionary(uniqueKeysWithValues: mappings.map { ($0.id, $0) })
        XCTAssertEqual(byID[1]?.slot, 0, "key 1 is slot 0 in reading order")
        XCTAssertEqual(byID[1]?.agent?.paneID, "w1:p0")
        XCTAssertEqual(byID[0]?.agent?.paneID, "w1:p1")
        XCTAssertEqual(byID[6]?.slot, 2)
        XCTAssertEqual(byID[6]?.agent?.paneID, "w1:p2")
        XCTAssertEqual(byID[13]?.slot, 5)
        XCTAssertNil(byID[13]?.agent, "slot 6 is empty with four agents")
        XCTAssertNil(byID[7]?.slot, "a non-slot key on focus agent follows Herdr's focus")
    }

    func testAgentsBeyondTheSixSlotsAreUnassigned() {
        XCTAssertEqual(HerdrInputMapping.unassignedAgentIndices(bindings: KeyBindings(), agents: agents(8)), [6, 7])
    }

    func testRemappedSlotKeyLeavesItsAgentUnassignedUnlessAnotherInputReachesIt() {
        let remapped = KeyBindings(actions: [2: .zoomPane])
        XCTAssertEqual(HerdrInputMapping.unassignedAgentIndices(bindings: remapped, agents: agents(3)), [2])
        let reached = KeyBindings(actions: [2: .zoomPane, Pad.dialPushID: .focusSlot(3)])
        XCTAssertEqual(HerdrInputMapping.unassignedAgentIndices(bindings: reached, agents: agents(3)), [])
    }

    // MARK: - Navigation helpers

    func testAdjacentTabsWrapBothWays() {
        let tabs = [
            HerdrTab(tabID: "a", workspaceID: "w", number: 1),
            HerdrTab(tabID: "b", workspaceID: "w", number: 2, focused: true),
            HerdrTab(tabID: "c", workspaceID: "w", number: 3),
            HerdrTab(tabID: "x", workspaceID: "other", number: 1),
        ]
        XCTAssertEqual(HerdrClient.adjacentTab(in: tabs, offset: 1)?.tabID, "c")
        XCTAssertEqual(HerdrClient.adjacentTab(in: tabs, offset: -1)?.tabID, "a")
        XCTAssertEqual(HerdrClient.adjacentTab(in: tabs, offset: 2)?.tabID, "a", "wraps forward")
        XCTAssertEqual(HerdrClient.adjacentTab(in: tabs, offset: -2)?.tabID, "c", "wraps back")
    }

    func testAdjacentWorkspacesWrap() {
        let workspaces = [
            HerdrWorkspace(workspaceID: "w2", number: 2),
            HerdrWorkspace(workspaceID: "w1", number: 1, focused: true),
            HerdrWorkspace(workspaceID: "w3", number: 3),
        ]
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: workspaces, offset: 1)?.workspaceID, "w2")
        XCTAssertEqual(HerdrClient.adjacentWorkspace(in: workspaces, offset: -1)?.workspaceID, "w3")
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: [workspaces[1]], offset: 1))
        XCTAssertNil(HerdrClient.adjacentWorkspace(in: [workspaces[0], workspaces[2]], offset: 1),
                     "nothing focused")
    }

    func testKeyListSplitsOnSpaces() {
        XCTAssertEqual(HerdrClient.keyList("ctrl+c  esc enter"), ["ctrl+c", "esc", "enter"])
        XCTAssertEqual(HerdrClient.keyList("up,down"), ["up", "down"])
        XCTAssertEqual(HerdrClient.keyList("  "), [])
    }

    func testLastAttemptRowOnlyAfterAFailure() {
        let when = Date()
        var status = HerdrStatus(reachability: .connected, lastRefreshAt: when, lastAttemptAt: when)
        XCTAssertNil(status.lastFailedAttemptAt)
        status.reachability = .unreachable("no socket")
        XCTAssertEqual(status.lastFailedAttemptAt, when)
        status.reachability = .unknown
        XCTAssertNil(status.lastFailedAttemptAt)
    }

    /// A request's handlers capture the connection; close() must drop them
    /// or every request leaks its connection and queue. No socket is opened.
    func testClosingASocketConnectionReleasesIt() {
        weak var released: SocketConnection?
        do {
            let conn = SocketConnection(path: "/dev/null/no-herdr.sock")
            released = conn
            let finish = { conn.close() }
            conn.onLine = { _ in finish() }
            conn.onClosed = { _ in finish() }
            conn.close()
        }
        XCTAssertNil(released)
    }
}
