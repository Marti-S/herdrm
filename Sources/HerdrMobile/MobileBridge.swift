import Foundation
import HerdrKit
import Security
import UIKit

/// One paired HerdrM host. The bridge owns its Mac-side local and SSH-backed
/// devices, so those SSH targets and credentials never need to be copied here.
struct MobileBridge: Codable, Identifiable, Hashable, Sendable {
  let id: UUID
  var expectedServerID: UUID?
  var name: String
  var host: String
  var port: UInt16

  init(
    id: UUID = UUID(),
    expectedServerID: UUID? = nil,
    name: String,
    host: String,
    port: UInt16 = FleetBridgeProtocol.defaultPort
  ) {
    self.id = id
    self.expectedServerID = expectedServerID
    self.name = name
    self.host = host
    self.port = port
  }

  var subtitle: String {
    port == FleetBridgeProtocol.defaultPort ? host : "\(host):\(port)"
  }
}

/// JSON written by the Mac to
/// `~/Library/Application Support/HerdrM/mobile-pairing.json`.
struct MobileBridgePairingInfo: Codable, Equatable {
  let protocolVersion: Int
  let serverID: UUID
  let serverName: String
  let hostHint: String
  let port: UInt16
  let token: String
  let loopbackOnly: Bool
  let networkScope: FleetBridgeNetworkScope?

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case serverID = "server_id"
    case serverName = "server_name"
    case hostHint = "host_hint"
    case port
    case token
    case loopbackOnly = "loopback_only"
    case networkScope = "network_scope"
  }

  var resolvedNetworkScope: FleetBridgeNetworkScope {
    networkScope ?? (loopbackOnly ? .loopback : .allInterfaces)
  }

  static func decode(_ text: String) throws -> MobileBridgePairingInfo {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8), !data.isEmpty else {
      throw MobileBridgePairingError.empty
    }
    let info: MobileBridgePairingInfo
    do {
      info = try JSONDecoder().decode(MobileBridgePairingInfo.self, from: data)
    } catch {
      throw MobileBridgePairingError.invalid(error.localizedDescription)
    }
    guard info.protocolVersion == FleetBridgeProtocol.version else {
      throw MobileBridgePairingError.protocolMismatch(info.protocolVersion)
    }
    guard !info.token.isEmpty, info.port > 0 else {
      throw MobileBridgePairingError.invalid("The token or port is missing.")
    }
    return info
  }
}

enum MobileBridgePairingError: LocalizedError {
  case empty
  case invalid(String)
  case protocolMismatch(Int)

  var errorDescription: String? {
    switch self {
    case .empty:
      return String(localized: "The pairing JSON is empty.")
    case .invalid(let detail):
      return String(localized: "The pairing JSON is invalid: \(detail)")
    case .protocolMismatch(let version):
      return String(
        localized:
          "This Mac uses bridge protocol \(version), but this app supports \(FleetBridgeProtocol.version)."
      )
    }
  }
}

@MainActor
final class MobileBridgeStore {
  private static let key = "fleetBridge.v1"

  private struct Envelope: Codable {
    let version: Int
    let bridge: MobileBridge?
  }

  func load() -> MobileBridge? {
    guard let data = UserDefaults.standard.data(forKey: Self.key),
      let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
      envelope.version == 1
    else { return nil }
    return envelope.bridge
  }

  func save(_ bridge: MobileBridge?) {
    let envelope = Envelope(version: 1, bridge: bridge)
    if let data = try? JSONEncoder().encode(envelope) {
      UserDefaults.standard.set(data, forKey: Self.key)
    }
  }
}

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

/// Maintains the one long-lived fleet subscription. Per-device RPC and terminal
/// transports are stateless and open their own authenticated bridge connection.
@MainActor
final class MobileBridgeSession {
  let bridge: MobileBridge
  var state: MobileConnectionState = .idle
  var snapshot: FleetSnapshot?
  var onChange: (() -> Void)?

  private let clientID: UUID
  private let clientName: String
  private var runTask: Task<Void, Never>?
  private var generation: UInt64 = 0

  init(
    bridge: MobileBridge,
    clientID: UUID = MobileClientIdentity.id,
    clientName: String? = nil
  ) {
    self.bridge = bridge
    self.clientID = clientID
    self.clientName = clientName ?? MobileClientIdentity.name
  }

  func reconnect() async {
    await disconnect()
    connect()
  }

  func connect() {
    guard runTask == nil else { return }
    generation &+= 1
    let currentGeneration = generation
    state = .connecting
    onChange?()
    runTask = Task { [weak self] in
      await self?.runSubscriptionLoop(generation: currentGeneration)
    }
  }

  func disconnect() async {
    generation &+= 1
    let task = runTask
    runTask = nil
    task?.cancel()
    await task?.value
    state = .idle
    onChange?()
  }

  func refresh() async {
    do {
      let next = try await makeClient().snapshot()
      let previousState = state
      let snapshotChanged = snapshot != next
      if snapshotChanged {
        snapshot = next
      }
      state = .connected(version: "Bridge \(FleetBridgeProtocol.version)")
      if snapshotChanged || state != previousState {
        onChange?()
      }
    } catch {
      let nextState = MobileConnectionState.failed(Self.presentation(error))
      guard state != nextState else { return }
      state = nextState
      onChange?()
    }
  }

  func transport(for deviceID: UUID) -> (any MobileTransport)? {
    guard snapshot?.device(deviceID) != nil,
      let client = try? makeClient()
    else { return nil }
    return FleetBridgeDeviceTransport(client: client, deviceID: deviceID)
  }

  private func runSubscriptionLoop(generation expectedGeneration: UInt64) async {
    var backoff: Double = 1
    defer {
      if generation == expectedGeneration {
        runTask = nil
      }
    }

    while !Task.isCancelled, generation == expectedGeneration {
      if state != .connecting {
        state = .connecting
        onChange?()
      }
      do {
        var receivedSnapshotOnConnection = false
        let stream = try makeClient().snapshots(after: snapshot?.revision)
        for try await next in stream {
          guard
            !Task.isCancelled,
            generation == expectedGeneration
          else { return }

          let previousState = state
          let snapshotChanged: Bool
          if receivedSnapshotOnConnection {
            snapshotChanged = next.revision > (snapshot?.revision ?? 0)
          } else {
            // A restarted bridge begins a new revision sequence. Accept its
            // first snapshot even when the number moves backwards, while still
            // suppressing an identical reconnect snapshot.
            snapshotChanged = snapshot != next
            receivedSnapshotOnConnection = true
          }
          if snapshotChanged {
            snapshot = next
          }
          backoff = 1
          state = .connected(version: "Bridge \(FleetBridgeProtocol.version)")
          if snapshotChanged || state != previousState {
            onChange?()
          }
        }
        guard
          !Task.isCancelled,
          generation == expectedGeneration
        else { return }
        throw FleetBridgeClientError.connectionClosed
      } catch {
        guard
          !Task.isCancelled,
          generation == expectedGeneration
        else { return }
        state = .failed(Self.presentation(error))
        onChange?()
        if (error as? FleetBridgeClientError)?.isPermanent == true {
          return
        }
      }

      try? await Task.sleep(for: .seconds(backoff))
      backoff = min(backoff * 2, 30)
    }
  }

  private func makeClient() throws -> FleetBridgeClient {
    guard let token = try MobileBridgeSecretStore.token(for: bridge.id),
      !token.isEmpty
    else { throw FleetBridgeClientError.missingToken }
    return FleetBridgeClient(
      bridge: bridge,
      token: token,
      clientID: clientID,
      clientName: clientName
    )
  }

  private static func presentation(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}
