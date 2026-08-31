import Foundation
import HerdrKit
import UniformTypeIdentifiers

/// File staging is intentionally a refinement of the terminal/RPC transport.
/// Direct SSH does not conform yet; paired Mac bridges keep staging and remote
/// device credentials host-owned.
protocol MobileAttachmentTransport: MobileTransport {
    func stageAttachment(fileName: String, data: Data) async throws -> String
}

extension FleetBridgeDeviceTransport: MobileAttachmentTransport {
    func stageAttachment(fileName: String, data: Data) async throws -> String {
        try AttachmentUploadPolicy.validateFileSize(data.count)
        let safeName = AttachmentUploadPolicy.sanitizedFileName(fileName)
        let result = try await client.request(
            deviceID: deviceID,
            method: "attachment.stage",
            params: .object([
                "name": .string(safeName),
                "bytes": .string(data.base64EncodedString()),
            ])
        )
        guard let path = result["path"]?.stringValue, !path.isEmpty else {
            throw AttachmentUploadError.stagingFailed(
                "the Mac returned no device-local path"
            )
        }
        return path
    }
}

struct MobilePickedAttachment: Sendable {
    let fileName: String
    let data: Data
    let isImage: Bool

    static func load(urls: [URL]) async throws -> [MobilePickedAttachment] {
        try await Task.detached(priority: .userInitiated) {
            guard !urls.isEmpty else { throw AttachmentUploadError.noFiles }
            guard urls.count <= AttachmentUploadPolicy.maximumFiles else {
                throw AttachmentUploadError.tooManyFiles(
                    limit: AttachmentUploadPolicy.maximumFiles
                )
            }

            var attachments: [MobilePickedAttachment] = []
            var totalBytes = 0
            attachments.reserveCapacity(urls.count)

            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }

                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                    .contentTypeKey,
                    .nameKey,
                ])
                guard values.isRegularFile != false else {
                    throw AttachmentUploadError.invalidFile
                }
                if let expectedSize = values.fileSize {
                    try AttachmentUploadPolicy.validateFileSize(expectedSize)
                    guard totalBytes + expectedSize
                        <= AttachmentUploadPolicy.maximumSelectionBytes
                    else {
                        throw AttachmentUploadError.selectionTooLarge(
                            limit: AttachmentUploadPolicy.maximumSelectionBytes
                        )
                    }
                }

                // The scope ends after this iteration, so copy the bounded file
                // eagerly rather than retaining a memory mapping to provider data.
                let data = try Data(contentsOf: url)
                try AttachmentUploadPolicy.validateFileSize(data.count)
                totalBytes += data.count
                guard totalBytes <= AttachmentUploadPolicy.maximumSelectionBytes else {
                    throw AttachmentUploadError.selectionTooLarge(
                        limit: AttachmentUploadPolicy.maximumSelectionBytes
                    )
                }

                let contentType = values.contentType
                    ?? UTType(filenameExtension: url.pathExtension)
                attachments.append(MobilePickedAttachment(
                    fileName: AttachmentUploadPolicy.sanitizedFileName(
                        values.name ?? url.lastPathComponent
                    ),
                    data: data,
                    isImage: contentType?.conforms(to: .image) == true
                ))
            }

            try AttachmentUploadPolicy.validateSelection(
                fileCount: attachments.count,
                totalBytes: totalBytes
            )
            return attachments
        }.value
    }
}
