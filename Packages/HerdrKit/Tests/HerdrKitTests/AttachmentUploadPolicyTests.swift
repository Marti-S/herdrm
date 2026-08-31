import XCTest
@testable import HerdrKit

final class AttachmentUploadPolicyTests: XCTestCase {
    func testSanitizedFileNameDropsDirectoryPrefixes() {
        XCTAssertEqual(
            AttachmentUploadPolicy.sanitizedFileName("../../bad:name\\image.png"),
            "image.png"
        )
    }

    func testSanitizedFileNameReplacesReservedCharactersInBasename() {
        XCTAssertEqual(
            AttachmentUploadPolicy.sanitizedFileName("bad:name.png"),
            "bad-name.png"
        )
    }

    func testSanitizedFileNameReplacesEmptyAndDotComponents() {
        XCTAssertEqual(AttachmentUploadPolicy.sanitizedFileName(""), "attachment")
        XCTAssertEqual(AttachmentUploadPolicy.sanitizedFileName(".."), "attachment")
        XCTAssertEqual(AttachmentUploadPolicy.sanitizedFileName("\u{0}\n"), "attachment")
    }

    func testSanitizedFileNameHonorsUTF8ByteLimit() {
        let value = AttachmentUploadPolicy.sanitizedFileName(
            String(repeating: "文件", count: 100) + ".txt"
        )
        XCTAssertLessThanOrEqual(value.utf8.count, AttachmentUploadPolicy.maximumFileNameBytes)
        XCTAssertFalse(value.isEmpty)
    }

    func testFileAndSelectionBounds() throws {
        XCTAssertNoThrow(try AttachmentUploadPolicy.validateFileSize(
            AttachmentUploadPolicy.maximumFileBytes
        ))
        XCTAssertThrowsError(try AttachmentUploadPolicy.validateFileSize(
            AttachmentUploadPolicy.maximumFileBytes + 1
        ))
        XCTAssertNoThrow(try AttachmentUploadPolicy.validateSelection(
            fileCount: AttachmentUploadPolicy.maximumFiles,
            totalBytes: AttachmentUploadPolicy.maximumSelectionBytes
        ))
        XCTAssertThrowsError(try AttachmentUploadPolicy.validateSelection(
            fileCount: AttachmentUploadPolicy.maximumFiles + 1,
            totalBytes: 0
        ))
        XCTAssertThrowsError(try AttachmentUploadPolicy.validateSelection(
            fileCount: 1,
            totalBytes: AttachmentUploadPolicy.maximumSelectionBytes + 1
        ))
    }
}
