#if canImport(CryptoKit) && canImport(Security)
import Foundation
import XCTest
@testable import HerdrKit

final class FleetBridgePairingAuthorityTests: XCTestCase {
    private let bridgeID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

    func testInvitationRedeemsOnceAndAuthenticatesCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let invitationSecret = try XCTUnwrap(
            FleetPairingSecret(bytes: Data(repeating: 0x11, count: 32))
        )
        let token = FleetPairingSecret.encodeBase64URL(Data(repeating: 0x22, count: 32))
        let authority = FleetBridgePairingAuthority(
            bridgeID: bridgeID,
            clock: { now },
            secretGenerator: { invitationSecret },
            tokenGenerator: { token }
        )
        let invitation = try await authority.makeInvitation(
            endpoint: endpoint(),
            lifetime: 60
        )
        let request = FleetPairingRequest(
            invitationID: invitation.invitationID,
            bridgeID: bridgeID,
            clientID: clientID,
            clientName: "Jon's iPhone",
            secret: invitation.secret
        )

        let credential = try await authority.redeem(request)
        XCTAssertEqual(credential.bridgeID, bridgeID)
        XCTAssertEqual(credential.clientID, clientID)
        XCTAssertEqual(credential.token, token)
        XCTAssertEqual(credential.capabilities, [.observe, .control])
        XCTAssertTrue(credential.isValid)

        let authenticated = await authority.authenticate(
            FleetCredentialPresentation(
                bridgeID: bridgeID,
                clientID: clientID,
                token: token
            )
        )
        XCTAssertEqual(authenticated?.clientName, "Jon's iPhone")
        XCTAssertEqual(authenticated?.lastConnectedAt, now)

        do {
            _ = try await authority.redeem(request)
            XCTFail("expected the invitation to be single-use")
        } catch {
            XCTAssertEqual(error as? FleetPairingAuthorityError, .invitationMissing)
        }
    }

    func testWrongSecretConsumesInvitation() async throws {
        let correct = try XCTUnwrap(
            FleetPairingSecret(bytes: Data(repeating: 0x11, count: 32))
        )
        let wrong = try XCTUnwrap(
            FleetPairingSecret(bytes: Data(repeating: 0x12, count: 32))
        )
        let authority = FleetBridgePairingAuthority(
            bridgeID: bridgeID,
            clock: { Date(timeIntervalSince1970: 1_000) },
            secretGenerator: { correct },
            tokenGenerator: {
                FleetPairingSecret.encodeBase64URL(Data(repeating: 0x22, count: 32))
            }
        )
        let invitation = try await authority.makeInvitation(
            endpoint: endpoint(),
            lifetime: 60
        )
        let wrongRequest = FleetPairingRequest(
            invitationID: invitation.invitationID,
            bridgeID: bridgeID,
            clientID: clientID,
            clientName: "Phone",
            secret: wrong
        )

        do {
            _ = try await authority.redeem(wrongRequest)
            XCTFail("expected a secret mismatch")
        } catch {
            XCTAssertEqual(error as? FleetPairingAuthorityError, .secretMismatch)
        }

        let correctRequest = FleetPairingRequest(
            invitationID: invitation.invitationID,
            bridgeID: bridgeID,
            clientID: clientID,
            clientName: "Phone",
            secret: correct
        )
        do {
            _ = try await authority.redeem(correctRequest)
            XCTFail("expected the failed attempt to consume the invitation")
        } catch {
            XCTAssertEqual(error as? FleetPairingAuthorityError, .invitationMissing)
        }
    }

    func testRevocationImmediatelyRejectsCredential() async throws {
        let secret = try XCTUnwrap(
            FleetPairingSecret(bytes: Data(repeating: 0x11, count: 32))
        )
        let token = FleetPairingSecret.encodeBase64URL(Data(repeating: 0x22, count: 32))
        let authority = FleetBridgePairingAuthority(
            bridgeID: bridgeID,
            clock: { Date(timeIntervalSince1970: 1_000) },
            secretGenerator: { secret },
            tokenGenerator: { token }
        )
        let invitation = try await authority.makeInvitation(
            endpoint: endpoint(),
            lifetime: 60
        )
        _ = try await authority.redeem(
            FleetPairingRequest(
                invitationID: invitation.invitationID,
                bridgeID: bridgeID,
                clientID: clientID,
                clientName: "Phone",
                secret: secret
            )
        )
        await authority.revoke(clientID: clientID)

        let authenticated = await authority.authenticate(
            FleetCredentialPresentation(
                bridgeID: bridgeID,
                clientID: clientID,
                token: token
            )
        )
        XCTAssertNil(authenticated)
        let clients = await authority.pairedClients()
        XCTAssertTrue(clients.isEmpty)
    }

    func testExpiredInvitationCannotRedeem() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let secret = try XCTUnwrap(
            FleetPairingSecret(bytes: Data(repeating: 0x11, count: 32))
        )
        let authority = FleetBridgePairingAuthority(
            bridgeID: bridgeID,
            clock: { clock.value },
            secretGenerator: { secret },
            tokenGenerator: {
                FleetPairingSecret.encodeBase64URL(Data(repeating: 0x22, count: 32))
            }
        )
        let invitation = try await authority.makeInvitation(
            endpoint: endpoint(),
            lifetime: 30
        )
        clock.value = Date(timeIntervalSince1970: 1_031)

        do {
            _ = try await authority.redeem(
                FleetPairingRequest(
                    invitationID: invitation.invitationID,
                    bridgeID: bridgeID,
                    clientID: clientID,
                    clientName: "Phone",
                    secret: secret
                )
            )
            XCTFail("expected expiration")
        } catch {
            // Expired invitations are purged before lookup and intentionally
            // become indistinguishable from revoked or already-used codes.
            XCTAssertEqual(error as? FleetPairingAuthorityError, .invitationMissing)
        }
    }

    private func endpoint() -> FleetBridgeEndpoint {
        FleetBridgeEndpoint(
            bridgeID: bridgeID,
            name: "Studio Mac",
            host: "studio.example.ts.net",
            port: 45123,
            tlsPublicKeyFingerprint: String(repeating: "a", count: 64)
        )
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) {
        storage = value
    }

    var value: Date {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
#endif