#if canImport(CryptoKit) && canImport(Security)
import Foundation
import XCTest
@testable import HerdrKit

final class FleetPairingWireTests: XCTestCase {
    func testClientRequestRoundTrip() throws {
        let request = FleetPairingRequest(
            invitationID: UUID(),
            bridgeID: UUID(),
            clientID: UUID(),
            clientName: "Phone",
            secret: try XCTUnwrap(
                FleetPairingSecret(bytes: Data(repeating: 0x11, count: 32))
            )
        )
        let message = FleetPairingClientMessage.redeem(request)
        let frame = try FleetPairingWire.encode(message)
        var decoder = FleetPairingWireDecoder<FleetPairingClientMessage>()
        XCTAssertEqual(try decoder.append(frame), [message])
        try decoder.finish()
    }

    func testServerCredentialRoundTrip() throws {
        let credential = FleetClientCredential(
            bridgeID: UUID(),
            clientID: UUID(),
            clientName: "Phone",
            token: FleetPairingSecret.encodeBase64URL(Data(repeating: 0x22, count: 32)),
            capabilities: [.observe, .control],
            issuedAt: Date(timeIntervalSince1970: 1_000)
        )
        let message = FleetPairingServerMessage.credential(credential)
        var decoder = FleetPairingWireDecoder<FleetPairingServerMessage>()
        XCTAssertEqual(
            try decoder.append(FleetPairingWire.encode(message)),
            [message]
        )
    }

    func testFragmentedAndCoalescedFrames() throws {
        let first = FleetPairingServerMessage.error(
            FleetPairingRemoteError(code: "first", message: "one")
        )
        let second = FleetPairingServerMessage.error(
            FleetPairingRemoteError(code: "second", message: "two")
        )
        let firstFrame = try FleetPairingWire.encode(first)
        let combined = firstFrame + (try FleetPairingWire.encode(second))
        var decoder = FleetPairingWireDecoder<FleetPairingServerMessage>()

        XCTAssertTrue(try decoder.append(Data(combined.prefix(3))).isEmpty)
        XCTAssertEqual(
            try decoder.append(Data(combined.dropFirst(3))),
            [first, second]
        )
        try decoder.finish()
    }

    func testZeroAndOversizedLengthsAreRejectedBeforePayload() throws {
        var decoder = FleetPairingWireDecoder<FleetPairingServerMessage>(maximumPayloadBytes: 32)
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0]))) { error in
            XCTAssertEqual(error as? FleetPairingWireError, .emptyFrame)
        }

        var oversized = FleetPairingWireDecoder<FleetPairingServerMessage>(
            maximumPayloadBytes: 32
        )
        XCTAssertThrowsError(try oversized.append(Data([0, 0, 0, 33]))) { error in
            XCTAssertEqual(error as? FleetPairingWireError, .frameTooLarge(32))
        }
    }

    func testFinishRejectsPartialFrame() throws {
        let message = FleetPairingServerMessage.error(
            FleetPairingRemoteError(code: "x", message: "y")
        )
        let frame = try FleetPairingWire.encode(message)
        var decoder = FleetPairingWireDecoder<FleetPairingServerMessage>()
        XCTAssertTrue(try decoder.append(Data(frame.dropLast())).isEmpty)
        XCTAssertThrowsError(try decoder.finish()) { error in
            XCTAssertEqual(error as? FleetPairingWireError, .unexpectedEOF)
        }
    }
} 
#endif