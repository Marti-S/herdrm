import Foundation
import Security

/// Persists the device list as a versioned JSON envelope in UserDefaults.
@MainActor
final class MobileDeviceStore {
    private static let key = "devices.v1"
    private struct Envelope: Codable {
        var version: Int
        var devices: [MobileDevice]
    }

    func load() -> [MobileDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [] }
        return envelope.devices
    }

    func save(_ devices: [MobileDevice]) {
        let envelope = Envelope(version: 1, devices: devices)
        if let data = try? JSONEncoder().encode(envelope) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
