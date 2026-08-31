#if canImport(Security)
import Foundation
import Security

public struct FleetCredentialKeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "could not access bridge credential in Keychain (OSStatus \(status))"
    }
}

/// Stores one revocable bridge credential per bridge identity.
///
/// The endpoint remains ordinary app metadata; only the opaque bearer token and
/// its associated client identity are kept in the Keychain. This-device-only
/// accessibility prevents iCloud Keychain sync and device migration.
public enum FleetClientCredentialKeychain {
    private static let service = "dev.bybee.herdrm.bridge-client-credential"

    public static func credential(for bridgeID: UUID) throws -> FleetClientCredential? {
        var query = baseQuery(bridgeID: bridgeID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw FleetCredentialKeychainError(status: status == errSecSuccess ? errSecDecode : status)
        }
        do {
            let credential = try JSONDecoder().decode(FleetClientCredential.self, from: data)
            guard credential.bridgeID == bridgeID, credential.isValid else {
                throw FleetCredentialKeychainError(status: errSecDecode)
            }
            return credential
        } catch let error as FleetCredentialKeychainError {
            throw error
        } catch {
            throw FleetCredentialKeychainError(status: errSecDecode)
        }
    }

    public static func setCredential(_ credential: FleetClientCredential) throws {
        guard credential.isValid else {
            throw FleetCredentialKeychainError(status: errSecParam)
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(credential)
        } catch {
            throw FleetCredentialKeychainError(status: errSecEncode)
        }

        let query = baseQuery(bridgeID: credential.bridgeID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw FleetCredentialKeychainError(status: update)
        }

        var item = query
        item.merge(attributes) { _, new in new }
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else {
            throw FleetCredentialKeychainError(status: add)
        }
    }

    public static func removeCredential(for bridgeID: UUID) throws {
        let status = SecItemDelete(baseQuery(bridgeID: bridgeID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FleetCredentialKeychainError(status: status)
        }
    }

    private static func baseQuery(bridgeID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: bridgeID.uuidString.lowercased(),
        ]
    }
}
#endif