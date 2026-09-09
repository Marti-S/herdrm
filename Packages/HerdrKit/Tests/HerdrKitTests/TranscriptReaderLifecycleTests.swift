import Foundation
import XCTest
@testable import HerdrKit

private enum ReaderTestError: Error { case timeout, failed }

private func readerSnapshot(_ text: String, sequence: UInt64 = 1) -> TranscriptSnapshot {
    TranscriptSnapshot(providerID: "pane", source: .terminalRecentUnwrapped, sequence: sequence,
                       items: TerminalTranscriptItems.make(text: text, providerID: "pane"))
}

private actor ReaderFixture {
    private var value: TranscriptSnapshot
    private var shouldBlock = false
    private var pending: [(TranscriptSnapshot, CheckedContinuation<TranscriptSnapshot, Error>)] = []
    private var streams: [UUID: AsyncThrowingStream<TranscriptEvent, Error>.Continuation] = [:]
    private(set) var snapshotCalls = 0
    private(set) var streamCalls = 0

    init(_ value: TranscriptSnapshot) { self.value = value }
    func blockSnapshots() { shouldBlock = true }
    func set(_ value: TranscriptSnapshot) { self.value = value }
    func snapshot() async throws -> TranscriptSnapshot {
        snapshotCalls += 1
        let captured = value
        if shouldBlock {
            // Deliberately ignore cancellation to emulate a delayed old transport reply.
            return try await withCheckedThrowingContinuation { pending.append((captured, $0)) }
        }
        return captured
    }
    func releaseSnapshots() {
        shouldBlock = false
        let captured = pending
        pending.removeAll()
        for (snapshot, continuation) in captured { continuation.resume(returning: snapshot) }
    }
    func attach(_ continuation: AsyncThrowingStream<TranscriptEvent, Error>.Continuation, id: UUID) {
        guard !Task.isCancelled else { continuation.finish(); return }
        streams[id] = continuation
        streamCalls += 1
    }
    func detach(_ id: UUID) { streams.removeValue(forKey: id) }
    func emit(_ value: TranscriptSnapshot) {
        self.value = value
        for stream in streams.values { stream.yield(.snapshot(value)) }
    }
    func finish() {
        for stream in streams.values { stream.finish() }
        streams.removeAll()
    }
    nonisolated func updates() -> AsyncThrowingStream<TranscriptEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            let registration = Task { await self.attach(continuation, id: id) }
            continuation.onTermination = { _ in
                registration.cancel()
                Task { await self.detach(id) }
            }
        }
    }
}

private struct ReaderProvider: AgentTranscriptProvider {
    let fixture: ReaderFixture
    func snapshot() async throws -> TranscriptSnapshot { try await fixture.snapshot() }
    func updates(after sequence: UInt64?) -> AsyncThrowingStream<TranscriptEvent, Error> { fixture.updates() }
}
private struct StreamingReaderProvider: SnapshotFirstTranscriptProvider {
    let fixture: ReaderFixture
    func snapshot() async throws -> TranscriptSnapshot { try await fixture.snapshot() }
    func updates(after sequence: UInt64?) -> AsyncThrowingStream<TranscriptEvent, Error> { fixture.updates() }
}

final class TranscriptReaderLifecycleTests: XCTestCase {
    @MainActor
    private func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw ReaderTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @MainActor
    func testRebindIgnoresDelayedOldInitialSnapshot() async throws {
        let old = ReaderFixture(readerSnapshot("old")), new = ReaderFixture(readerSnapshot("new"))
        await old.blockSnapshots()
        let reader = TranscriptReader(provider: ReaderProvider(fixture: old))
        let start = Task { await reader.start() }
        try await eventually { await old.snapshotCalls == 1 }
        let binding = UUID()
        reader.rebind(provider: ReaderProvider(fixture: new), bindingID: binding)
        try await eventually { reader.snapshot?.items == readerSnapshot("new").items }
        await old.releaseSnapshots()
        await start.value
        XCTAssertEqual(reader.bindingID, binding)
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("new").items)
        XCTAssertEqual(reader.loadState, .ready)
        reader.stop()
    }

    @MainActor
    func testRepeatedStartCoalescesInitialLoadsAndSubscriptions() async throws {
        let fixture = ReaderFixture(readerSnapshot("ready"))
        await fixture.blockSnapshots()
        let reader = TranscriptReader(provider: ReaderProvider(fixture: fixture))
        let first = Task { await reader.start() }
        let second = Task { await reader.start() }
        try await eventually { await fixture.snapshotCalls == 1 }
        await fixture.releaseSnapshots()
        await first.value; await second.value
        try await eventually { await fixture.streamCalls == 1 }
        await reader.start()
        let calls = await fixture.snapshotCalls
        XCTAssertEqual(calls, 1)
        reader.stop()
    }

    @MainActor
    func testManualRefreshCannotOverwriteNewerStreamOutput() async throws {
        let fixture = ReaderFixture(readerSnapshot("initial"))
        let reader = TranscriptReader(provider: ReaderProvider(fixture: fixture))
        await reader.start()
        try await eventually { await fixture.streamCalls == 1 }
        await fixture.set(readerSnapshot("stale refresh", sequence: 2))
        await fixture.blockSnapshots()
        let refresh = Task { await reader.refreshAndWait() }
        try await eventually { await fixture.snapshotCalls == 2 }
        await fixture.emit(readerSnapshot("new streaming output", sequence: 3))
        try await eventually { reader.revision == 3 }
        await fixture.releaseSnapshots()
        await refresh.value
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("new streaming output").items)
        reader.stop()
    }

    @MainActor
    func testSuspendAndResumeRebindKeepsCachedContent() async throws {
        let old = ReaderFixture(readerSnapshot("cached")), new = ReaderFixture(readerSnapshot("fresh", sequence: 2))
        let reader = TranscriptReader(provider: ReaderProvider(fixture: old))
        await reader.start()
        reader.suspend()
        reader.rebind(provider: ReaderProvider(fixture: new), bindingID: UUID())
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("cached").items)
        let before = await new.snapshotCalls
        XCTAssertEqual(before, 0)
        reader.resume()
        try await eventually { reader.revision == 2 }
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("fresh").items)
        reader.stop()
    }

    @MainActor
    func testPinnedReaderRetainsVisibleContentUntilUserResumes() async throws {
        let fixture = ReaderFixture(readerSnapshot("reading"))
        let reader = TranscriptReader(provider: ReaderProvider(fixture: fixture))
        await reader.start()
        try await eventually { await fixture.streamCalls == 1 }
        reader.setPinnedToLatest(false)
        await fixture.emit(readerSnapshot("new output", sequence: 2))
        try await eventually { reader.hasNewOutput }
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("reading").items)
        let version = reader.contentVersion
        reader.resumeFollowing()
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("new output").items)
        XCTAssertEqual(reader.contentVersion, version + 1)
        XCTAssertFalse(reader.hasNewOutput)
        reader.stop()
    }

    @MainActor
    func testRevisionOnlyChangeDoesNotInvalidateRenderedContent() async throws {
        let fixture = ReaderFixture(readerSnapshot("unchanged"))
        let reader = TranscriptReader(provider: ReaderProvider(fixture: fixture))
        await reader.start()
        try await eventually { await fixture.streamCalls == 1 }
        let version = reader.contentVersion
        await fixture.emit(readerSnapshot("unchanged", sequence: 10))
        try await eventually { reader.revision == 10 }
        XCTAssertEqual(reader.contentVersion, version)
        reader.stop()
    }

    @MainActor
    func testSnapshotFirstProviderDoesNotPerformDuplicateInitialRPC() async throws {
        let fixture = ReaderFixture(readerSnapshot("not requested"))
        let reader = TranscriptReader(provider: StreamingReaderProvider(fixture: fixture))
        await reader.start()
        try await eventually { await fixture.streamCalls == 1 }
        let calls = await fixture.snapshotCalls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(reader.loadState, .loading)
        await fixture.emit(readerSnapshot("first pushed snapshot"))
        try await eventually { reader.loadState == .ready }
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("first pushed snapshot").items)
        reader.stop()
    }

    @MainActor
    func testSnapshotFirstStreamClosingBeforeSnapshotIsAnError() async throws {
        let fixture = ReaderFixture(readerSnapshot("unused"))
        let reader = TranscriptReader(provider: StreamingReaderProvider(fixture: fixture))
        await reader.start()
        try await eventually { await fixture.streamCalls == 1 }
        await fixture.finish()
        try await eventually { if case .failed = reader.loadState { return true }; return false }
        XCTAssertNil(reader.snapshot)
        reader.stop()
    }

    @MainActor
    func testStopFencesPendingManualRefresh() async throws {
        let fixture = ReaderFixture(readerSnapshot("cached"))
        let reader = TranscriptReader(provider: ReaderProvider(fixture: fixture))
        await reader.start()
        await fixture.blockSnapshots()
        await fixture.set(readerSnapshot("late", sequence: 2))
        let refresh = Task { await reader.refreshAndWait() }
        try await eventually { await fixture.snapshotCalls == 2 }
        reader.stop()
        await fixture.releaseSnapshots()
        await refresh.value
        XCTAssertEqual(reader.snapshot?.items, readerSnapshot("cached").items)
    }
}
