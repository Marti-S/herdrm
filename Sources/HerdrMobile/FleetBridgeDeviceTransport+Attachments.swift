import Foundation
import HerdrKit

extension FleetBridgeDeviceTransport {
    func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String {
        guard attachment.bytes.count <= FleetAttachment.maximumBytes else {
            throw MobileAttachmentError.tooLarge(limit: FleetAttachment.maximumBytes)
        }
        let result = try await client.request(
            deviceID: deviceID,
            method: "bridge.attachment.stage",
            params: .object([
                "file_name": .string(
                    FleetAttachment.sanitizedFileName(attachment.fileName)
                ),
                "bytes": .string(attachment.bytes.base64EncodedString()),
            ])
        )
        guard let path = result["path"]?.stringValue, !path.isEmpty else {
            throw MobileAttachmentError.malformedStageResponse
        }
        return path
    }
}
