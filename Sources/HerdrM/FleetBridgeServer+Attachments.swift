import Foundation
import HerdrKit

extension FleetBridgeServer {
    /// Persists a mobile-selected file on the target device and returns the
    /// device-local path that should be inserted into an Agent prompt.
    func stageAttachment(
        deviceID: UUID,
        fileName: String,
        bytes: Data
    ) async throws -> String {
        guard bytes.count <= FleetAttachment.maximumBytes else {
            throw FleetBridgeHostError.invalidRequest(
                "Attachments may not exceed \(FleetAttachment.maximumBytes) bytes."
            )
        }
        guard let model else {
            throw FleetBridgeHostError.invalidRequest("HerdrM is not ready.")
        }
        guard let device = model.device(deviceID) else {
            throw FleetBridgeHostError.unknownDevice(deviceID)
        }
        guard case .connected = model.session(device.id).connection else {
            throw FleetBridgeHostError.invalidRequest("The selected device is not connected.")
        }

        let localURL = try await Self.writeAttachmentToProtectedCache(
            fileName: fileName,
            bytes: bytes
        )
        if device.isLocal {
            // The local Agent reads this path directly. Old cache entries are
            // pruned whenever another mobile attachment is staged.
            return localURL.path
        }

        defer { try? FileManager.default.removeItem(at: localURL) }
        return try await model.service(for: device).stageAttachment(from: localURL)
    }

    private nonisolated static func writeAttachmentToProtectedCache(
        fileName: String,
        bytes: Data
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let base = manager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HerdrM", isDirectory: true)
                .appendingPathComponent("MobileAttachments", isDirectory: true)
            try manager.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: base.path
            )

            let expiry = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            if let entries = try? manager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in entries {
                    let values = try? entry.resourceValues(
                        forKeys: [.contentModificationDateKey, .isRegularFileKey]
                    )
                    if values?.isRegularFile == true,
                       let modified = values?.contentModificationDate,
                       modified < expiry {
                        try? manager.removeItem(at: entry)
                    }
                }
            }

            let safeName = FleetAttachment.sanitizedFileName(fileName)
            let destination = base.appendingPathComponent(
                "\(UUID().uuidString.lowercased())-\(safeName)",
                isDirectory: false
            )
            try bytes.write(to: destination, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
            return destination
        }.value
    }
}
