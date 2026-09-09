import Foundation

/// Coalesces terminal frames to display cadence while bounding queued bytes.
/// Individual UI deliveries are also bounded so a burst cannot become one
/// multi-megabyte main-actor terminal parse.
public actor TerminalOutputBatcher {
    public typealias Delivery = @MainActor @Sendable (Data) async -> Void

    private let maximumQueuedBytes: Int
    private let immediateDrainBytes: Int
    private let maximumDeliveryBytes: Int
    private let delivery: Delivery
    private var buffer = Data()
    private var drainTask: Task<Void, Never>?
    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var nextAdmission: UInt64 = 0
    private var servingAdmission: UInt64 = 0
    private var admissionWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var finishing = false
    private var closed = false

    public init(
        maximumQueuedBytes: Int = 2 * 1024 * 1024,
        immediateDrainBytes: Int = 128 * 1024,
        maximumDeliveryBytes: Int = 32 * 1024,
        delivery: @escaping Delivery
    ) {
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.immediateDrainBytes = max(1, min(immediateDrainBytes, maximumQueuedBytes))
        self.maximumDeliveryBytes = max(1, min(maximumDeliveryBytes, maximumQueuedBytes))
        self.delivery = delivery
    }

    public func append(_ data: Data) async {
        guard !data.isEmpty, !closed else { return }
        let admission = reserveAdmission()
        await waitForAdmission(admission)
        guard !closed, !finishing else {
            completeAdmission(admission)
            return
        }

        var offset = data.startIndex
        while offset < data.endIndex, !closed {
            while buffer.count >= maximumQueuedBytes, !closed {
                await withCheckedContinuation { continuation in
                    capacityWaiters.append(continuation)
                }
            }
            guard !closed else { break }
            let count = min(maximumQueuedBytes - buffer.count, data.endIndex - offset)
            buffer.append(data[offset..<(offset + count)])
            offset += count
            scheduleDrain(immediate: buffer.count >= immediateDrainBytes)
        }
        completeAdmission(admission)
    }

    public func finish() async {
        guard !closed else { return }
        let admission = reserveAdmission()
        await waitForAdmission(admission)
        guard !closed else {
            completeAdmission(admission)
            return
        }
        finishing = true
        if let drainTask { await drainTask.value }
        self.drainTask = nil
        while !closed, !buffer.isEmpty {
            await deliver(takeBufferedBytes())
            await Task.yield()
        }
        closed = true
        resumeCapacityWaiters()
        completeAdmission(admission)
    }

    public func cancel() {
        guard !closed else { return }
        finishing = true
        closed = true
        drainTask?.cancel()
        drainTask = nil
        buffer.removeAll(keepingCapacity: false)
        resumeCapacityWaiters()
        resumeAdmissionWaiters()
    }

    var queuedByteCount: Int { buffer.count }

    private func reserveAdmission() -> UInt64 {
        let admission = nextAdmission
        nextAdmission &+= 1
        return admission
    }

    private func waitForAdmission(_ admission: UInt64) async {
        guard admission != servingAdmission, !closed else { return }
        await withCheckedContinuation { continuation in
            admissionWaiters[admission] = continuation
        }
    }

    private func completeAdmission(_ admission: UInt64) {
        guard admission == servingAdmission else { return }
        servingAdmission &+= 1
        admissionWaiters.removeValue(forKey: servingAdmission)?.resume()
    }

    private func resumeAdmissionWaiters() {
        let waiters = admissionWaiters.values
        admissionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }
    }

    private func scheduleDrain(immediate: Bool) {
        guard drainTask == nil, !closed, !finishing else { return }
        drainTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(12)) }
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func drain() async {
        guard !closed else { drainTask = nil; return }
        let batch = takeBufferedBytes()
        if !batch.isEmpty { await deliver(batch) }
        await Task.yield()
        drainTask = nil
        if !buffer.isEmpty, !finishing {
            // Yield between bounded deliveries without imposing another timer
            // on an already queued burst.
            scheduleDrain(immediate: true)
        }
    }

    private func deliver(_ data: Data) async {
        let interval = PerformanceInterval("MobileTerminalDelivery")
        defer { interval.end(bytes: data.count) }
        await delivery(data)
    }

    private func takeBufferedBytes() -> Data {
        let count = min(buffer.count, maximumDeliveryBytes)
        let batch = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        if buffer.isEmpty { buffer = Data() }
        resumeCapacityWaiters()
        return batch
    }

    private func resumeCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }
}
