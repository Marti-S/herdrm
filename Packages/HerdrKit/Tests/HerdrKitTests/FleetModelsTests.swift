import XCTest
@testable import HerdrKit

final class FleetModelsTests: XCTestCase {
    func testGlobalReferencesRemainDistinctAcrossDevices() {
        let first = UUID()
        let second = UUID()

        XCTAssertNotEqual(
            FleetPaneRef(deviceID: first, paneID: "w1:p1"),
            FleetPaneRef(deviceID: second, paneID: "w1:p1")
        )
        XCTAssertNotEqual(
            FleetSpaceRef(deviceID: first, workspaceID: "w1"),
            FleetSpaceRef(deviceID: second, workspaceID: "w1")
        )
    }

    func testFleetDeviceInfoDoesNotEncodeSSHTargetOrSocketPath() throws {
        let device = Device(
            name: "Build Mac",
            kind: .ssh(target: "secret-user@private.tailnet"),
            socketPath: "/private/herdr.sock",
            osID: "macos"
        )
        let data = try JSONEncoder().encode(FleetDeviceInfo(device: device))
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("secret-user"))
        XCTAssertFalse(text.contains("private.tailnet"))
        XCTAssertFalse(text.contains("herdr.sock"))
        XCTAssertTrue(text.contains("Build Mac"))
        XCTAssertTrue(text.contains("remote"))
    }

    func testConnectionStateNormalizesPhaseSpecificFields() throws {
        XCTAssertEqual(
            FleetConnectionState(
                phase: .connecting,
                version: "ignored",
                message: "ignored"
            ),
            .connecting
        )
        XCTAssertEqual(
            FleetConnectionState(
                phase: .connected,
                version: "0.8.2",
                message: "ignored"
            ),
            .connected(version: "0.8.2")
        )
        XCTAssertEqual(
            FleetConnectionState(
                phase: .failed,
                version: "ignored",
                message: "offline"
            ),
            .failed("offline")
        )

        let inconsistent = Data(
            #"{"phase":"idle","version":"ignored","message":"ignored"}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(FleetConnectionState.self, from: inconsistent),
            .idle
        )
    }

    func testSnapshotResolvesResourcesByGlobalReference() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstAgent = try agent(paneID: "w1:p1", workspaceID: "w1")
        let secondAgent = try agent(paneID: "w1:p1", workspaceID: "w1")
        let workspace = try workspace(id: "w1")
        let terminal = try pane(id: "w1:p2", workspaceID: "w1")
        let tab = try tab(id: "t1", workspaceID: "w1")

        let snapshot = FleetSnapshot(
            revision: 9,
            devices: [
                FleetDeviceSnapshot(
                    device: FleetDeviceInfo(
                        id: firstID,
                        name: "First",
                        kind: .local
                    ),
                    connection: .connected(version: "0.8.2"),
                    agents: [firstAgent],
                    workspaces: [workspace],
                    tabs: [tab],
                    terminals: [terminal],
                    availableAgentKinds: ["codex"]
                ),
                FleetDeviceSnapshot(
                    device: FleetDeviceInfo(
                        id: secondID,
                        name: "Second",
                        kind: .remote
                    ),
                    connection: .connecting,
                    agents: [secondAgent]
                ),
            ]
        )

        XCTAssertEqual(
            snapshot.agent(FleetPaneRef(deviceID: firstID, paneID: "w1:p1")),
            firstAgent
        )
        XCTAssertEqual(
            snapshot.agent(FleetPaneRef(deviceID: secondID, paneID: "w1:p1")),
            secondAgent
        )
        XCTAssertNil(
            snapshot.agent(FleetPaneRef(deviceID: UUID(), paneID: "w1:p1"))
        )
        XCTAssertEqual(
            snapshot.workspace(FleetSpaceRef(deviceID: firstID, workspaceID: "w1")),
            workspace
        )
        XCTAssertEqual(
            snapshot.terminal(FleetPaneRef(deviceID: firstID, paneID: "w1:p2")),
            terminal
        )
        XCTAssertEqual(
            snapshot.tab(FleetTabRef(deviceID: firstID, tabID: "t1")),
            tab
        )
        XCTAssertEqual(snapshot.agentCount, 2)
        XCTAssertEqual(snapshot.terminalCount, 1)
    }

    private func agent(paneID: String, workspaceID: String) throws -> AgentInfo {
        try JSONDecoder().decode(
            AgentInfo.self,
            from: Data(
                """
                {
                  "agent": "codex",
                  "agent_status": "working",
                  "workspace_id": "\(workspaceID)",
                  "tab_id": "t1",
                  "pane_id": "\(paneID)"
                }
                """.utf8
            )
        )
    }

    private func workspace(id: String) throws -> WorkspaceInfo {
        try JSONDecoder().decode(
            WorkspaceInfo.self,
            from: Data(
                """
                {
                  "workspace_id": "\(id)",
                  "number": 1,
                  "label": "Workspace"
                }
                """.utf8
            )
        )
    }

    private func pane(id: String, workspaceID: String) throws -> PaneInfo {
        try JSONDecoder().decode(
            PaneInfo.self,
            from: Data(
                """
                {
                  "pane_id": "\(id)",
                  "terminal_id": "term-1",
                  "workspace_id": "\(workspaceID)"
                }
                """.utf8
            )
        )
    }

    private func tab(id: String, workspaceID: String) throws -> TabInfo {
        try JSONDecoder().decode(
            TabInfo.self,
            from: Data(
                """
                {
                  "tab_id": "\(id)",
                  "workspace_id": "\(workspaceID)",
                  "label": "1"
                }
                """.utf8
            )
        )
    }
}
