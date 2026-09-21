import Foundation
import HerdrKit
import Security
import UIKit

enum MobileBridgeSecretStore {
  private static let service = "dev.bybee.herdrm.ios.fleet-bridge"

  static func token(for bridgeID: UUID) throws -> String? {
    var query = baseQuery(bridgeID: bridgeID)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8)
    else {
      throw MobileBridgeSecretError(status: status == errSecSuccess ? errSecDecode : status)
    }
    return value
  }

  static func setToken(_ token: String, for bridgeID: UUID) throws {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      try removeToken(for: bridgeID)
      return
    }
    let data = Data(trimmed.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let query = baseQuery(bridgeID: bridgeID)
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else {
      throw MobileBridgeSecretError(status: update)
    }
    var item = query
    item.merge(attributes) { _, new in new }
    let add = SecItemAdd(item as CFDictionary, nil)
    guard add == errSecSuccess else { throw MobileBridgeSecretError(status: add) }
  }

  static func removeToken(for bridgeID: UUID) throws {
    let status = SecItemDelete(baseQuery(bridgeID: bridgeID) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MobileBridgeSecretError(status: status)
    }
  }

  private static func baseQuery(bridgeID: UUID) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: bridgeID.uuidString,
    ]
  }
}

struct MobileBridgeSecretError: LocalizedError {
  let status: OSStatus

  var errorDescription: String? {
    let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    return String(localized: "Could not access the bridge token: \(detail)")
  }
}

enum MobileClientIdentity {
  private static let idKey = "fleetBridge.clientID"

  static var id: UUID {
    if let raw = UserDefaults.standard.string(forKey: idKey),
      let value = UUID(uuidString: raw)
    {
      return value
    }
    let value = UUID()
    UserDefaults.standard.set(value.uuidString, forKey: idKey)
    return value
  }

  @MainActor
  static var name: String {
    let value = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? String(localized: "iPhone") : value
  }
}
