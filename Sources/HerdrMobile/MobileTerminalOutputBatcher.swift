import Foundation

/// Coalesces terminal frames to display cadence while bounding queued bytes.
/// The receive loop only waits when rendering falls more than the configured
/// memory bound behind, so normal bursts stay off the main actor.
actor MobileTerminalOutputBatcher {
  typealias Delivery = @MainActor @Sendable (Data) -> Void

  private let maximumQueuedBytes: Int
  private let immediateDrainBytes: Int
  private let delivery: Delivery
  private var buffer = Data()
  private var drainTask: Task<Void, Never>?
  private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishing = false
  private var closed = false

  init(
    maximumQueuedBytes: Int = 2 * 1024 * 1024,
    immediateDrainBytes: Int = 128 * 1024,
    delivery: @escaping Delivery
  ) {
    self.maximumQueuedBytes = max(1, maximumQueuedBytes)
    self.immediateDrainBytes = max(1, min(immediateDrainBytes, maximumQueuedBytes))
    self.delivery = delivery
  }

  func append(_ data: Data) async {
    guard !data.isEmpty, !closed, !finishing else { return }
    var offset = 0
    while offset < data.count, !closed, !finishing {
      while buffer.count >= maximumQueuedBytes, !closed, !finishing {
        await withCheckedContinuation { continuation in
          capacityWaiters.append(continuation)
        }
      }
      guard !closed, !finishing else { return }

      let count = min(maximumQueuedBytes - buffer.count, data.count - offset)
      buffer.append(data[offset..<(offset + count)])
      offset += count
      scheduleDrain(immediate: buffer.count >= immediateDrainBytes)
    }
  }

  func finish() async {
    guard !closed else { return }
    finishing = true
    if let drainTask {
      await drainTask.value
    }
    self.drainTask = nil
    let finalBatch = takeBufferedBytes()
    if !finalBatch.isEmpty {
      await delivery(finalBatch)
    }
    closed = true
    resumeCapacityWaiters()
  }

  func cancel() {
    guard !closed else { return }
    finishing = true
    closed = true
    drainTask?.cancel()
    drainTask = nil
    buffer.removeAll(keepingCapacity: false)
    resumeCapacityWaiters()
  }

  private func scheduleDrain(immediate: Bool) {
    guard drainTask == nil, !closed, !finishing else { return }
    drainTask = Task { [weak self] in
      if !immediate {
        try? await Task.sleep(for: .milliseconds(12))
      }
      guard !Task.isCancelled else { return }
      await self?.drain()
    }
  }

  private func drain() async {
    guard !closed else {
      drainTask = nil
      return
    }
    let batch = takeBufferedBytes()
    if !batch.isEmpty {
      await delivery(batch)
    }
    drainTask = nil
    if !buffer.isEmpty, !finishing {
      scheduleDrain(immediate: buffer.count >= immediateDrainBytes)
    }
  }

  private func takeBufferedBytes() -> Data {
    let batch = buffer
    buffer.removeAll(keepingCapacity: true)
    resumeCapacityWaiters()
    return batch
  }

  private func resumeCapacityWaiters() {
    let waiters = capacityWaiters
    capacityWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters {
      waiter.resume()
    }
  }
}
