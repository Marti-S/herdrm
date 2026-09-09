import Foundation

/// Providers whose update stream begins with an authoritative snapshot can
/// bootstrap the reader without a separate, duplicate snapshot RPC.
public protocol SnapshotFirstTranscriptProvider: AgentTranscriptProvider {}

/// UI-independent reader state. Cached content survives transport replacement,
/// but each load, manual refresh, and stream is fenced by a binding generation.
@MainActor
open class TranscriptReader {
    public enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var snapshot: TranscriptSnapshot?
    public private(set) var hasNewOutput = false
    public private(set) var updateErrorMessage: String?
    public private(set) var isPinnedToLatest = true
    public private(set) var contentVersion: UInt64 = 0
    public private(set) var bindingID: UUID

    private var provider: any AgentTranscriptProvider
    private var loadTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingSnapshot: TranscriptSnapshot?
    private var generation: UInt64 = 0
    private var receivedUpdates: UInt64 = 0
    private var started = false
    private var suspended = false

    public init(provider: any AgentTranscriptProvider, bindingID: UUID = UUID()) {
        self.provider = provider
        self.bindingID = bindingID
    }

    /// Called before a visible mutation. Apple UI adapters can publish here.
    open func willChange() {}

    public var items: [ConversationItem] { snapshot?.items ?? [] }
    public var revision: UInt64 { snapshot?.sequence ?? 0 }
    public var isTruncated: Bool { snapshot?.isTruncated ?? false }
    public var source: TranscriptSource? { snapshot?.source }

    public func start() async {
        if started {
            await loadTask?.value
            return
        }
        started = true
        guard !suspended else { return }
        launchLoad()
        await loadTask?.value
    }

    public func stop() {
        started = false
        cancelWork()
    }

    public func suspend() {
        guard !suspended else { return }
        suspended = true
        cancelWork()
    }

    public func resume() {
        guard suspended else { return }
        suspended = false
        if started { launchLoad() }
    }

    public func rebind(provider: any AgentTranscriptProvider, bindingID: UUID) {
        guard bindingID != self.bindingID else { return }
        cancelWork()
        self.provider = provider
        self.bindingID = bindingID
        if started, !suspended { launchLoad() }
    }

    public func retry() {
        stop()
        Task { await start() }
    }

    public func refresh() {
        guard !suspended, refreshTask == nil else { return }
        let expected = generation
        let expectedUpdates = receivedUpdates
        let provider = provider
        refreshTask = Task { [weak self] in
            defer {
                if self?.generation == expected { self?.refreshTask = nil }
            }
            do {
                let next = try await provider.snapshot()
                guard let self, self.isCurrent(expected),
                      self.receivedUpdates == expectedUpdates else { return }
                self.install(next, force: false)
                self.willChange()
                self.loadState = .ready
                self.updateErrorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent(expected) else { return }
                self.willChange()
                self.updateErrorMessage = error.localizedDescription
            }
        }
    }

    public func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    public func setPinnedToLatest(_ pinned: Bool) {
        if pinned {
            resumeFollowing()
        } else if isPinnedToLatest {
            willChange()
            isPinnedToLatest = false
        }
    }

    public func resumeFollowing() {
        guard !isPinnedToLatest || pendingSnapshot != nil || hasNewOutput else { return }
        willChange()
        isPinnedToLatest = true
        if let pendingSnapshot {
            if !sameContent(snapshot, pendingSnapshot) { contentVersion &+= 1 }
            snapshot = pendingSnapshot
            self.pendingSnapshot = nil
        }
        hasNewOutput = false
    }

    private func cancelWork() {
        generation &+= 1
        loadTask?.cancel()
        updateTask?.cancel()
        refreshTask?.cancel()
        loadTask = nil
        updateTask = nil
        refreshTask = nil
    }

    private func isCurrent(_ expected: UInt64) -> Bool {
        generation == expected && !suspended && !Task.isCancelled
    }

    private func launchLoad() {
        guard loadTask == nil else { return }
        generation &+= 1
        let expected = generation
        let provider = provider
        willChange()
        updateErrorMessage = nil
        if snapshot == nil { loadState = .loading }
        if provider is any SnapshotFirstTranscriptProvider {
            startUpdates(provider: provider, after: nil, generation: expected, needsInitialSnapshot: true)
            return
        }
        loadTask = Task { [weak self] in
            defer {
                if self?.generation == expected { self?.loadTask = nil }
            }
            do {
                let initial = try await provider.snapshot()
                guard let self, self.started, self.isCurrent(expected) else { return }
                self.install(initial, force: self.snapshot == nil)
                self.willChange()
                self.loadState = .ready
                self.startUpdates(provider: provider, after: initial.sequence, generation: expected)
            } catch is CancellationError {
                guard let self, self.isCurrent(expected) else { return }
                self.willChange()
                self.started = false
                self.loadState = self.snapshot == nil ? .idle : .ready
            } catch {
                guard let self, self.started, self.isCurrent(expected) else { return }
                self.willChange()
                self.started = false
                if self.snapshot == nil {
                    self.loadState = .failed(error.localizedDescription)
                } else {
                    self.loadState = .ready
                    self.updateErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startUpdates(
        provider: any AgentTranscriptProvider,
        after sequence: UInt64?,
        generation expected: UInt64,
        needsInitialSnapshot: Bool = false
    ) {
        let stream = provider.updates(after: sequence)
        updateTask = Task { [weak self] in
            var awaitingInitial = needsInitialSnapshot
            do {
                for try await event in stream {
                    guard let self, self.started, self.isCurrent(expected) else { return }
                    if awaitingInitial {
                        guard case .snapshot = event else { throw TerminalTranscriptUpdateError.missingSnapshot }
                        awaitingInitial = false
                        self.willChange()
                        self.loadState = .ready
                        self.updateErrorMessage = nil
                    }
                    self.receivedUpdates &+= 1
                    let base = self.pendingSnapshot ?? self.snapshot
                        ?? .empty(providerID: "pending")
                    self.install(base.applying(event), force: false)
                }
                if needsInitialSnapshot, !Task.isCancelled { throw TerminalSessionError.closed }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.started, self.isCurrent(expected) else { return }
                self.willChange()
                if self.snapshot == nil {
                    self.started = false
                    self.loadState = .failed(error.localizedDescription)
                } else {
                    self.updateErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func install(_ next: TranscriptSnapshot, force: Bool) {
        if force || isPinnedToLatest || snapshot == nil {
            let changed = !sameContent(snapshot, next)
            if changed || hasNewOutput { willChange() }
            snapshot = next
            if changed { contentVersion &+= 1 }
            pendingSnapshot = nil
            hasNewOutput = false
        } else {
            let changed = !sameContent(snapshot, next)
            if changed != hasNewOutput { willChange() }
            pendingSnapshot = changed ? next : nil
            if !changed { snapshot = next }
            hasNewOutput = changed
        }
    }

    private func sameContent(_ lhs: TranscriptSnapshot?, _ rhs: TranscriptSnapshot) -> Bool {
        guard let lhs else { return false }
        return lhs.providerID == rhs.providerID && lhs.source == rhs.source
            && lhs.items == rhs.items && lhs.isTruncated == rhs.isTruncated
    }
}
