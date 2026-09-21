import XCTest
@testable import HerdrKit

final class TerminalSessionWireTests: XCTestCase {
    func testDecodesHerdrTerminalFrameEnvelope() throws {
        let bytes = Data([0x1B, 0x5B, 0x32, 0x4A])
        let line = Data("""
            {"type":"terminal.frame","seq":7,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"\(bytes.base64EncodedString())"}
            """.utf8)

        XCTAssertEqual(
            try TerminalSessionWire.decodeRecord(line),
            .frame(
                TerminalFrame(
                    sequence: 7,
                    width: 80,
                    height: 24,
                    isFull: true,
                    bytes: bytes
                )
            )
        )
    }

    func testDecodesClosedEnvelope() throws {
        let line = Data(#"{"type":"terminal.closed","reason":"taken over"}"#.utf8)
        XCTAssertEqual(
            try TerminalSessionWire.decodeRecord(line),
            .closed(reason: "taken over")
        )
    }

    func testEncodesInputAsBase64NDJSON() throws {
        let payload = Data([0x00, 0x1B, 0xFF])
        let data = try TerminalSessionWire.encodeInput(payload)
        XCTAssertEqual(data.last, 0x0A)
        let object = try jsonObject(data)
        XCTAssertEqual(object["type"] as? String, "terminal.input")
        XCTAssertEqual(object["bytes"] as? String, payload.base64EncodedString())
    }

    func testEncodesResizeUsingHerdrControlFields() throws {
        let data = try TerminalSessionWire.encodeResize(
            TerminalSize(
                columns: 120,
                rows: 40,
                cellWidthPixels: 9,
                cellHeightPixels: 18
            )
        )
        let object = try jsonObject(data)
        XCTAssertEqual(object["type"] as? String, "terminal.resize")
        XCTAssertEqual(object["cols"] as? Int, 120)
        XCTAssertEqual(object["rows"] as? Int, 40)
        XCTAssertEqual(object["cell_width_px"] as? Int, 9)
        XCTAssertEqual(object["cell_height_px"] as? Int, 18)
    }

    func testEncodesRelease() throws {
        let object = try jsonObject(TerminalSessionWire.encodeRelease())
        XCTAssertEqual(object["type"] as? String, "terminal.release")
        XCTAssertEqual(object.count, 1)
    }

    func testIncrementalDecoderHandlesSplitAndCoalescedRecords() throws {
        let first = Data(#"{"type":"terminal.frame","seq":1,"encoding":"ansi","width":2,"height":1,"full":true,"bytes":"YQ=="}"#.utf8)
        let second = Data(#"{"type":"terminal.closed","reason":null}"#.utf8)
        let stream = first + Data([0x0A]) + second + Data([0x0A])

        var decoder = TerminalSessionRecordDecoder()
        try decoder.append(stream.prefix(19))
        XCTAssertNil(try decoder.nextRecord())
        try decoder.append(stream.dropFirst(19))
        XCTAssertEqual(
            try decoder.nextRecord(),
            .frame(TerminalFrame(sequence: 1, width: 2, height: 1, isFull: true, bytes: Data("a".utf8)))
        )
        XCTAssertEqual(try decoder.nextRecord(), .closed(reason: nil))
        XCTAssertNil(try decoder.nextRecord())
    }


    func testIncrementalDecoderBoundsIncompleteRecord() {
        var decoder = TerminalSessionRecordDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try decoder.append(Data("12345".utf8))) { error in
            XCTAssertEqual(
                error as? TerminalSessionWireError,
                .recordTooLarge(limit: 4)
            )
        }
    }

    func testRejectsUnknownRecordType() {
        XCTAssertThrowsError(
            try TerminalSessionWire.decodeRecord(Data(#"{"type":"other"}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? TerminalSessionWireError,
                .unsupportedRecordType("other")
            )
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        var line = data
        if line.last == 0x0A { line.removeLast() }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: line) as? [String: Any]
        )
    }
}
