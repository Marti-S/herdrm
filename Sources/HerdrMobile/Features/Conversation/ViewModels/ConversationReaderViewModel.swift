import Foundation
import HerdrKit
import SwiftUI

/// Thrown when one transcript read outlives its deadline.
private struct TranscriptLoadTimeout: Error {}

@MainActor
final class ConversationReaderViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var snapshot: TranscriptSnapshot?
    @Published private(set) var hasNewOutput = false
    @Published private(set) var updateErrorMessage: String?
    @Published private(set) var isPinnedToLatest = true
    @Published private(set) var contentVersion: UInt64 = 0
    private let provider: any AgentTranscriptProvider
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var updateTask: Task<Void, Never>?
    private var pendingSnapshot: TranscriptSnapshot?
    /// Views currently showing this store. The store is cached per pane and a
    /// replacement screen's `.task` can start before the old screen's task is
    /// cancelled, so lifecycle is counted rather than toggled.
    private var viewerCount = 0

    init(provider: any AgentTranscriptProvider) {
        self.provider = provider
    }

    var items: [ConversationItem] { snapshot?.items ?? [] }
    var revision: UInt64 { snapshot?.sequence ?? 0 }
    var isTruncated: Bool { snapshot?.isTruncated ?? false }
    var source: TranscriptSource? { snapshot?.source }

    /// Keeps the transcript live for as long as the calling task runs. Bind
    /// it to the view with `.task { await store.run() }`; cancellation is the
    /// only detach signal.
    func run() async {
        attach()
        defer { detach() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func attach() {
        viewerCount += 1
        if viewerCount == 1 { beginLoading() }
    }

    private func detach() {
        viewerCount = max(0, viewerCount - 1)
        if viewerCount == 0 { cancelWork() }
    }

    private var isRunning: Bool { loadTask != nil || updateTask != nil }

    /// A single first read may queue behind other SSH work on the same
    /// connection (`SessionDriver` serializes operations FIFO and the wait is
    /// not cancellable), so an attempt is abandoned at this deadline and
    /// retried instead of spinning forever.
    static let loadAttemptTimeout: Duration = .seconds(6)
    private static let loadRetryDelay: Duration = .seconds(1)

    private func beginLoading() {
        guard !isRunning else { return }
        updateErrorMessage = nil
        if snapshot == nil {
            loadState = .loading
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            guard let self else { return }
            // Only clear the handle this task owns: a cancelled task can run
            // its cleanup after the next attempt has already been stored.
            defer { if loadGeneration == generation { loadTask = nil } }
            var attempt = 0
            while !Task.isCancelled, viewerCount > 0, loadGeneration == generation {
                attempt += 1
                do {
                    let initial = try await Self.withTimeout(Self.loadAttemptTimeout) {
                        try await self.provider.snapshot()
                    }
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    install(initial, force: true)
                    loadState = .ready
                    updateErrorMessage = nil
                    startUpdates(after: initial.sequence)
                    return
                } catch is CancellationError {
                    return
                } catch is TranscriptLoadTimeout {
                    // Keep the spinner and try again; the connection is busy,
                    // not broken.
                    guard !Task.isCancelled else { return }
                    if attempt >= 3 {
                        updateErrorMessage = String(localized: "Still loading — the connection is busy.")
                    }
                } catch {
                    guard !Task.isCancelled, loadGeneration == generation else { return }
                    loadState = .failed(Self.presentation(error))
                    return
                }
                do { try await Task.sleep(for: Self.loadRetryDelay) } catch { return }
            }
        }
    }

    /// Runs `operation` but stops waiting after `duration`. The abandoned work
    /// is cancelled; uncancellable native waits simply finish unobserved.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TranscriptLoadTimeout()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TranscriptLoadTimeout() }
            return result
        }
    }

    private func cancelWork() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        updateTask?.cancel()
        updateTask = nil
        if loadState == .loading, snapshot == nil {
            // Never leave a detached store looking busy; the next viewer
            // starts a fresh load.
            loadState = .idle
        }
    }

    func retry() {
        cancelWork()
        updateErrorMessage = nil
        if viewerCount > 0 { beginLoading() }
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let next = try await provider.snapshot()
                install(next, force: isPinnedToLatest)
                loadState = .ready
                updateErrorMessage = nil
            } catch {
                updateErrorMessage = Self.presentation(error)
            }
        }
    }

    func setPinnedToLatest(_ pinned: Bool) {
        isPinnedToLatest = pinned
        if pinned {
            resumeFollowing()
        }
    }

    func resumeFollowing() {
        isPinnedToLatest = true
        if let pendingSnapshot {
            snapshot = pendingSnapshot
            contentVersion &+= 1
            self.pendingSnapshot = nil
        }
        hasNewOutput = false
    }

    private static let updateRetryDelay: Duration = .seconds(3)

    /// Follows the provider stream and, if it ends or fails while a viewer is
    /// still attached, resumes from the last known sequence after a pause.
    private func startUpdates(after sequence: UInt64?) {
        updateTask?.cancel()
        let stream = provider.updates(after: sequence)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    guard !Task.isCancelled else { return }
                    receive(event)
                }
                guard !Task.isCancelled else { return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                updateErrorMessage = Self.presentation(error)
            }
            do {
                try await Task.sleep(for: Self.updateRetryDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, viewerCount > 0 else { return }
            startUpdates(after: revision)
        }
    }

    private func receive(_ event: TranscriptEvent) {
        let base = pendingSnapshot
            ?? snapshot
            ?? TranscriptSnapshot.empty(
                providerID: "pending",
                source: .semantic
            )
        install(base.applying(event), force: false)
    }

    private func install(_ next: TranscriptSnapshot, force: Bool) {
        if force || isPinnedToLatest || snapshot == nil {
            snapshot = next
            contentVersion &+= 1
            pendingSnapshot = nil
            hasNewOutput = false
        } else {
            pendingSnapshot = next
            hasNewOutput = next.sequence != snapshot?.sequence
                || next.items != snapshot?.items
                || next.isTruncated != snapshot?.isTruncated
        }
    }

    private static func presentation(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
