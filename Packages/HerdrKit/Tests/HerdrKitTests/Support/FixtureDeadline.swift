import Foundation
import XCTest

struct FixtureTimeout: Error, CustomStringConvertible {
    let message: String
    let file: StaticString
    let line: UInt
    var description: String { "Timed out: \(message) at \(file):\(line)" }
}

@MainActor
func waitForFixture(
    _ message: String,
    timeout: Duration = .seconds(3),
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw FixtureTimeout(message: message, file: file, line: line)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// A task-group timeout still joins its cancelled children and can hang. Observe
/// an unstructured task instead, and never join it during cancellation/teardown.
@MainActor
final class FixtureTask<Value> {
    private var result: Result<Value, Error>?
    private var task: Task<Void, Never>?
    private let name: String

    init(_ name: String, operation: @escaping @MainActor () async throws -> Value) {
        self.name = name
        task = Task { [weak self] in
            do {
                let value = try await operation()
                self?.result = .success(value)
            } catch {
                self?.result = .failure(error)
            }
        }
    }

    func cancel() { task?.cancel() }

    func value(
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Value {
        do {
            try await waitForFixture(name, timeout: timeout, file: file, line: line) { result != nil }
        } catch {
            cancel()
            throw error
        }
        return try result!.get()
    }
}

/// Cancellation-insensitive like the transport/delivery under test. A deadline
/// fails and releases the gate; teardown releases it synchronously even if the
/// producer never started. Release-before-wait and repeated release are safe.
@MainActor
final class FixtureGate {
    private var shouldWait = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var deadline: Task<Void, Never>?
    private let name: String
    private let timeout: Duration

    init(_ name: String, timeout: Duration = .seconds(3)) {
        self.name = name
        self.timeout = timeout
    }

    func waitOnFirstCall(file: StaticString = #filePath, line: UInt = #line) async {
        guard shouldWait else { return }
        shouldWait = false
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            deadline = Task { [weak self, timeout] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, self.continuation != nil else { return }
                XCTFail("Unreleased fixture: \(self.name)", file: file, line: line)
                self.release()
            }
        }
    }

    func release() {
        shouldWait = false
        deadline?.cancel()
        deadline = nil
        continuation?.resume()
        continuation = nil
    }
}

extension XCTestCase {
    @MainActor
    func fixtureGate(_ name: String) -> FixtureGate {
        let gate = FixtureGate(name)
        addTeardownBlock { @MainActor in gate.release() }
        return gate
    }

    @MainActor
    func fixtureTask<Value>(
        _ name: String,
        operation: @escaping @MainActor () async throws -> Value
    ) -> FixtureTask<Value> {
        let task = FixtureTask(name, operation: operation)
        addTeardownBlock { @MainActor in task.cancel() }
        return task
    }

    @MainActor
    func withFixtureDeadline<Value>(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try await fixtureTask(name, operation: operation).value(file: file, line: line)
    }
}
