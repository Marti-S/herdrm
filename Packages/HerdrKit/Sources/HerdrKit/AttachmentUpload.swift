import Foundation

/// Shared bounds and filename normalization for mobile-to-host attachment
/// uploads. The bridge record limit is much larger, but keeping each file at
/// 16 MiB bounds base64 expansion, memory use, and host-side disk writes.
public enum AttachmentUploadPolicy {
    public static let maximumFileBytes = 16 * 1024 * 1024
    public static let maximumSelectionBytes = 32 * 1024 * 1024
    public static let maximumFiles = 5
    public static let maximumFileNameBytes = 120

    public static func validateFileSize(_ count: Int) throws {
        guard count >= 0, count <= maximumFileBytes else {
            throw AttachmentUploadError.fileTooLarge(limit: maximumFileBytes)
        }
    }

    public static func validateSelection(fileCount: Int, totalBytes: Int) throws {
        guard fileCount > 0 else { throw AttachmentUploadError.noFiles }
        guard fileCount <= maximumFiles else {
            throw AttachmentUploadError.tooManyFiles(limit: maximumFiles)
        }
        guard totalBytes <= maximumSelectionBytes else {
            throw AttachmentUploadError.selectionTooLarge(limit: maximumSelectionBytes)
        }
    }

    /// Returns a single safe path component. Directory prefixes, control
    /// characters, separators, and cross-platform reserved punctuation are
    /// removed before the UTF-8 byte limit is applied.
    public static func sanitizedFileName(_ rawValue: String) -> String {
        let normalized = rawValue.replacingOccurrences(of: "\\", with: "/")
        let component = normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? rawValue
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:"))
        let whitespace = CharacterSet.whitespacesAndNewlines
        let hasMeaningfulScalar = component.unicodeScalars.contains {
            !forbidden.contains($0) && !whitespace.contains($0)
        }

        var value = component.unicodeScalars.map { scalar in
            forbidden.contains(scalar) ? "-" : String(scalar)
        }.joined()
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasMeaningfulScalar || value == "." || value == ".." {
            value = ""
        }
        if value.isEmpty { value = "attachment" }

        while value.utf8.count > maximumFileNameBytes, !value.isEmpty {
            value.removeLast()
        }
        return value.isEmpty ? "attachment" : value
    }
}

public enum AttachmentUploadError: Error, LocalizedError, Sendable, Equatable {
    case noFiles
    case tooManyFiles(limit: Int)
    case fileTooLarge(limit: Int)
    case selectionTooLarge(limit: Int)
    case invalidFile
    case unsupportedAgent
    case unavailable
    case stagingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFiles:
            return "No files were selected."
        case .tooManyFiles(let limit):
            return "Select no more than \(limit) files at once."
        case .fileTooLarge(let limit):
            return "Each attachment must be \(Self.megabytes(limit)) MiB or smaller."
        case .selectionTooLarge(let limit):
            return "The selected attachments must total \(Self.megabytes(limit)) MiB or less."
        case .invalidFile:
            return "The selected item is not a readable regular file."
        case .unsupportedAgent:
            return "This Agent does not advertise file attachment support."
        case .unavailable:
            return "Attachment upload is unavailable for this connection."
        case .stagingFailed(let detail):
            return "Could not stage the attachment: \(detail)"
        }
    }

    private static func megabytes(_ bytes: Int) -> Int {
        bytes / (1024 * 1024)
    }
}
