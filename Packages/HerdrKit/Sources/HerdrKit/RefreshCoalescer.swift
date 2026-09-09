import Foundation

/// Coalesces invalidations, never data. At most one refresh runs at a time;
/// invalidations received during that refresh produce one trailing refresh.
/// The start-to-start rate limit also applies under a continuous event burst.
public actor RefreshCoalescer {
    private let interval: Duration
    private let refresh: @Sendable () async -> Void
    private let clock = ContinuousClock()
    private var nextStart: ContinuousClock.Instant?
    private var dirty = false
    private var closed = false
    private var worker: Task<Void, Never>?

    public init(
        minimumInterval: Duration = .milliseconds(100),
        refresh: @escaping @Sendable () async -> Void
    ) {
        interval = max(.zero, minimumInterval)
        self.refresh = refresh
    }

    public func invalidate(immediate: Bool = false) {
        guard !closed else { return }
        dirty = true
        guard worker == nil else { return }
        if nextStart == nil { nextStart = clock.now + (immediate ? .zero : interval) }
        worker = Task { await self.run() }
    }

    public func waitUntilIdle() async {
        await worker?.value
    }

    public func cancel() {
        closed = true
        dirty = false
        worker?.cancel()
    }

    private func run() async {
        defer { worker = nil }
        while dirty, !closed, !Task.isCancelled {
            do {
                if let nextStart, nextStart > clock.now {
                    try await clock.sleep(until: nextStart)
                }
            } catch { return }
            guard !closed, !Task.isCancelled else { return }
            dirty = false
            nextStart = clock.now + interval
            await refresh()
        }
    }
}
