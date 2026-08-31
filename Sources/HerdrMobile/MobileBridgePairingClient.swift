import Foundation
import HerdrKit

actor MobileBridgePairingClient {
    func redeem(
        invitation: FleetPairingInvitation,
        request: FleetPairingRequest
    ) async throws -> FleetClientCredential {
        guard invitation.isValid() else {
            throw MobileBridgePairingError.invalidInvitation
        }
        guard request.invitationID == invitation.invitationID,
              request.bridgeID == invitation.endpoint.bridgeID,
              request.secret == invitation.secret
        else {
            throw MobileBridgePairingError.invalidInvitation
        }
        guard Self.acceptsTransport(endpoint: invitation.endpoint) else {
            throw MobileBridgePairingError.insecureEndpoint
        }

        let connection = try FleetTCPConnection(endpoint: invitation.endpoint)
        defer { connection.close() }
        try await connection.start()
        try await connection.send(
            FleetPairingWire.encode(FleetPairingClientMessage.redeem(request))
        )

        var decoder = FleetPairingWireDecoder<FleetPairingServerMessage>()
        while let bytes = try await connection.receive() {
            for message in try decoder.append(bytes) {
                switch message {
                case .credential(let credential):
                    guard credential.bridgeID == request.bridgeID,
                          credential.clientID == request.clientID,
                          credential.isValid
                    else {
                        throw MobileBridgePairingError.invalidCredential
                    }
                    return credential
                case .error(let error):
                    throw MobileBridgePairingError.remote(
                        code: error.code,
                        message: error.message
                    )
                }
            }
        }
        try decoder.finish()
        throw MobileBridgePairingError.connectionClosed
    }

    private static func acceptsTransport(endpoint: FleetBridgeEndpoint) -> Bool {
        if endpoint.isTailscaleAddress { return true }
#if DEBUG
        if endpoint.isLoopbackAddress { return true }
#endif
        return false
    }
}

enum MobileBridgePairingError: Error, LocalizedError {
    case invalidInvitation
    case insecureEndpoint
    case invalidCredential
    case connectionClosed
    case remote(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidInvitation:
            return String(localized: "This pairing invitation is invalid or expired.")
        case .insecureEndpoint:
            return String(localized: "Pairing currently requires a Tailscale address.")
        case .invalidCredential:
            return String(localized: "The Mac returned an invalid bridge credential.")
        case .connectionClosed:
            return String(localized: "The Mac closed the pairing connection before replying.")
        case .remote(_, let message):
            return message
        }
    }
}