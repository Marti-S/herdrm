import Foundation
import XCTest
@testable import HerdrKit

private enum ObservationTestError: Error { case timeout, unsupported }

private actor ObservationSession: TerminalSession {
    nonisolated let mode = TerminalSessionMode.observe
    private var waiter: CheckedContinuation<TerminalFrame?, Error>?
    private var frames: [TerminalFrame] = []
    private(set) var isClosed = false
    func read() async throws -> TerminalFrame? {
        if isClosed { return nil }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
    func frame() {
        let frame = TerminalFrame(sequence: 1, width: 80, height: 24, bytes: Data([1]))
        if let waiter { self.waiter = nil; waiter.resume(returning: frame) }
        else { frames.append(frame) }
    }
    func send(_ data: Data) async throws { throw TerminalSessionError.readOnly }
    func resize(_ size: TerminalSize) async throws { throw TerminalSessionError.readOnly }
    func close() {
        isClosed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
private actor ObservationReads {
    private(set) var calls = 0
    private(set) var delivered = 0
    func read() -> TerminalReadResult {
        calls += 1
        return TerminalReadResult(paneID: "p", workspaceID: "w", tabID: "t", source: .recentUnwrapped,
                                  format: .text, text: "output", revision: UInt64(calls), truncated: false)
    }
    func receive() { delivered += 1 }
}
final class ObservedTranscriptTests: XCTestCase {
    private func eventually(_ condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ObservationTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testIdleObserverDoesNotPollAndCancellationClosesSession() async throws {
        let session = ObservationSession(), reads = ObservationReads()
        let stream = ObservedTranscript.reads(minimumInterval: .milliseconds(10), open: { session }, read: { await reads.read() })
        let consumer = Task { for try await _ in stream { await reads.receive() } }
        try await eventually { await reads.delivered == 1 }
        try await Task.sleep(for: .milliseconds(80))
        let idleCalls = await reads.calls
        XCTAssertEqual(idleCalls, 1)
        await session.frame()
        try await eventually { await reads.delivered == 2 }
        consumer.cancel()
        _ = try? await consumer.value
        try await eventually { await session.isClosed }
    }

    func testUnsupportedObservationUsesCompatibilityRead() async throws {
        let reads = ObservationReads()
        let stream = ObservedTranscript.reads(open: { throw ObservationTestError.unsupported }, read: { await reads.read() })
        let consumer = Task {
            for try await value in stream {
                XCTAssertEqual(value.text, "output")
                await reads.receive()
            }
        }
        try await eventually { await reads.delivered == 1 }
        consumer.cancel()
        _ = try? await consumer.value
    }
}
