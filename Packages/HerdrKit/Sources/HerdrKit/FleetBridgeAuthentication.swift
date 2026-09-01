import CryptoKit
import Foundation
import Security

public enum FleetBridgeAuthenticationError: Error, LocalizedError, Sendable, Equatable {
    case invalidToken
    case invalidNonceLength(Int)
    case randomFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The bridge pairing token is invalid."
        case .invalidNonceLength(let count):
            return "The bridge nonce has invalid length \(count)."
        case .randomFailure(let status):
            return "Could not generate bridge authentication randomness (OSStatus \(status))."
        }
    }
}

/// Challenge-response proof generation for the fleet bridge.
///
/// Pairing transfers one 256-bit secret through the QR/JSON payload. Normal
/// network connections never transmit that secret: both sides prove possession
/// with direction-specific HMAC-SHA256 values over fresh client/server nonces
/// and the stable endpoint identities.
public enum FleetBridgeAuthenticator {
    public static let nonceBytes = 32
    public static let proofBytes = 32

    private static let serverContext = Data("herdrm-fleet-bridge/server-proof/v2".utf8)
    private static let clientContext = Data("herdrm-fleet-bridge/client-proof/v2".utf8)

    public static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw FleetBridgeAuthenticationError.randomFailure(status)
        }
        return Data(bytes)
    }

    public static func serverProof(
        token: String,
        clientID: UUID,
        clientName: String,
        serverID: UUID,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> Data {
        try proof(
            token: token,
            context: serverContext,
            clientID: clientID,
            clientName: clientName,
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
    }

    public static func clientProof(
        token: String,
        clientID: UUID,
        clientName: String,
        serverID: UUID,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> Data {
        try proof(
            token: token,
            context: clientContext,
            clientID: clientID,
            clientName: clientName,
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
    }

    /// Constant-time comparison for authentication proofs.
    public static func verify(_ candidate: Data, equals expected: Data) -> Bool {
        guard candidate.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (candidateByte, expectedByte) in zip(candidate, expected) {
            difference |= candidateByte ^ expectedByte
        }
        return difference == 0
    }

    public static func validateNonce(_ nonce: Data) throws {
        guard nonce.count == nonceBytes else {
            throw FleetBridgeAuthenticationError.invalidNonceLength(nonce.count)
        }
    }

    private static func proof(
        token: String,
        context: Data,
        clientID: UUID,
        clientName: String,
        serverID: UUID,
        clientNonce: Data,
        serverNonce: Data
    ) throws -> Data {
        try validateNonce(clientNonce)
        try validateNonce(serverNonce)
        let key = SymmetricKey(data: try tokenBytes(token))
        let message = transcript(
            context: context,
            clientID: clientID,
            clientName: clientName,
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    }

    private static func transcript(
        context: Data,
        clientID: UUID,
        clientName: String,
        serverID: UUID,
        clientNonce: Data,
        serverNonce: Data
    ) -> Data {
        var data = Data()
        appendField(context, to: &data)
        appendField(Data(String(FleetBridgeProtocol.version).utf8), to: &data)
        appendField(Data(clientID.uuidString.lowercased().utf8), to: &data)
        appendField(Data(clientName.utf8), to: &data)
        appendField(Data(serverID.uuidString.lowercased().utf8), to: &data)
        appendField(clientNonce, to: &data)
        appendField(serverNonce, to: &data)
        return data
    }

    private static func appendField(_ field: Data, to data: inout Data) {
        var length = UInt32(field.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(field)
    }

    private static func tokenBytes(_ token: String) throws -> Data {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var base64 = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else {
            throw FleetBridgeAuthenticationError.invalidToken
        }
        return bytes
    }
}
