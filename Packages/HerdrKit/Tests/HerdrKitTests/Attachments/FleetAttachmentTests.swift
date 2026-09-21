import XCTest
@testable import HerdrKit

final class FleetAttachmentTests: XCTestCase {
    func testSanitizedFileNameDropsPathComponents() {
        XCTAssertEqual(
            FleetAttachment.sanitizedFileName("../../private/report final.pdf"),
            "report final.pdf"
        )
        XCTAssertEqual(
            FleetAttachment.sanitizedFileName(#"C:\Users\me\image.png"#),
            "image.png"
        )
    }

    func testSanitizedFileNameReplacesControlsAndReservedSeparators() {
        XCTAssertEqual(
            FleetAttachment.sanitizedFileName("report:\u{0000}draft.txt"),
            "report__draft.txt"
        )
    }

    func testSanitizedFileNameUsesFallbackForEmptyTraversalNames() {
        XCTAssertEqual(FleetAttachment.sanitizedFileName("../.."), "attachment")
        XCTAssertEqual(FleetAttachment.sanitizedFileName("  \n"), "attachment")
    }

    func testSanitizedFileNameIsUtf8Bounded() {
        let value = FleetAttachment.sanitizedFileName(String(repeating: "é", count: 200))
        XCTAssertLessThanOrEqual(value.utf8.count, FleetAttachment.maximumFileNameBytes)
        XCTAssertFalse(value.isEmpty)
    }

    func testAttachmentLimitFitsBridgeRecordAfterBase64Expansion() {
        let expanded = ((FleetAttachment.maximumBytes + 2) / 3) * 4
        XCTAssertLessThan(expanded, 64 * 1024 * 1024)
    }
}
