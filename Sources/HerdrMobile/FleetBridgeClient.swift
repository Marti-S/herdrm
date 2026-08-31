import Foundation
import HerdrKit
import Network

private final class FleetBridgeStartGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?

  init(_ continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func succeed() {
    resume(.success(()))
  }

  func fail(_ error: any Error) {
    resume(.failure(error))
  }

  private func resume(_ result: Result<Void, Error>) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}

enum FleetBridgeClientError: LocalizedError {
  case invalidEndpoint
  case connectionFailed(String)
  case connectionClosed
  case timedOut
  case missingToken
  case protocolMismatch(Int)
  case serverIdentityChanged(expected: UUID, received: UUID)
  case unexpectedRecord(String)
  case server(code: String, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return String(localized: "The Mac bridge address or port is invalid.")
    case .connectionFailed(let detail):
      return String(localized: "Could not connect to the Mac bridge: \(detail)")
    case .connectionClosed:
      return String(localized: "The Mac bridge closed the connection.")
    case .timedOut:
      return String(localized: "The Mac bridge did not respond in time.")
    case .missingToken:
      return String(localized: "No pairing token is saved for this Mac.")
    case .protocolMismatch(let version):
      return String(
        localized:
          "The Mac uses bridge protocol \(version), but this app supports \(FleetBridgeProtocol.version)."
      )
    case .serverIdentityChanged(let expected, let received):
      return String(
        localized:
          "The Mac identity changed from \(expected.uuidString) to \(received.uuidString). Remove and pair it again."
      )
    case .unexpectedRecord(let type):
      return String(localized: "The Mac bridge sent an unexpected \(type) record.")
    case .server(_, let message):
      return message
    }
  }

  var isPermanent: Bool {
    switch self {
    case .invalidEndpoint, .missingToken, .protocolMismatch, .serverIdentityChanged:
      return true
    case .server(let code, _):
      return ["authentication_failed", "protocol_mismatch"].contains(code)
    case .connectionFailed, .connectionClosed, .timedOut, .unexpectedRecord:
      return false
    }
  }
}

/// One authenticated TCP connection. The bridge protocol assigns exactly one
/// operation to each connection after the hello/welcome exchange.
private actor FleetBridgeChannel {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private var decoder = FleetBridgeRecordDecoder()
  private var queuedRecords: [FleetBridgeServerRecord] = []
  private var started = false
  private var closed = false

  init(host: String, port: UInt16) throws {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let endpointPort = NWEndpoint.Port(rawValue: port)
    else { throw FleetBridgeClientError.invalidEndpoint }
    connection = NWConnection(
      host: NWEndpoint.Host(trimmed),
      port: endpointPort,
      using: .tcp
    )
    queue = DispatchQueue(label: "dev.bybee.herdrm.ios.fleet-bridge.\(UUID().uuidString)")
  }

  func start() async throws {
    guard !started else { return }
    guard !closed else { throw FleetBridgeClientError.connectionClosed }
    started = true
    let connection = connection
    let queue = queue
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let gate = FleetBridgeStartGate(continuation)
        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            gate.succeed()
          case .failed(let error):
            gate.fail(FleetBridgeClientError.connectionFailed(error.localizedDescription))
          case .cancelled:
            gate.fail(FleetBridgeClientError.connectionClosed)
          default:
            break
          }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) {
          gate.fail(FleetBridgeClientError.timedOut)
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }

  func send(_ record: FleetBridgeClientRecord) async throws {
    guard started, !closed else { throw FleetBridgeClientError.connectionClosed }
    let data = try FleetBridgeWire.encodeClient(record)
    let connection = connection
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.send(
          content: data,
          completion: .contentProcessed { error in
            if let error {
              continuation.resume(
                throwing: FleetBridgeClientError.connectionFailed(
                  error.localizedDescription
                )
              )
            } else {
              continuation.resume()
            }
          })
      }
    } onCancel: {
      connection.cancel()
    }
  }

  func receive() async throws -> FleetBridgeServerRecord? {
    if !queuedRecords.isEmpty {
      return queuedRecords.removeFirst()
    }
    guard started, !closed else { return nil }

    while true {
      guard let chunk = try await receiveChunk() else {
        closed = true
        return nil
      }
      if chunk.isEmpty { continue }
      try decoder.append(chunk)
      while let line = try decoder.nextRecordData() {
        queuedRecords.append(try FleetBridgeWire.decodeServer(line))
      }
      if !queuedRecords.isEmpty {
        return queuedRecords.removeFirst()
      }
    }
  }

  func close() {
    guard !closed else { return }
    closed = true
    connection.cancel()
    queuedRecords.removeAll()
  }

  private func receiveChunk() async throws -> Data? {
    let connection = connection
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data?, Error>) in
        connection.receive(
          minimumIncompleteLength: 1,
          maximumLength: 64 * 1024
        ) { data, _, isComplete, error in
          if let error {
            continuation.resume(
              throwing: FleetBridgeClientError.connectionFailed(
                error.localizedDescription
              )
            )
          } else if let data, !data.isEmpty {
            continuation.resume(returning: data)
          } else if isComplete {
            continuation.resume(returning: nil)
          } else {
            continuation.resume(returning: Data())
          }
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }
}

struct FleetBridgeClient: Sendable {
  let bridge: MobileBridge
  let token: String
  let clientID: UUID
  let clientName: String

  func snapshot() async throws -> FleetSnapshot {
    let (channel, _) = try await authenticatedChannel()
    do {
      let request = FleetBridgeSnapshotRequest()
      try await channel.send(.snapshot(request))
      while let record = try await channel.receive() {
        switch record {
        case .snapshot(let response) where response.requestID == request.id:
          await channel.close()
          return response.snapshot
        case .error(let error):
          throw Self.serverError(error)
        default:
          continue
        }
      }
      throw FleetBridgeClientError.connectionClosed
    } catch {
      await channel.close()
      throw error
    }
  }

  func snapshots(
    after revision: UInt64?
  ) -> AsyncThrowingStream<FleetSnapshot, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        var channel: FleetBridgeChannel?
        do {
          let opened = try await authenticatedChannel()
          channel = opened.channel
          let request = FleetBridgeSubscribeRequest(afterRevision: revision)
          try await opened.channel.send(.subscribe(request))
          while !Task.isCancelled,
            let record = try await opened.channel.receive()
          {
            switch record {
            case .snapshot(let response) where response.requestID == request.id:
              continuation.yield(response.snapshot)
            case .error(let error):
              throw Self.serverError(error)
            default:
              continue
            }
          }
          if !Task.isCancelled {
            throw FleetBridgeClientError.connectionClosed
          }
          continuation.finish()
        } catch {
          if Task.isCancelled {
            continuation.finish()
          } else {
            continuation.finish(throwing: error)
          }
        }
        if let channel { await channel.close() }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func request(
    deviceID: UUID,
    method: String,
    params: JSONValue
  ) async throws -> JSONValue {
    let (channel, _) = try await authenticatedChannel()
    do {
      let request = FleetBridgeRPCRequest(
        deviceID: deviceID,
        method: method,
        params: params
      )
      try await channel.send(.rpc(request))
      while let record = try await channel.receive() {
        switch record {
        case .rpc(let response) where response.id == request.id:
          await channel.close()
          return response.result
        case .error(let error):
          throw Self.serverError(error)
        default:
          continue
        }
      }
      throw FleetBridgeClientError.connectionClosed
    } catch {
      await channel.close()
      throw error
    }
  }

  func openTerminalSession(
    deviceID: UUID,
    target: TerminalAttachTarget,
    mode: TerminalSessionMode,
    size: TerminalSize
  ) async throws -> any TerminalSession {
    guard size.isValid else { throw TerminalSessionError.invalidSize }
    let (channel, _) = try await authenticatedChannel()
    do {
      let request = FleetBridgeTerminalOpenRequest(
        deviceID: deviceID,
        target: FleetTerminalTarget(target),
        mode: mode,
        size: size
      )
      try await channel.send(.terminalOpen(request))
      return FleetBridgeTerminalSession(
        channel: channel,
        streamID: request.streamID,
        mode: mode,
        initialSize: size
      )
    } catch {
      await channel.close()
      throw error
    }
  }

  private func authenticatedChannel() async throws -> (
    channel: FleetBridgeChannel,
    welcome: FleetBridgeWelcome
  ) {
    guard !token.isEmpty else { throw FleetBridgeClientError.missingToken }
    let channel = try FleetBridgeChannel(host: bridge.host, port: bridge.port)
    do {
      try await channel.start()
      try await channel.send(
        .hello(
          FleetBridgeHello(
            token: token,
            clientID: clientID,
            clientName: clientName
          )))
      guard let record = try await channel.receive() else {
        throw FleetBridgeClientError.connectionClosed
      }
      switch record {
      case .welcome(let welcome):
        guard welcome.protocolVersion == FleetBridgeProtocol.version else {
          throw FleetBridgeClientError.protocolMismatch(welcome.protocolVersion)
        }
        if let expected = bridge.expectedServerID,
          welcome.serverID != expected
        {
          throw FleetBridgeClientError.serverIdentityChanged(
            expected: expected,
            received: welcome.serverID
          )
        }
        return (channel, welcome)
      case .error(let error):
        throw Self.serverError(error)
      default:
        throw FleetBridgeClientError.unexpectedRecord("handshake")
      }
    } catch {
      await channel.close()
      throw error
    }
  }

  private static func serverError(_ error: FleetBridgeErrorRecord) -> FleetBridgeClientError {
    .server(code: error.code, message: error.message)
  }
}

private actor FleetBridgeTerminalSession: TerminalSession {
  nonisolated let mode: TerminalSessionMode

  private let channel: FleetBridgeChannel
  private let streamID: UUID
  private var size: TerminalSize
  private var closed = false

  init(
    channel: FleetBridgeChannel,
    streamID: UUID,
    mode: TerminalSessionMode,
    initialSize: TerminalSize
  ) {
    self.channel = channel
    self.streamID = streamID
    self.mode = mode
    self.size = initialSize
  }

  func read() async throws -> TerminalFrame? {
    guard !closed else { return nil }
    while let record = try await channel.receive() {
      switch record {
      case .terminalFrame(let value) where value.streamID == streamID:
        return value.frame
      case .terminalClosed(let value) where value.streamID == streamID:
        closed = true
        await channel.close()
        return nil
      case .error(let error)
      where error.streamID == nil || error.streamID == streamID:
        closed = true
        await channel.close()
        throw FleetBridgeClientError.server(
          code: error.code,
          message: error.message
        )
      default:
        continue
      }
    }
    closed = true
    throw FleetBridgeClientError.connectionClosed
  }

  func send(_ data: Data) async throws {
    guard !closed else { throw TerminalSessionError.closed }
    guard mode.allowsInput else { throw TerminalSessionError.readOnly }
    guard !data.isEmpty else { return }
    try await channel.send(
      .terminalInput(
        FleetBridgeTerminalInput(
          streamID: streamID,
          bytes: data
        )))
  }

  func resize(_ size: TerminalSize) async throws {
    guard !closed else { throw TerminalSessionError.closed }
    guard mode.allowsResize else { throw TerminalSessionError.readOnly }
    guard size.isValid else { throw TerminalSessionError.invalidSize }
    guard size != self.size else { return }
    try await channel.send(
      .terminalResize(
        FleetBridgeTerminalResize(
          streamID: streamID,
          size: size
        )))
    self.size = size
  }

  func close() async {
    guard !closed else { return }
    closed = true
    if mode.access == .control {
      try? await channel.send(
        .terminalRelease(
          FleetBridgeTerminalRelease(
            streamID: streamID
          )))
    }
    await channel.close()
  }
}

/// A device-scoped view of one Mac bridge. The bridge connection itself is
/// opened per operation, matching the host's one-operation-per-connection wire.
struct FleetBridgeDeviceTransport: MobileTransport {
  let client: FleetBridgeClient
  let deviceID: UUID

  func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await client.request(deviceID: deviceID, method: method, params: params)
  }

  /// Fleet changes are owned by the bridge session's one shared subscription.
  /// Returning an empty stream prevents every device view from opening a
  /// duplicate fleet subscription.
  func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
    AsyncThrowingStream { continuation in continuation.finish() }
  }

  func openTerminalSession(
    target: TerminalAttachTarget,
    mode: TerminalSessionMode,
    size: TerminalSize
  ) async throws -> any TerminalSession {
    try await client.openTerminalSession(
      deviceID: deviceID,
      target: target,
      mode: mode,
      size: size
    )
  }

  func close() async {}
}
