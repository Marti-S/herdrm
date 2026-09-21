import Foundation
import HerdrKit

struct MobileAttachmentPayload: Sendable {
    let fileName: String
    let bytes: Data
}

enum MobileAttachmentError: LocalizedError {
    case notRegularFile
    case tooLarge(limit: Int)
    case unreadable(String)
    case malformedStageResponse

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            return String(localized: "Choose a regular file rather than a folder or package.")
        case .tooLarge(let limit):
            return String(localized: "Attachments may not exceed \(limit / 1_048_576) MiB.")
        case .unreadable(let detail):
            return String(localized: "The selected file could not be read: \(detail)")
        case .malformedStageResponse:
            return String(localized: "The target device returned no attachment path.")
        }
    }
}

enum MobileAttachmentLoader {
    static func load(from url: URL) async throws -> MobileAttachmentPayload {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                let values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey]
                )
                guard values.isRegularFile == true else {
                    throw MobileAttachmentError.notRegularFile
                }
                if let fileSize = values.fileSize,
                   fileSize > FleetAttachment.maximumBytes {
                    throw MobileAttachmentError.tooLarge(
                        limit: FleetAttachment.maximumBytes
                    )
                }

                let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard bytes.count <= FleetAttachment.maximumBytes else {
                    throw MobileAttachmentError.tooLarge(
                        limit: FleetAttachment.maximumBytes
                    )
                }
                return MobileAttachmentPayload(
                    fileName: FleetAttachment.sanitizedFileName(
                        values.name ?? url.lastPathComponent
                    ),
                    bytes: bytes
                )
            }.value
        } catch let error as MobileAttachmentError {
            throw error
        } catch {
            throw MobileAttachmentError.unreadable(error.localizedDescription)
        }
    }
}
