import Foundation
import XCTest
@testable import HerdrKit

final class TerminalSnapshotTests: XCTestCase {
    func testSnapshotDecodesPaneTerminalIDsAndTabLabels() throws {
        let data = Data(#"""
        {
          "agents": [],
          "workspaces": [],
          "panes": [{
            "pane_id": "w7:p1",
            "terminal_id": "term_abc123",
            "workspace_id": "w7",
            "tab_id": "w7:t1",
            "agent_status": "unknown",
            "cwd": "/tmp/project",
            "revision": 3
          }],
          "tabs": [{
            "tab_id": "w7:t1",
            "workspace_id": "w7",
            "number": 1,
            "label": "server",
            "focused": true,
            "pane_count": 1
          }],
          "focused_pane_id": "w7:p1",
          "focused_workspace_id": "w7",
          "version": "0.8.2",
          "protocol": 20
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.panes?.first?.terminalID, "term_abc123")
        XCTAssertEqual(snapshot.tabs?.first?.label, "server")
        XCTAssertEqual(snapshot.tabs?.first?.workspaceID, "w7")
    }

    func testOlderSnapshotWithoutPanesOrTabsStillDecodes() throws {
        let data = Data(#"{"agents":[],"workspaces":[],"protocol":17,"version":"0.7.4"}"#.utf8)
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.panes)
        XCTAssertNil(snapshot.tabs)
    }

    func testOrdinaryTerminalPanesExcludeAgentPanes() throws {
        let data = Data(#"""
        {
          "agents": [{
            "agent": "codex",
            "agent_status": "working",
            "workspace_id": "w1",
            "tab_id": "w1:t1",
            "pane_id": "w1:p1"
          }],
          "workspaces": [],
          "panes": [
            {"pane_id":"w1:p1","terminal_id":"term_agent","workspace_id":"w1"},
            {"pane_id":"w1:p2","terminal_id":"term_shell","workspace_id":"w1"}
          ]
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.ordinaryTerminalPanes.map(\.paneID), ["w1:p2"])
    }
}
