import Foundation

/// Produces complete reads from read-only terminal activity. Only invalidations
/// and complete snapshots are coalesced; terminal byte streams are never dropped.
public enum ObservedTranscript {
    public typealias Read = @Sendable () async throws -> TerminalReadResult
    public typealias Open = @Sendable () async throws -> any TerminalSession

    public static func reads(
        minimumInterval: Duration = .milliseconds(100),
        fallbackInterval: Duration = .milliseconds(900),
        open: @escaping Open,
        read: @escaping Read
    ) -> AsyncThrowingStream<TerminalReadResult, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let session: any TerminalSession
                do {
                    session = try await open()
                } catch {
                    if Task.isCancelled { continuation.finish(); return }
                    // Observation is optional on older daemons. A failed read
                    // still surfaces the real transport/authorization failure.
                    await poll(interval: fallbackInterval, read: read, into: continuation)
                    return
                }
                let coalescer = RefreshCoalescer(minimumInterval: minimumInterval) {
                    do {
                        let next = try await read()
                        guard !Task.isCancelled else { return }
                        continuation.yield(next)
                    } catch {
                        continuation.finish(throwing: error)
                        await session.close()
                    }
                }
                await withTaskCancellationHandler {
                    do {
                        // Subscribe before this read: no snapshot/subscription gap.
                        await coalescer.invalidate(immediate: true)
                        while !Task.isCancelled, let frame = try await session.read() {
                            if !frame.bytes.isEmpty { await coalescer.invalidate() }
                        }
                        await coalescer.waitUntilIdle()
                        continuation.finish()
                    } catch {
                        if Task.isCancelled { continuation.finish() }
                        else { continuation.finish(throwing: error) }
                    }
                    await coalescer.cancel()
                    await session.close()
                } onCancel: {
                    Task {
                        await coalescer.cancel()
                        await session.close()
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func polling(
        interval: Duration = .milliseconds(900),
        read: @escaping Read
    ) -> AsyncThrowingStream<TerminalReadResult, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { await poll(interval: interval, read: read, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func poll(
        interval: Duration,
        read: Read,
        into continuation: AsyncThrowingStream<TerminalReadResult, Error>.Continuation
    ) async {
        var previous: TerminalReadResult?
        var idlePolls = 0
        do {
            while !Task.isCancelled {
                let next = try await read()
                if previous != next {
                    previous = next
                    idlePolls = 0
                    continuation.yield(next)
                } else {
                    idlePolls = min(idlePolls + 1, 3)
                }
                // Preserve the compatibility cadence during output; reduce idle
                // network/battery use rather than polling older hosts faster.
                try await Task.sleep(for: max(.milliseconds(50), interval) * (1 + idlePolls))
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
