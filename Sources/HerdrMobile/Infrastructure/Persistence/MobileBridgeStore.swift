import Foundation
import HerdrKit
import Security
import UIKit

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
