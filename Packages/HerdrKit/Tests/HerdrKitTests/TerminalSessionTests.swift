import XCTest
@testable import HerdrKit

final class TerminalSessionTests: XCTestCase {
    func testObserveModeIsReadOnlyAndNeverTakesOver() {
        let mode = TerminalSessionMode(access: .observe, takeover: true)

        XCTAssertEqual(mode, .observe)
        XCTAssertFalse(mode.allowsInput)
        XCTAssertFalse(mode.allowsResize)
        XCTAssertFalse(mode.takeover)
    }

    func testControlModePreservesTakeoverIntent() {
        let mode = TerminalSessionMode.control(takeover: true)

        XCTAssertEqual(mode.access, .control)
        XCTAssertTrue(mode.allowsInput)
        XCTAssertTrue(mode.allowsResize)
        XCTAssertTrue(mode.takeover)
    }

    func testTerminalFrameCodableRoundTripUsesHerdrWireFields() throws {
        let frame = TerminalFrame(
            sequence: 42,
            width: 120,
            height: 36,
            isFull: true,
            bytes: Data([0x1B, 0x5B, 0x32, 0x4A])
        )

        let data = try JSONEncoder().encode(frame)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["seq"] as? Int, 42)
        XCTAssertEqual(object["encoding"] as? String, "ansi")
        XCTAssertEqual(object["width"] as? Int, 120)
        XCTAssertEqual(object["height"] as? Int, 36)
        XCTAssertEqual(object["full"] as? Bool, true)

        let decoded = try JSONDecoder().decode(TerminalFrame.self, from: data)
        XCTAssertEqual(decoded, frame)
        XCTAssertEqual(decoded.size, TerminalSize(columns: 120, rows: 36))
    }

    func testTerminalSizeUsesControlWireFields() throws {
        let size = TerminalSize(
            columns: 80,
            rows: 24,
            cellWidthPixels: 9,
            cellHeightPixels: 18
        )

        let data = try JSONEncoder().encode(size)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["cols"] as? Int, 80)
        XCTAssertEqual(object["rows"] as? Int, 24)
        XCTAssertEqual(object["cell_width_px"] as? Int, 9)
        XCTAssertEqual(object["cell_height_px"] as? Int, 18)
        XCTAssertEqual(try JSONDecoder().decode(TerminalSize.self, from: data), size)
    }

    func testTerminalSizeRejectsEmptyGrid() {
        XCTAssertTrue(TerminalSize(columns: 80, rows: 24).isValid)
        XCTAssertFalse(TerminalSize(columns: 0, rows: 24).isValid)
        XCTAssertFalse(TerminalSize(columns: 80, rows: 0).isValid)
    }
}
