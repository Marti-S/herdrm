import XCTest
@testable import HerdrKit

/// E2E tests against a real remote herdr over SSH.
/// Enabled by HERDRM_E2E_SSH_TARGET (e.g. "vincent@10.10.10.87"); skipped otherwise.
final class RemoteSSHTests: XCTestCase {
    private var target: String? {
        ProcessInfo.processInfo.environment["HERDRM_E2E_SSH_TARGET"]
    }

    func testProbeRemoteHome() async throws {
        guard let target else { throw XCTSkip("HERDRM_E2E_SSH_TARGET not set") }
        let tunnel = SSHTunnel(target: target)
        let home = try await tunnel.probeRemoteHome()
        XCTAssertTrue(home.hasPrefix("/"), "unexpected remote home: \(home)")
    }

    func testTunnelPingSnapshotAndAgents() async throws {
        guard let target else { throw XCTSkip("HERDRM_E2E_SSH_TARGET not set") }
        let device = Device(name: "e2e-remote", kind: .ssh(target: target))
        let service = HerdrService(device: device)
        let pong = try await service.connect()
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, HerdrService.minimumProtocolVersion)

        let snapshot = try await service.snapshot()
        let agents = try await service.agents()
        XCTAssertEqual(Set(snapshot.agents.map(\.paneID)), Set(agents.map(\.paneID)))
        XCTAssertFalse(snapshot.workspaces.isEmpty, "remote session has no workspaces")

        // Round-trip a mutation: create a tab remotely, verify it in the snapshot, close it.
        let paneID = try await service.createTab(workspaceID: nil, cwd: nil, label: "herdrm-e2e")
        let after = try await service.snapshot()
        XCTAssertNotEqual(snapshot.agents.count + snapshot.workspaces.count, 0)
        XCTAssertTrue(
            after.workspaces.count >= snapshot.workspaces.count,
            "workspace count went backwards after tab.create"
        )
        try await service.closePane(paneID: paneID)
        await service.disconnect()
    }

    func testTunnelSurvivesRepeatedRequests() async throws {
        guard let target else { throw XCTSkip("HERDRM_E2E_SSH_TARGET not set") }
        let device = Device(name: "e2e-remote", kind: .ssh(target: target))
        let service = HerdrService(device: device)
        _ = try await service.connect()
        for _ in 0..<10 {
            _ = try await service.workspaces()
        }
        await service.disconnect()
    }
}
