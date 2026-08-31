import XCTest
@testable import HerdrKit

final class FleetWireTests: XCTestCase {
    func testHelloRoundTripUsesStableFieldNames() throws {
        let clientID = UUID()
        let message = FleetWireMessage.hello(
            FleetClientHello(
                clientID: clientID,
                clientName: "Phone",
                lastRevision: 12
            )
        )
        let frame = try FleetWireCodec.encode(message)
        let payload = frame.dropFirst(4)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "hello")
        let hello = try XCTUnwrap(object["payload"] as? [String: Any])
        XCTAssertEqual(hello["protocol"] as? Int, FleetBridgeProtocol.version)
        XCTAssertEqual(hello["client_id"] as? String, clientID.uuidString)
        XCTAssertEqual(hello["client_name"] as? String, "Phone")
        XCTAssertEqual(hello["last_revision"] as? Int, 12)

        var decoder = FleetWireDecoder()
        try decoder.append(frame)
        XCTAssertEqual(try decoder.nextMessage(), message)
    }

    func testDecoderHandlesFragmentedAndCoalescedFrames() throws {
        let first = try FleetWireCodec.encode(.ping)
        let second = try FleetWireCodec.encode(.pong)
        let bytes = first + second

        var decoder = FleetWireDecoder()
        try decoder.append(bytes.prefix(3))
        XCTAssertNil(try decoder.nextMessage())
        try decoder.append(bytes.dropFirst(3))
        XCTAssertEqual(try decoder.nextMessage(), .ping)
        XCTAssertEqual(try decoder.nextMessage(), .pong)
        XCTAssertNil(try decoder.nextMessage())
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecoderRejectsZeroLengthFrame() throws {
        var decoder = FleetWireDecoder()
        XCTAssertThrowsError(
            try decoder.append(Data([0, 0, 0, 0]))
        ) { error in
            XCTAssertEqual(error as? FleetWireError, .invalidLength)
        }
    }

    func testDecoderRejectsOversizedFrameBeforePayloadArrives() {
        var decoder = FleetWireDecoder(maximumFrameBytes: 8)
        XCTAssertThrowsError(
            try decoder.append(Data([0, 0, 0, 9]))
        ) { error in
            XCTAssertEqual(
                error as? FleetWireError,
                .frameTooLarge(limit: 8)
            )
        }
    }

    func testRPCResponseKeepsExactlyOneOutcome() throws {
        let id = UUID()
        let success = FleetRPCResponse.success(id: id, result: .string("ok"))
        XCTAssertEqual(success.result, .string("ok"))
        XCTAssertNil(success.error)

        let failure = FleetRPCResponse.failure(
            id: id,
            error: FleetRPCError(code: "denied", message: "Denied")
        )
        XCTAssertNil(failure.result)
        XCTAssertEqual(failure.error?.code, "denied")

        let malformed = Data(
            """
            {
              "id": "\(id.uuidString)",
              "result": "ok",
              "error": {
                "code": "denied",
                "message": "Denied",
                "retryable": false
              }
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(FleetRPCResponse.self, from: malformed)
        )
    }

    func testRPCResponsePreservesExplicitNullSuccess() throws {
        let response = FleetRPCResponse.success(id: UUID())
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(FleetRPCResponse.self, from: data)
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.result, .null)
    }

    func testWelcomeCarriesSanitizedSnapshotAndCapabilities() throws {
        let snapshot = FleetSnapshot(
            revision: 3,
            devices: [
                FleetDeviceSnapshot(
                    device: FleetDeviceInfo(
                        id: UUID(),
                        name: "Mac",
                        kind: .local,
                        osID: "macos"
                    ),
                    connection: .connected(version: "0.8.2")
                )
            ]
        )
        let welcome = FleetWireMessage.welcome(
            FleetServerWelcome(
                bridgeID: UUID(),
                bridgeName: "Studio",
                capabilities: [.observe, .control],
                snapshot: snapshot
            )
        )

        let frame = try FleetWireCodec.encode(welcome)
        var decoder = FleetWireDecoder()
        try decoder.append(frame)
        XCTAssertEqual(try decoder.nextMessage(), welcome)
    }
}
