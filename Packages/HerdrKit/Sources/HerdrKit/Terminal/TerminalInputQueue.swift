import Foundation

/// Serializes terminal-session input and transport-scoped semantic requests.
/// Session input is generation-scoped; semantic requests remain valid across
/// terminal restarts and report their delivery result to the enqueuer.
@MainActor
public final class TerminalInputQueue {
    public typealias TerminalSender = @MainActor @Sendable (Data) async throws -> Void
    public typealias Resizer = @MainActor @Sendable (TerminalSize) async throws -> Void
    public typealias SemanticSender = @MainActor @Sendable (String, JSONValue) async throws -> Void

    public struct SemanticTicket {
        private let completion: SemanticCompletion

        fileprivate init(completion: SemanticCompletion) {
            self.completion = completion
        }

        @MainActor
        public func value() async throws {
            try await completion.value()
        }
    }

    private enum Operation {
        case terminal(Data, generation: UInt64)
        case resize(TerminalSize, generation: UInt64)
        case semantic(method: String, params: JSONValue, completion: SemanticCompletion)
    }

    private let sendTerminal: TerminalSender
    private let resizeTerminal: Resizer
    private let sendSemantic: SemanticSender
    private var generation: UInt64
    private var operations: [Operation] = []
    private var drainTask: Task<Void, Never>?

    public init(
        generation: UInt64 = 0,
        sendTerminal: @escaping TerminalSender,
        resizeTerminal: @escaping Resizer,
        sendSemantic: @escaping SemanticSender
    ) {
        self.generation = generation
        self.sendTerminal = sendTerminal
        self.resizeTerminal = resizeTerminal
        self.sendSemantic = sendSemantic
    }

    public func updateGeneration(_ generation: UInt64) {
        self.generation = generation
    }

    public func enqueueTerminal(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        if case .terminal(let existing, let existingGeneration)? = operations.last,
           existingGeneration == generation {
            var combined = existing
            combined.append(data)
            operations[operations.count - 1] = .terminal(
                combined,
                generation: generation
            )
        } else {
            operations.append(.terminal(data, generation: generation))
        }
        startDrainIfNeeded()
    }

    public func enqueueResize(_ size: TerminalSize, generation: UInt64) {
        operations.append(.resize(size, generation: generation))
        startDrainIfNeeded()
    }

    public func submitSemantic(method: String, params: JSONValue) -> SemanticTicket {
        let completion = SemanticCompletion()
        operations.append(.semantic(
            method: method,
            params: params,
            completion: completion
        ))
        startDrainIfNeeded()
        return SemanticTicket(completion: completion)
    }

    public func enqueueSemantic(method: String, params: JSONValue) async throws {
        let ticket = submitSemantic(method: method, params: params)
        try await ticket.value()
    }

    var pendingOperationCount: Int { operations.count }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [self] in
            await drain()
        }
    }

    private func drain() async {
        while !operations.isEmpty {
            let operation = operations.removeFirst()
            switch operation {
            case .terminal(let data, let operationGeneration):
                guard operationGeneration == generation else { continue }
                try? await sendTerminal(data)

            case .resize(let size, let operationGeneration):
                guard operationGeneration == generation else { continue }
                try? await resizeTerminal(size)

            case .semantic(let method, let params, let completion):
                do {
                    try await sendSemantic(method, params)
                    completion.resolve(.success(()))
                } catch {
                    completion.resolve(.failure(error))
                }
            }
        }
        drainTask = nil
        if !operations.isEmpty {
            startDrainIfNeeded()
        }
    }
}

@MainActor
fileprivate final class SemanticCompletion {
    private enum State {
        case pending([CheckedContinuation<Void, any Error>])
        case resolved(Result<Void, any Error>)
    }

    private var state: State = .pending([])

    func value() async throws {
        switch state {
        case .resolved(let result):
            try result.get()
        case .pending:
            try await withCheckedThrowingContinuation { continuation in
                switch state {
                case .resolved(let result):
                    continuation.resume(with: result)
                case .pending(var continuations):
                    continuations.append(continuation)
                    state = .pending(continuations)
                }
            }
        }
    }

    func resolve(_ result: Result<Void, any Error>) {
        guard case .pending(let continuations) = state else { return }
        state = .resolved(result)
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }
}
