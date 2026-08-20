import XCTest
@testable import HerdrKit

final class SilentForwardTests: XCTestCase {
    func testOnlyAnEmptyReplyReadsAsASilentForward() {
        XCTAssertTrue(HerdrService.isSilentForward(.malformedResponse("empty reply")))
        // Everything below proves somebody replied (or the local socket itself failed);
        // replacing those errors with a forward diagnosis would hide the real failure.
        XCTAssertFalse(HerdrService.isSilentForward(.malformedResponse("undecodable reply")))
        XCTAssertFalse(HerdrService.isSilentForward(.connectionFailed("connect(): Connection refused")))
        XCTAssertFalse(HerdrService.isSilentForward(.socketUnavailable("/tmp/herdr.sock")))
        XCTAssertFalse(HerdrService.isSilentForward(.rpc(code: "unknown_method", message: "nope")))
        XCTAssertFalse(HerdrService.isSilentForward(.tunnelFailed("ssh exited 255")))
        XCTAssertFalse(HerdrService.isSilentForward(.incompatibleProtocol(3)))
    }

    func testMissingRemoteSocketMeansHerdrIsDownOverThere() throws {
        let error = try XCTUnwrap(SSHTunnel.silentForwardDiagnosis(
            probeOutput: "missing\n",
            target: "vincent@10.10.10.87",
            remoteSocketPath: "/home/vincent/.config/herdr/herdr.sock"
        ))
        guard case .remoteHerdrDown(let target, let socketPath) = error else {
            return XCTFail("expected remoteHerdrDown, got \(error)")
        }
        XCTAssertEqual(target, "vincent@10.10.10.87")
        XCTAssertEqual(socketPath, "/home/vincent/.config/herdr/herdr.sock")
    }

    func testExistingButMuteSocketBlamesTheForwardInstead() throws {
        let error = try XCTUnwrap(SSHTunnel.silentForwardDiagnosis(
            probeOutput: " exists\n",
            target: "vincent@10.10.10.87",
            remoteSocketPath: "/home/vincent/.config/herdr/herdr.sock"
        ))
        guard case .tunnelFailed(let reason) = error else {
            return XCTFail("expected tunnelFailed, got \(error)")
        }
        XCTAssertTrue(reason.contains("AllowStreamLocalForwarding"))
    }

    func testUnrecognizedProbeOutputStaysUndiagnosed() {
        // e.g. a login shell that chokes on the probe; the original error must surface.
        XCTAssertNil(SSHTunnel.silentForwardDiagnosis(
            probeOutput: "zsh: command not found: test",
            target: "vincent@10.10.10.87",
            remoteSocketPath: "/home/vincent/.config/herdr/herdr.sock"
        ))
    }
}
