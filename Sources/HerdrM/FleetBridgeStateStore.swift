import Foundation
import HerdrKit

/// Mac-local persistence for the bridge identity and revocable client registry.
/// Raw client bearer tokens never enter this file; `FleetPairedClientRecord`
/// contains only SHA-256 digests.
final class FleetBridgeStateStore: @unchecked Sendable {
    struct State: Codable, Sendable, Equatable {
        var version: Int
        var bridgeID: UUID
        var clients: [FleetPairedClientRecord]
    }

    private static let currentVersion = 1
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.bybee.herdrm.bridge.state")

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
            .appendingPathComponent("Bridge", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.fileURL = base.appendingPathComponent("state.json")
    }

    func loadOrCreate() -> State {
        queue.sync {
            if let data = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(State.self, from: data),
               decoded.version == Self.currentVersion {
                return decoded
            }
            let state = State(
                version: Self.currentVersion,
                bridgeID: UUID(),
                clients: []
            )
            saveUnlocked(state)
            return state
        }
    }

    func saveClients(_ clients: [FleetPairedClientRecord], bridgeID: UUID) {
        queue.sync {
            saveUnlocked(
                State(
                    version: Self.currentVersion,
                    bridgeID: bridgeID,
                    clients: clients
                )
            )
        }
    }

    func reset() -> State {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
            let state = State(
                version: Self.currentVersion,
                bridgeID: UUID(),
                clients: []
            )
            saveUnlocked(state)
            return state
        }
    }

    private func saveUnlocked(_ state: State) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // The network controller surfaces persistence errors when it gains
            // a settings UI. Startup remains usable with an in-memory registry.
        }
    }
}