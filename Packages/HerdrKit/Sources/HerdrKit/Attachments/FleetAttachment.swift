import Foundation

/// Shared attachment constraints for the mobile bridge and direct-SSH fallback.
/// A 32 MiB payload expands to roughly 43 MiB in base64, remaining below the
/// bridge's existing 64 MiB bounded JSON record.
public enum FleetAttachment {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumFileNameBytes = 180

    /// Returns one path-free, non-control filename suitable for a private cache
    /// on either the Mac bridge or a remote SSH host.
    public static func sanitizedFileName(_ rawValue: String) -> String {
        let pathNeutral = rawValue.replacingOccurrences(of: "\\", with: "/")
        let basename = pathNeutral.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? ""
        let trimmedBasename = basename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBasename.isEmpty,
              trimmedBasename != ".",
              trimmedBasename != ".."
        else { return "attachment" }

        let filteredScalars = trimmedBasename.unicodeScalars.map { scalar -> UnicodeScalar in
            if CharacterSet.controlCharacters.contains(scalar)
                || scalar == "/"
                || scalar == "\\"
                || scalar == ":"
            {
                return "_"
            }
            return scalar
        }
        let value = String(String.UnicodeScalarView(filteredScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != ".." else {
            return "attachment"
        }

        var result = ""
        result.reserveCapacity(min(value.count, maximumFileNameBytes))
        for character in value {
            let candidate = result + String(character)
            if candidate.utf8.count > maximumFileNameBytes { break }
            result = candidate
        }
        return result.isEmpty ? "attachment" : result
    }
}
