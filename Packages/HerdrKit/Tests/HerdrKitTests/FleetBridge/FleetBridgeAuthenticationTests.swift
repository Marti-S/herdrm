import XCTest
@testable import HerdrKit

final class FleetBridgeAuthenticationTests: XCTestCase {
    private let token = Data(repeating: 0xA5, count: 32)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    func testDirectionalProofsVerify() throws {
        let clientID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let serverID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let clientNonce = Data(repeating: 0x11, count: FleetBridgeAuthenticator.nonceBytes)
        let serverNonce = Data(repeating: 0x22, count: FleetBridgeAuthenticator.nonceBytes)

        let serverProof = try FleetBridgeAuthenticator.serverProof(
            token: token,
            clientID: clientID,
            clientName: "Phone",
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let clientProof = try FleetBridgeAuthenticator.clientProof(
            token: token,
            clientID: clientID,
            clientName: "Phone",
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )

        XCTAssertEqual(serverProof.count, FleetBridgeAuthenticator.proofBytes)
        XCTAssertEqual(clientProof.count, FleetBridgeAuthenticator.proofBytes)
        XCTAssertNotEqual(serverProof, clientProof)
        XCTAssertTrue(FleetBridgeAuthenticator.verify(serverProof, equals: serverProof))
        XCTAssertTrue(FleetBridgeAuthenticator.verify(clientProof, equals: clientProof))
        XCTAssertFalse(FleetBridgeAuthenticator.verify(serverProof, equals: clientProof))
    }

    func testProofBindsNoncesNamesAndEndpointIdentities() throws {
        let clientID = UUID()
        let serverID = UUID()
        let clientNonce = Data(repeating: 0x31, count: FleetBridgeAuthenticator.nonceBytes)
        let serverNonce = Data(repeating: 0x42, count: FleetBridgeAuthenticator.nonceBytes)
        let baseline = try FleetBridgeAuthenticator.serverProof(
            token: token,
            clientID: clientID,
            clientName: "Phone",
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )

        XCTAssertNotEqual(
            baseline,
            try FleetBridgeAuthenticator.serverProof(
                token: token,
                clientID: UUID(),
                clientName: "Phone",
                serverID: serverID,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )
        XCTAssertNotEqual(
            baseline,
            try FleetBridgeAuthenticator.serverProof(
                token: token,
                clientID: clientID,
                clientName: "Other Phone",
                serverID: serverID,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )
        XCTAssertNotEqual(
            baseline,
            try FleetBridgeAuthenticator.serverProof(
                token: token,
                clientID: clientID,
                clientName: "Phone",
                serverID: UUID(),
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
        )
        var changedNonce = clientNonce
        changedNonce[0] ^= 0xFF
        XCTAssertNotEqual(
            baseline,
            try FleetBridgeAuthenticator.serverProof(
                token: token,
                clientID: clientID,
                clientName: "Phone",
                serverID: serverID,
                clientNonce: changedNonce,
                serverNonce: serverNonce
            )
        )
    }

    func testInvalidTokenAndNonceAreRejected() {
        XCTAssertThrowsError(
            try FleetBridgeAuthenticator.serverProof(
                token: "not-a-token",
                clientID: UUID(),
                clientName: "Phone",
                serverID: UUID(),
                clientNonce: Data(repeating: 0, count: FleetBridgeAuthenticator.nonceBytes),
                serverNonce: Data(repeating: 0, count: FleetBridgeAuthenticator.nonceBytes)
            )
        ) { error in
            XCTAssertEqual(error as? FleetBridgeAuthenticationError, .invalidToken)
        }

        XCTAssertThrowsError(try FleetBridgeAuthenticator.validateNonce(Data([1, 2, 3]))) { error in
            XCTAssertEqual(
                error as? FleetBridgeAuthenticationError,
                .invalidNonceLength(3)
            )
        }
    }

    func testRandomNoncesHaveExpectedLengthAndDiffer() throws {
        let first = try FleetBridgeAuthenticator.randomNonce()
        let second = try FleetBridgeAuthenticator.randomNonce()
        XCTAssertEqual(first.count, FleetBridgeAuthenticator.nonceBytes)
        XCTAssertEqual(second.count, FleetBridgeAuthenticator.nonceBytes)
        XCTAssertNotEqual(first, second)
    }
}
