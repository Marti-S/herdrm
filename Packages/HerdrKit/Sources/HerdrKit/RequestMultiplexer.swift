import Foundation

/// Request/response correlation for one connection. This type never retries a
/// send: a missing acknowledgment does not mean a mutation was not executed.
public actor RequestMultiplexer<Response: Sendable> {
    public enum Failure: Error, Equatable {
        case closed
        case overloaded
        case duplicateID
        case timedOut
    }

    private struct Pending {
        let continuation: CheckedContinuation<Response, Error>
        let deadline: Task<Void, Never>
        var sending: Task<Void, Never>?
    }

    private let limit: Int
    private let timeout: Duration
    private var pending: [UUID: Pending] = [:]
    private var failure: (any Error)?

    public init(limit: Int = 32, timeout: Duration = .seconds(15)) {
        self.limit = max(1, limit)
        self.timeout = max(.milliseconds(1), timeout)
    }

    public var count: Int { pending.count }

    public func perform(
        id: UUID = UUID(),
        send: @escaping @Sendable () async throws -> Void
    ) async throws -> Response {
        try Task.checkCancellation()
        if let failure { throw failure }
        guard pending[id] == nil else { throw Failure.duplicateID }
        guard pending.count < limit else { throw Failure.overloaded }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let deadline = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.resolve(id: id, result: .failure(Failure.timedOut))
                }
                pending[id] = Pending(continuation: continuation, deadline: deadline, sending: nil)
                let sending = Task { [weak self] in
                    guard let self, await self.contains(id), !Task.isCancelled else { return }
                    do { try await send() }
                    catch { await self.resolve(id: id, result: .failure(error)) }
                }
                pending[id]?.sending = sending
            }
        } onCancel: {
            Task { await self.resolve(id: id, result: .failure(CancellationError())) }
        }
    }

    public func resolve(id: UUID, result: Result<Response, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        request.sending?.cancel()
        request.continuation.resume(with: result)
    }

    public func close(throwing error: any Error = Failure.closed) {
        guard failure == nil else { return }
        failure = error
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.deadline.cancel()
            request.sending?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func contains(_ id: UUID) -> Bool { pending[id] != nil }
}
