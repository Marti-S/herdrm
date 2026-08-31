#if canImport(Security)
import Foundation
import Security

public enum FleetSecureRandomError: Error, LocalizedError, Sendable {
    case generationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .generationFailed(let status):
            return SecCopyErrorMessageString(status, nil) as String?
                ?? "secure random generation failed with OSStatus \(status)"
        }
    }
}

public extension FleetPairingSecret {
    static func random(byteCount: Int = minimumByteCount) throws -> FleetPairingSecret {
        guard byteCount >= minimumByteCount else {
            throw FleetSecureRandomError.generationFailed(errSecParam)
        }
        var bytes = Data(repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess, let secret = FleetPairingSecret(bytes: bytes) else {
            throw FleetSecureRandomError.generationFailed(status)
        }
        return secret
    }
}

public enum FleetCredentialToken {
    public static func random(byteCount: Int = FleetPairingSecret.minimumByteCount) throws -> String {
        try FleetPairingSecret.random(byteCount: byteCount).value
    }
}
#endif