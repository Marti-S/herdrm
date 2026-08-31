import Foundation
import HerdrKit

/// Materializes authenticated mobile uploads under HerdrM's private
/// Application Support directory, then reuses HerdrService's existing local or
/// SSH staging path. Local-device files remain available to the Agent; remote
/// staging removes the temporary Mac copy after upload succeeds.
enum FleetBridgeAttachmentStore {
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    static func stage(
        data: Data,
        fileName: String,
        device: Device,
        service: HerdrService
    ) async throws -> String {
        try AttachmentUploadPolicy.validateFileSize(data.count)
        let safeName = AttachmentUploadPolicy.sanitizedFileName(fileName)
        let root = try uploadRoot()
        cleanupStaleUploads(in: root)

        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let localURL = directory.appendingPathComponent(safeName, isDirectory: false)

        do {
            try data.write(to: localURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: localURL.path
            )
            let devicePath = try await service.stageAttachment(from: localURL)
            if !device.isLocal {
                try? FileManager.default.removeItem(at: directory)
            }
            return devicePath
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let uploadError = error as? AttachmentUploadError {
                throw uploadError
            }
            throw AttachmentUploadError.stagingFailed(error.localizedDescription)
        }
    }

    private static func uploadRoot() throws -> URL {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
            .appendingPathComponent("MobileUploads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        return root
    }

    private static func cleanupStaleUploads(in root: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for entry in entries {
            let modified = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
