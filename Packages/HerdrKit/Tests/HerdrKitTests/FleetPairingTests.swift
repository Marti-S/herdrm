import Foundation
import XCTest
@testable import HerdrKit

final class FleetPairingTests: XCTestCase {
    private let bytes = Data((0..<32).map(UInt8.init))

    func testPairingSecretRoundTripsBase64URL() throws {
        let secret = try XCTUnwrap(FleetPairingSecret(bytes: bytes))
        XCTAssertFalse(secret.value.contains("+"))
        XCTAssertFalse(secret.value.contains("/"))
        XCTAssertFalse(secret.value.contains("="))
        XCTAssertEqual(secret.bytes, bytes)
        XCTAssertEqual(FleetPairingSecret(value: secret.value), secret)
    }

    func testPairingSecretRejectsShortAndNonURLSafeValues() {
        XCTAssertNil(FleetPairingSecret(bytes: Data(repeating: 1, count: 31)))
        XCTAssertNil(FleetPairingSecret(value: "not+url/safe="))
    }

    func testInvitationURLRoundTrip() throws {
        let endpoint = FleetBridgeEndpoint(
            bridgeID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            name: "Studio Mac",
            host: "studio.example.ts.net",
            port: 45123,
            tlsPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
        let invitation = FleetPairingInvitation(
            invitationID: UUID(uuidString: "00000000-0000-0000-0000-000000000020")!,
            endpoint: endpoint,
            secret: try XCTUnwrap(FleetPairingSecret(bytes: bytes)),
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let url = try XCTUnwrap(invitation.url)
        XCTAssertEqual(url.scheme, "herdrm")
        XCTAssertEqual(FleetPairingInvitation(url: url), invitation)
    }

    func testInvitationValidityChecksExpiryAndEndpoint() throws {
        let secret = try XCTUnwrap(FleetPairingSecret(bytes: bytes))
        let now = Date(timeIntervalSince1970: 100)
        let validEndpoint = FleetBridgeEndpoint(
            bridgeID: UUID(), name: "Mac", host: "100.64.0.2", port: 45123
        )
        XCTAssertTrue(
            FleetPairingInvitation(
                endpoint: validEndpoint,
                secret: secret,
                expiresAt: Date(timeIntervalSince1970: 101)
            ).isValid(at: now)
        )
        XCTAssertFalse(
            FleetPairingInvitation(
                endpoint: validEndpoint,
                secret: secret,
                expiresAt: now
            ).isValid(at: now)
        )
        let invalidEndpoint = FleetBridgeEndpoint(
            bridgeID: UUID(), name: "", host: "", port: 45123
        )
        XCTAssertFalse(
            FleetPairingInvitation(
                endpoint: invalidEndpoint,
                secret: secret,
                expiresAt: Date(timeIntervalSince1970: 101)
            ).isValid(at: now)
        )
    }

    func testCredentialRequiresOpaqueHighEntropyToken() throws {
        let validToken = FleetPairingSecret.encodeBase64URL(bytes)
        XCTAssertTrue(
            FleetClientCredential(
                bridgeID: UUID(),
                clientID: UUID(),
                clientName: "Phone",
                token: validToken,
                capabilities: [.observe],
                issuedAt: Date()
            ).isValid
        )
        XCTAssertFalse(
            FleetClientCredential(
                bridgeID: UUID(),
                clientID: UUID(),
                clientName: "Phone",
                token: "short",
                capabilities: [.observe],
                issuedAt: Date()
            ).isValid
        )
    }
}