import Foundation

/// One ordered writer with explicit memory/admission bounds. Cancelling a
/// queued write removes it; cancelling an in-flight write does not retract
/// bytes already handed to the transport. Callers must not replay mutations.
public actor BoundedAsyncWriter {
    public enum Failure: Error, Equatable {
        case closed
        case overloaded
    }

    private struct Entry {
        let id: UUID
        let data: Data
        var continuation: CheckedContinuation<Void, Error>?
    }

    private let maximumBytes: Int
    private let maximumMessages: Int
    private let write: @Sendable (Data) async throws -> Void
    private var pending: [Entry] = []
    private var inFlight: Entry?
    private var worker: Task<Void, Never>?
    private var failure: (any Error)?
    public private(set) var queuedByteCount = 0

    public init(
        maximumBytes: Int = 64 * 1024 * 1024,
        maximumMessages: Int = 128,
        write: @escaping @Sendable (Data) async throws -> Void
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumMessages = max(1, maximumMessages)
        self.write = write
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard !data.isEmpty else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard data.count <= maximumBytes - queuedByteCount,
                      pending.count + (inFlight == nil ? 0 : 1) < maximumMessages
                else {
                    continuation.resume(throwing: Failure.overloaded)
                    return
                }
                queuedByteCount += data.count
                pending.append(Entry(id: id, data: data, continuation: continuation))
                if worker == nil {
                    worker = Task { await self.drain() }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    public func close(throwing error: any Error = Failure.closed) {
        guard failure == nil else { return }
        failure = error
        worker?.cancel()
        worker = nil
        inFlight?.continuation?.resume(throwing: error)
        inFlight = nil
        for entry in pending { entry.continuation?.resume(throwing: error) }
        pending.removeAll()
        queuedByteCount = 0
    }

    private func cancel(_ id: UUID) {
        if inFlight?.id == id {
            inFlight?.continuation?.resume(throwing: CancellationError())
            inFlight?.continuation = nil
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            let entry = pending.remove(at: index)
            queuedByteCount -= entry.data.count
            entry.continuation?.resume(throwing: CancellationError())
        }
    }

    private func drain() async {
        defer { worker = nil }
        while failure == nil, !pending.isEmpty {
            let entry = pending.removeFirst()
            inFlight = entry
            do {
                try await write(entry.data)
                guard failure == nil else { return }
                queuedByteCount -= entry.data.count
                inFlight?.continuation?.resume()
                inFlight = nil
            } catch {
                close(throwing: error)
                return
            }
        }
    }
}
