import Foundation
import XCTest
@testable import HerdrKit

final class FleetBridgeHostTests: XCTestCase {
    func testHandshakeRequestPingAndSnapshotPublish() async throws {
        let initial = FleetSnapshot(revision: 1, devices: [])
        let requested = LockedRequest()
        let host = FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe, .control],
            initialSnapshot: initial,
            requestHandler: { request in
                await requested.set(request)
                return .success(id: request.id, result: .string("ok"))
            }
        )
        let pair = MemoryByteStream.makePair()
        await host.accept(pair.server)
        let client = TestFleetClient(stream: pair.client)

        try await client.send(
            .hello(
                FleetClientHello(
                    clientID: UUID(),
                    clientName: "Phone",
                    lastRevision: nil
                )
            )
        )

        guard case .welcome(let welcome)? = try await client.receive() else {
            return XCTFail("expected welcome")
        }
        XCTAssertEqual(welcome.bridgeName, "Studio")
        XCTAssertEqual(welcome.capabilities, [.observe, .control])
        XCTAssertEqual(welcome.snapshot, initial)

        let request = FleetRPCRequest(
            deviceID: UUID(),
            method: "agent.prompt",
            params: .object(["text": .string("continue")])
        )
        try await client.send(.request(request))
        guard case .response(let response)? = try await client.receive() else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(response, .success(id: request.id, result: .string("ok")))
        XCTAssertEqual(await requested.value(), request)

        try await client.send(.ping)
        XCTAssertEqual(try await client.receive(), .pong)

        let next = FleetSnapshot(revision: 2, devices: [])
        XCTAssertTrue(await host.publish(next))
        guard case .snapshot(let update)? = try await client.receive() else {
            return XCTFail("expected snapshot update")
        }
        XCTAssertEqual(update.reason, .changed)
        XCTAssertEqual(update.snapshot, next)
        XCTAssertFalse(await host.publish(initial))

        await pair.client.close()
        await eventually { await host.activeConnectionCount == 0 }
        await host.stop()
    }

    func testRejectsIncompatibleProtocolBeforeWelcome() async throws {
        let host = testHost()
        let pair = MemoryByteStream.makePair()
        await host.accept(pair.server)
        let client = TestFleetClient(stream: pair.client)

        try await client.send(
            .hello(
                FleetClientHello(
                    protocolVersion: FleetBridgeProtocol.version + 1,
                    clientID: UUID(),
                    clientName: "Future phone"
                )
            )
        )
        XCTAssertNil(try await client.receive())
        await eventually { await host.activeConnectionCount == 0 }
        await host.stop()
    }

    func testFirstMessageMustBeHello() async throws {
        let host = testHost()
        let pair = MemoryByteStream.makePair()
        await host.accept(pair.server)
        let client = TestFleetClient(stream: pair.client)

        try await client.send(.ping)
        XCTAssertNil(try await client.receive())
        await eventually { await host.activeConnectionCount == 0 }
        await host.stop()
    }

    func testRejectsRequestThatRequiresANewerSnapshot() async throws {
        let called = LockedFlag()
        let host = FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe],
            initialSnapshot: FleetSnapshot(revision: 4, devices: []),
            requestHandler: { request in
                await called.set()
                return .success(id: request.id)
            }
        )
        let pair = MemoryByteStream.makePair()
        await host.accept(pair.server)
        let client = TestFleetClient(stream: pair.client)
        try await client.send(
            .hello(FleetClientHello(clientID: UUID(), clientName: "Phone"))
        )
        _ = try await client.receive()

        let request = FleetRPCRequest(
            deviceID: UUID(),
            method: "agent.prompt",
            minimumRevision: 5
        )
        try await client.send(.request(request))
        guard case .response(let response)? = try await client.receive() else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(response.error?.code, "stale_revision")
        XCTAssertEqual(response.error?.retryable, true)
        let wasCalled = await called.value()
        XCTAssertFalse(wasCalled)
        await host.stop()
    }

    func testConcurrentResponsesAndSnapshotUpdatesRemainFramed() async throws {
        let gate = AsyncGate()
        let host = FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe, .control],
            initialSnapshot: FleetSnapshot(revision: 1, devices: []),
            requestHandler: { request in
                await gate.wait()
                return .success(id: request.id, result: .string("done"))
            }
        )
        let pair = MemoryByteStream.makePair(maximumWriteChunk: 7)
        await host.accept(pair.server)
        let client = TestFleetClient(stream: pair.client)

        try await client.send(
            .hello(FleetClientHello(clientID: UUID(), clientName: "Phone"))
        )
        _ = try await client.receive()

        let request = FleetRPCRequest(deviceID: UUID(), method: "agent.prompt")
        try await client.send(.request(request))
        let publishTask = Task {
            await host.publish(FleetSnapshot(revision: 2, devices: []))
        }
        await gate.open()

        let messages = [try await client.receive(), try await client.receive()]
        XCTAssertTrue(messages.contains(.snapshot(
            FleetSnapshotUpdate(
                reason: .changed,
                snapshot: FleetSnapshot(revision: 2, devices: [])
            )
        )))
        XCTAssertTrue(messages.contains(.response(
            .success(id: request.id, result: .string("done"))
        )))
        XCTAssertTrue(await publishTask.value)
        await host.stop()
    }

    private func testHost() -> FleetBridgeHost {
        FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe],
            initialSnapshot: FleetSnapshot(revision: 1, devices: []),
            requestHandler: { .success(id: $0.id) }
        )
    }

    private func eventually(
        attempts: Int = 100,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition did not become true")
    }
}

private actor LockedRequest {
    private var request: FleetRPCRequest?
    func set(_ request: FleetRPCRequest) { self.request = request }
    func value() -> FleetRPCRequest? { request }
}

private actor LockedFlag {
    private var isSet = false
    func set() { isSet = true }
    func value() -> Bool { isSet }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor MemoryInbox {
    private var chunks: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false

    func enqueue(_ data: Data, maximumChunk: Int?) {
        guard !finished else { return }
        let pieces: [Data]
        if let maximumChunk, data.count > maximumChunk {
            pieces = stride(from: 0, to: data.count, by: maximumChunk).map { offset in
                Data(data[offset..<min(offset + maximumChunk, data.count)])
            }
        } else {
            pieces = [data]
        }

        for piece in pieces {
            if let waiter {
                self.waiter = nil
                waiter.resume(returning: piece)
            } else {
                chunks.append(piece)
            }
        }
    }

    func read(maximumBytes: Int) async -> Data? {
        if !chunks.isEmpty {
            let data = chunks.removeFirst()
            if data.count <= maximumBytes { return data }
            let head = Data(data.prefix(maximumBytes))
            chunks.insert(Data(data.dropFirst(maximumBytes)), at: 0)
            return head
        }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            precondition(waiter == nil)
            waiter = continuation
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        waiter?.resume(returning: nil)
        waiter = nil
        chunks.removeAll()
    }
}

private struct MemoryByteStream: FleetBridgeByteStream {
    let incoming: MemoryInbox
    let outgoing: MemoryInbox
    let maximumWriteChunk: Int?

    struct Pair {
        let client: MemoryByteStream
        let server: MemoryByteStream
    }

    static func makePair(maximumWriteChunk: Int? = nil) -> Pair {
        let clientInbox = MemoryInbox()
        let serverInbox = MemoryInbox()
        return Pair(
            client: MemoryByteStream(
                incoming: clientInbox,
                outgoing: serverInbox,
                maximumWriteChunk: maximumWriteChunk
            ),
            server: MemoryByteStream(
                incoming: serverInbox,
                outgoing: clientInbox,
                maximumWriteChunk: maximumWriteChunk
            )
        )
    }

    func read(maximumBytes: Int) async throws -> Data? {
        await incoming.read(maximumBytes: maximumBytes)
    }

    func write(_ data: Data) async throws {
        await outgoing.enqueue(data, maximumChunk: maximumWriteChunk)
    }

    func close() async {
        await incoming.finish()
        await outgoing.finish()
    }
}

private actor TestFleetClient {
    private let stream: MemoryByteStream
    private var decoder = FleetWireDecoder()

    init(stream: MemoryByteStream) {
        self.stream = stream
    }

    func send(_ message: FleetWireMessage) async throws {
        try await stream.write(FleetWireCodec.encode(message))
    }

    func receive() async throws -> FleetWireMessage? {
        while true {
            if let message = try decoder.nextMessage() { return message }
            guard let data = try await stream.read(maximumBytes: 64 * 1024) else {
                return nil
            }
            try decoder.append(data)
        }
    }
}
