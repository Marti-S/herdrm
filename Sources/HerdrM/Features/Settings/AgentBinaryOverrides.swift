import Foundation

/// Per-kind CLI path overrides persisted in user defaults. Empty means automatic
/// lookup on the login-shell search PATH. Invalid paths hide that kind until
/// the user fixes or clears the field. They never silently fall back.
enum AgentBinaryOverrides {
    static let defaultsKey = "agent.binaryOverrides"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[entry.key] = value }
            }
    }

    static func save(_ overrides: [String: String], defaults: UserDefaults = .standard) {
        let trimmed = overrides.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(trimmed, forKey: Self.defaultsKey)
        }
    }
}
