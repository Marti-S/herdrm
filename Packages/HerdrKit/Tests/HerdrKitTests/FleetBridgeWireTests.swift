import XCTest
@testable import HerdrKit

final class FleetBridgeWireTests: XCTestCase {
    func testHelloRoundTrip() throws {
        let hello = FleetBridgeHello(token: "secret", clientID: UUID(), clientName: "Phone")
        let encoded = try FleetBridgeWire.encodeClient(.hello(hello))
        XCTAssertEqual(try FleetBridgeWire.decodeClient(encoded), .hello(hello))
        XCTAssertEqual(encoded.last, 0x0A)
    }

    func testRPCRoundTripPreservesDynamicJSON() throws {
        let request = FleetBridgeRPCRequest(
            deviceID: UUID(),
            method: "pane.send_input",
            params: .object([
                "pane_id": .string("w1:p1"),
                "keys": .array([.string("enter"), .string("ctrl+c")]),
            ])
        )
        XCTAssertEqual(
            try FleetBridgeWire.decodeClient(FleetBridgeWire.encodeClient(.rpc(request))),
            .rpc(request)
        )
    }

    func testSnapshotRoundTrip() throws {
        let descriptor = FleetDeviceDescriptor(
            id: UUID(), name: "Mac", kind: .local, osID: "macos"
        )
        let snapshot = FleetSnapshot(
            revision: 42,
            devices: [
                FleetDeviceSnapshot(
                    device: descriptor,
                    connection: .connected(version: "0.8.2"),
                    snapshot: nil,
                    availableAgentKinds: ["codex", "claude"]
                )
            ]
        )
        let record = FleetBridgeSnapshotRecord(requestID: UUID(), snapshot: snapshot)
        XCTAssertEqual(
            try FleetBridgeWire.decodeServer(FleetBridgeWire.encodeServer(.snapshot(record))),
            .snapshot(record)
        )
    }

    func testRemoteDescriptorContainsNoEndpointMetadata() throws {
        let descriptor = FleetDeviceDescriptor(
            id: UUID(), name: "Build Mac", kind: .remote, osID: "macos"
        )
        let json = String(decoding: try JSONEncoder().encode(descriptor), as: UTF8.self)
        XCTAssertFalse(json.contains("username"))
        XCTAssertFalse(json.contains("host"))
        XCTAssertFalse(json.contains("port"))
        XCTAssertFalse(json.contains("subtitle"))
        XCTAssertEqual(descriptor.subtitle, "Remote device")
    }

    func testFleetReferencesSeparateDevices() {
        let paneID = "w1:p1"
        let first = FleetPaneRef(deviceID: UUID(), paneID: paneID)
        let second = FleetPaneRef(deviceID: UUID(), paneID: paneID)
        XCTAssertNotEqual(first, second)
    }

    func testTerminalRecordsRoundTrip() throws {
        let streamID = UUID()
        let open = FleetBridgeTerminalOpenRequest(
            streamID: streamID,
            deviceID: UUID(),
            target: FleetTerminalTarget(kind: .agent, value: "w1:p1"),
            mode: .control(takeover: true),
            size: TerminalSize(columns: 80, rows: 24)
        )
        XCTAssertEqual(
            try FleetBridgeWire.decodeClient(FleetBridgeWire.encodeClient(.terminalOpen(open))),
            .terminalOpen(open)
        )

        let frame = FleetBridgeTerminalFrameRecord(
            streamID: streamID,
            frame: TerminalFrame(
                sequence: 7,
                width: 80,
                height: 24,
                isFull: true,
                bytes: Data([0, 1, 2, 255])
            )
        )
        XCTAssertEqual(
            try FleetBridgeWire.decodeServer(FleetBridgeWire.encodeServer(.terminalFrame(frame))),
            .terminalFrame(frame)
        )
    }

    func testIncrementalDecoderHandlesSplitAndCoalescedRecords() throws {
        let first = try FleetBridgeWire.encodeClient(
            .snapshot(FleetBridgeSnapshotRequest(id: UUID()))
        )
        let second = try FleetBridgeWire.encodeClient(
            .subscribe(FleetBridgeSubscribeRequest(id: UUID(), afterRevision: 9))
        )
        let combined = first + second
        let split = combined.count / 3
        var decoder = FleetBridgeRecordDecoder()
        try decoder.append(combined.prefix(split))
        XCTAssertNil(try decoder.nextRecordData())
        try decoder.append(combined.dropFirst(split))
        XCTAssertNotNil(try decoder.nextRecordData())
        XCTAssertNotNil(try decoder.nextRecordData())
        XCTAssertNil(try decoder.nextRecordData())
    }

    func testDecoderRejectsOversizedUnterminatedRecord() throws {
        var decoder = FleetBridgeRecordDecoder(maximumRecordBytes: 4)
        XCTAssertThrowsError(try decoder.append(Data(repeating: 0x61, count: 5))) { error in
            XCTAssertEqual(error as? FleetBridgeWireError, .recordTooLarge(limit: 4))
        }
    }

    func testUnsupportedTypeIsRejected() throws {
        let data = Data(#"{"type":"unknown","payload":{}}"#.utf8)
        XCTAssertThrowsError(try FleetBridgeWire.decodeClient(data)) { error in
            XCTAssertEqual(
                error as? FleetBridgeWireError,
                .unsupportedRecordType("unknown")
            )
        }
    }
}
