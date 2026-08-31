import Foundation
import HerdrKit

/// Pre-authentication endpoint for one-use QR invitations. It intentionally
/// accepts exactly one small request and closes immediately after replying; the
/// phone reconnects with its issued credential for the long-lived fleet stream.
final class FleetBridgePairingServer: @unchecked Sendable {
    private let authority: FleetBridgePairingAuthority
    private let listener: FleetTCPListener

    init(
        authority: FleetBridgePairingAuthority,
        port: UInt16,
        bindHost: String? = "127.0.0.1"
    ) throws {
        self.authority = authority
        self.listener = try FleetTCPListener(port: port, bindHost: bindHost)
    }

    @discardableResult
    func start() async throws -> UInt16 {
        try await listener.start { [authority] connection in
            await Self.handle(connection: connection, authority: authority)
        }
    }

    func stop() {
        listener.close()
    }

    var boundPort: UInt16? { listener.boundPort }

    private static func handle(
        connection: FleetTCPConnection,
        authority: FleetBridgePairingAuthority
    ) async {
        defer { connection.close() }
        do {
            try await connection.start()
            var decoder = FleetPairingWireDecoder<FleetPairingClientMessage>()
            while let data = try await connection.receive() {
                let messages = try decoder.append(data)
                guard messages.count <= 1 else {
                    throw PairingServerError.tooManyRequests
                }
                guard let message = messages.first else { continue }
                let response: FleetPairingServerMessage
                switch message {
                case .redeem(let request):
                    do {
                        response = .credential(try await authority.redeem(request))
                    } catch {
                        response = .error(remoteError(for: error))
                    }
                }
                try await connection.send(FleetPairingWire.encode(response))
                return
            }
            try decoder.finish()
        } catch {
            let response = FleetPairingServerMessage.error(remoteError(for: error))
            if let data = try? FleetPairingWire.encode(response) {
                try? await connection.send(data)
            }
        }
    }

    private static func remoteError(for error: Error) -> FleetPairingRemoteError {
        if let error = error as? FleetPairingAuthorityError {
            let code: String
            switch error {
            case .invalidEndpoint: code = "invalid_endpoint"
            case .invalidLifetime: code = "invalid_lifetime"
            case .invitationMissing: code = "invitation_missing"
            case .invitationExpired: code = "invitation_expired"
            case .bridgeMismatch: code = "bridge_mismatch"
            case .invalidClient: code = "invalid_client"
            case .secretMismatch: code = "secret_mismatch"
            case .tokenGenerationFailed: code = "credential_failed"
            }
            return FleetPairingRemoteError(
                code: code,
                message: error.localizedDescription
            )
        }
        if let error = error as? FleetPairingWireError {
            return FleetPairingRemoteError(
                code: "invalid_pairing_frame",
                message: error.localizedDescription
            )
        }
        if let error = error as? PairingServerError {
            return FleetPairingRemoteError(
                code: "too_many_requests",
                message: error.localizedDescription
            )
        }
        return FleetPairingRemoteError(
            code: "pairing_failed",
            message: error.localizedDescription
        )
    }
}

private enum PairingServerError: Error, LocalizedError {
    case tooManyRequests

    var errorDescription: String? {
        "A pairing connection accepts exactly one request."
    }
}