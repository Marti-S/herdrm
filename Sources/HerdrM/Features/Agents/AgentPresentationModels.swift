import Foundation

/// Atomic keeps the Pi-compatible one-cell indicator while workflows and
/// subagents replace the accompanying "Working..." text. Herdr's Pi manifest
/// matches that literal text, so the sidebar also checks the live glyph.
enum AtomicActivityDetector {
    static func isWorking(in text: String) -> Bool {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(8)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "∀" || trimmed.hasPrefix("∀ ")
            }
    }
}
