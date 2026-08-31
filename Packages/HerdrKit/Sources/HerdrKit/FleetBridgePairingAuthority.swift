#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Foundation

public struct FleetPairingRequest: Codable, Sendable, Equatable {
    public let invitationID: UUID
    public let bridgeID: UUID
    public let clientID: UUID
    public let clientName: String
    public let secret: FleetPairingSecret

    public init(
        invitationID: UUID,
        bridgeID: UUID,
        clientID: UUID,
        clientName: String,
        secret: FleetPairingSecret
    ) {
        self.invitationID = invitationID
        self.bridgeID = bridgeID
        self.clientID = clientID
        self.clientName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
    }
}

public struct FleetCredentialPresentation: Codable, Sendable, Equatable {
    public let bridgeID: UUID
    public let clientID: UUID
    public let token: String

    public init(bridgeID: UUID, clientID: UUID, token: String) {
        self.bridgeID = bridgeID
        self.clientID = clientID
        self.token = token
    }
}

/// The server-side form of a paired client. Only a SHA-256 token digest is
/// persisted, so exporting the Mac's preferences does not reveal usable bearer
/// credentials.
public struct FleetPairedClientRecord: Codable, Sendable, Identifiable, Equatable {
    public let clientID: UUID
    public var clientName: String
    public let tokenDigest: Data
    public var capabilities: Set<FleetCapability>
    public let pairedAt: Date
    public var lastConnectedAt: Date?

    public var id: UUID { clientID }

    public init(
        clientID: UUID,
        clientName: String,
        tokenDigest: Data,
        capabilities: Set<FleetCapability>,
        pairedAt: Date,
        lastConnectedAt: Date? = nil
    ) {
        self.clientID = clientID
        self.clientName = clientName
        self.tokenDigest = tokenDigest
        self.capabilities = capabilities
        self.pairedAt = pairedAt
        self.lastConnectedAt = lastConnectedAt
    }
}

public enum FleetPairingAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case invalidLifetime
    case invitationMissing
    case invitationExpired
    case bridgeMismatch
    case invalidClient
    case secretMismatch
    case tokenGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "the bridge endpoint is invalid"
        case .invalidLifetime: return "pairing invitations must live for 30 seconds to 10 minutes"
        case .invitationMissing: return "the pairing invitation was already used or revoked"
        case .invitationExpired: return "the pairing invitation expired"
        case .bridgeMismatch: return "the pairing invitation belongs to another bridge"
        case .invalidClient: return "the client identity is invalid"
        case .secretMismatch: return "the pairing secret did not match"
        case .tokenGenerationFailed: return "could not issue a client credential"
        }
    }
}

/// Owns short-lived pairing invitations and the revocable client registry for
/// one bridge. Network code should call `redeem` only after it has established
/// the invitation's pinned TLS connection (or an explicitly trusted Tailscale
/// path).
public actor FleetBridgePairingAuthority {
    public typealias Clock = @Sendable () -> Date
    public typealias SecretGenerator = @Sendable () throws -> FleetPairingSecret
    public typealias TokenGenerator = @Sendable () throws -> String
    public typealias RecordsChanged = @Sendable ([FleetPairedClientRecord]) async -> Void

    private struct ActiveInvitation: Sendable {
        let secret: FleetPairingSecret
        let expiresAt: Date
    }

    public let bridgeID: UUID
    private let clock: Clock
    private let secretGenerator: SecretGenerator
    private let tokenGenerator: TokenGenerator
    private let recordsChanged: RecordsChanged?
    private var invitations: [UUID: ActiveInvitation] = [:]
    private var clients: [UUID: FleetPairedClientRecord]

    public init(
        bridgeID: UUID,
        clients: [FleetPairedClientRecord] = [],
        clock: @escaping Clock = Date.init,
        secretGenerator: @escaping SecretGenerator = { try FleetPairingSecret.random() },
        tokenGenerator: @escaping TokenGenerator = { try FleetCredentialToken.random() },
        recordsChanged: RecordsChanged? = nil
    ) {
        self.bridgeID = bridgeID
        self.clock = clock
        self.secretGenerator = secretGenerator
        self.tokenGenerator = tokenGenerator
        self.recordsChanged = recordsChanged
        self.clients = Dictionary(
            clients.map { ($0.clientID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func makeInvitation(
        endpoint: FleetBridgeEndpoint,
        lifetime: TimeInterval = 5 * 60
    ) throws -> FleetPairingInvitation {
        guard endpoint.bridgeID == bridgeID, endpoint.isValid else {
            throw FleetPairingAuthorityError.invalidEndpoint
        }
        guard (30...(10 * 60)).contains(lifetime) else {
            throw FleetPairingAuthorityError.invalidLifetime
        }
        purgeExpiredInvitations()
        let invitationID = UUID()
        let secret: FleetPairingSecret
        do {
            secret = try secretGenerator()
        } catch {
            throw FleetPairingAuthorityError.tokenGenerationFailed
        }
        let expiration = clock().addingTimeInterval(lifetime)
        invitations[invitationID] = ActiveInvitation(secret: secret, expiresAt: expiration)
        return FleetPairingInvitation(
            invitationID: invitationID,
            endpoint: endpoint,
            secret: secret,
            expiresAt: expiration
        )
    }

    /// Consumes the invitation on the first redemption attempt. A failed guess
    /// therefore cannot be retried and a captured QR cannot race a legitimate
    /// phone repeatedly.
    public func redeem(
        _ request: FleetPairingRequest,
        capabilities: Set<FleetCapability> = [.observe, .control]
    ) async throws -> FleetClientCredential {
        purgeExpiredInvitations()
        guard let invitation = invitations.removeValue(forKey: request.invitationID) else {
            throw FleetPairingAuthorityError.invitationMissing
        }
        guard invitation.expiresAt > clock() else {
            throw FleetPairingAuthorityError.invitationExpired
        }
        guard request.bridgeID == bridgeID else {
            throw FleetPairingAuthorityError.bridgeMismatch
        }
        guard !request.clientName.isEmpty, request.clientName.count <= 80 else {
            throw FleetPairingAuthorityError.invalidClient
        }
        guard Self.constantTimeEqual(invitation.secret.bytes, request.secret.bytes) else {
            throw FleetPairingAuthorityError.secretMismatch
        }

        let token: String
        do {
            token = try tokenGenerator()
        } catch {
            throw FleetPairingAuthorityError.tokenGenerationFailed
        }
        guard let tokenBytes = FleetPairingSecret.decodeBase64URL(token),
              tokenBytes.count >= FleetPairingSecret.minimumByteCount
        else {
            throw FleetPairingAuthorityError.tokenGenerationFailed
        }

        let now = clock()
        clients[request.clientID] = FleetPairedClientRecord(
            clientID: request.clientID,
            clientName: request.clientName,
            tokenDigest: Self.digest(tokenBytes),
            capabilities: capabilities,
            pairedAt: now
        )
        await publishRecords()
        return FleetClientCredential(
            bridgeID: bridgeID,
            clientID: request.clientID,
            clientName: request.clientName,
            token: token,
            capabilities: capabilities,
            issuedAt: now
        )
    }

    public func authenticate(
        _ presentation: FleetCredentialPresentation
    ) async -> FleetPairedClientRecord? {
        guard presentation.bridgeID == bridgeID,
              let token = FleetPairingSecret.decodeBase64URL(presentation.token),
              var client = clients[presentation.clientID],
              Self.constantTimeEqual(client.tokenDigest, Self.digest(token))
        else { return nil }

        client.lastConnectedAt = clock()
        clients[presentation.clientID] = client
        await publishRecords()
        return client
    }

    public func revoke(clientID: UUID) async {
        guard clients.removeValue(forKey: clientID) != nil else { return }
        await publishRecords()
    }

    public func revokeInvitation(_ invitationID: UUID) {
        invitations.removeValue(forKey: invitationID)
    }

    public func pairedClients() -> [FleetPairedClientRecord] {
        clients.values.sorted {
            if $0.clientName != $1.clientName {
                return $0.clientName.localizedStandardCompare($1.clientName) == .orderedAscending
            }
            return $0.clientID.uuidString < $1.clientID.uuidString
        }
    }

    private func purgeExpiredInvitations() {
        let now = clock()
        invitations = invitations.filter { $0.value.expiresAt > now }
    }

    private func publishRecords() async {
        await recordsChanged?(pairedClients())
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
#endif