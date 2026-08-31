import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum FleetBridgeUnixError: Error, LocalizedError {
    case invalidPrivateDirectory(String)
    case invalidExistingSocket(String)
    case socketPathTooLong
    case systemCall(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateDirectory(let path):
            return "Fleet bridge directory is not private and owned by this user: \(path)"
        case .invalidExistingSocket(let path):
            return "Fleet bridge path exists but is not an owned Unix socket: \(path)"
        case .socketPathTooLong:
            return "Fleet bridge Unix socket path is too long."
        case .systemCall(let call, let reason):
            return "\(call): \(reason)"
        }
    }
}

/// Publishes the shared fleet host on a private per-user Unix socket.
///
/// The iOS bridge reaches this socket through an authenticated SSH
/// direct-streamlocal channel; the socket is never exposed as a local TCP port.
public actor FleetBridgeUnixServer {
    public nonisolated let socketPath: String

    private let host: FleetBridgeHost
    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var startInProgress = false
    private var stopRequested = false

    public init(
        host: FleetBridgeHost,
        socketPath: String = FleetBridgePath.unixSocketPath(userID: getuid())
    ) {
        self.host = host
        self.socketPath = socketPath
    }

    public func start() async throws {
        guard listenerFD < 0, !startInProgress else { return }
        startInProgress = true
        stopRequested = false
        let path = socketPath
        let fd: Int32
        do {
            fd = try await Task.detached(priority: .utility) {
                try Self.openListener(path: path)
            }.value
        } catch {
            startInProgress = false
            throw error
        }
        startInProgress = false
        guard !stopRequested, !Task.isCancelled else {
            systemShutdown(fd)
            systemClose(fd)
            try? Self.removeOwnedStaleSocket(path: path)
            throw CancellationError()
        }
        listenerFD = fd

        let host = host
        acceptTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let clientFD = systemAccept(fd)
                if clientFD >= 0 {
                    Self.protectFromSIGPIPE(clientFD)
                    await host.accept(POSIXFleetBridgeStream(fd: clientFD))
                    continue
                }
                if errno == EINTR { continue }
                if errno == EBADF || errno == EINVAL { return }
                return
            }
        }
    }

    public func stop() async {
        stopRequested = true
        let fd = listenerFD
        listenerFD = -1
        if fd >= 0 {
            systemShutdown(fd)
            systemClose(fd)
        }
        acceptTask?.cancel()
        _ = await acceptTask?.result
        acceptTask = nil
        await host.stop()
        try? Self.removeOwnedStaleSocket(path: socketPath)
    }

    private static func openListener(path: String) throws -> Int32 {
        try preparePrivateDirectory(for: path)
        try removeOwnedStaleSocket(path: path)

        let fd = socket(AF_UNIX, socketStreamType, 0)
        guard fd >= 0 else { throw systemError("socket()") }
        protectFromSIGPIPE(fd)

        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw FleetBridgeUnixError.socketPathTooLong
            }
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                raw.copyBytes(from: bytes)
            }

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    systemBind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw systemError("bind()") }
            guard chmod(path, 0o600) == 0 else { throw systemError("chmod(socket)") }
            guard listen(fd, 16) == 0 else { throw systemError("listen()") }
            return fd
        } catch {
            systemClose(fd)
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    private static func preparePrivateDirectory(for socketPath: String) throws {
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let attributes = try manager.attributesOfItem(atPath: directory.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        let type = attributes[.type] as? FileAttributeType
        guard owner == getuid(),
              type == .typeDirectory,
              let permissions,
              permissions & 0o077 == 0
        else {
            throw FleetBridgeUnixError.invalidPrivateDirectory(directory.path)
        }
        guard chmod(directory.path, 0o700) == 0 else {
            throw systemError("chmod(directory)")
        }
    }

    private static func removeOwnedStaleSocket(path: String) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return }
        let attributes = try manager.attributesOfItem(atPath: path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let type = attributes[.type] as? FileAttributeType
        guard owner == getuid(), type == .typeSocket else {
            throw FleetBridgeUnixError.invalidExistingSocket(path)
        }
        try manager.removeItem(atPath: path)
    }

    private static func protectFromSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        )
        #endif
    }

    private static func systemError(_ call: String) -> FleetBridgeUnixError {
        FleetBridgeUnixError.systemCall(call, String(cString: strerror(errno)))
    }
}

/// Blocking POSIX I/O is isolated on detached tasks. Each operation duplicates
/// the socket descriptor under the state lock. That prevents a concurrent close
/// followed by descriptor reuse from redirecting an in-flight read or write to
/// an unrelated file descriptor.
private final class POSIXFleetBridgeStream: FleetBridgeByteStream, @unchecked Sendable {
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32

    init(fd: Int32) {
        self.fd = fd
    }

    func read(maximumBytes: Int) async throws -> Data? {
        let operationFD = try duplicateFD()
        guard operationFD >= 0 else { return nil }
        let count = max(1, maximumBytes)
        return try await Task.detached(priority: .utility) {
            defer { systemClose(operationFD) }
            var bytes = [UInt8](repeating: 0, count: count)
            while true {
                let result = systemRead(operationFD, &bytes, bytes.count)
                if result > 0 { return Data(bytes.prefix(result)) }
                if result == 0 { return nil }
                if errno == EINTR { continue }
                if errno == EBADF || errno == ECONNRESET { return nil }
                throw FleetBridgeUnixError.systemCall(
                    "read()",
                    String(cString: strerror(errno))
                )
            }
        }.value
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let operationFD = try duplicateFD()
        guard operationFD >= 0 else { throw FleetBridgeHostError.streamClosed }
        try await Task.detached(priority: .utility) { [writeLock] in
            defer { systemClose(operationFD) }
            try writeLock.withLock {
                var offset = 0
                while offset < data.count {
                    let written = data.withUnsafeBytes { raw -> Int in
                        guard let base = raw.baseAddress else { return 0 }
                        return systemWrite(
                            operationFD,
                            base.advanced(by: offset),
                            raw.count - offset
                        )
                    }
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written < 0, errno == EINTR { continue }
                    throw FleetBridgeUnixError.systemCall(
                        "write()",
                        String(cString: strerror(errno))
                    )
                }
            }
        }.value
    }

    func close() async {
        let oldFD = stateLock.withLock {
            let value = fd
            fd = -1
            return value
        }
        guard oldFD >= 0 else { return }
        systemShutdown(oldFD)
        systemClose(oldFD)
    }

    private func duplicateFD() throws -> Int32 {
        try stateLock.withLock {
            guard fd >= 0 else { return -1 }
            let duplicate = dup(fd)
            guard duplicate >= 0 else {
                throw FleetBridgeUnixError.systemCall(
                    "dup()",
                    String(cString: strerror(errno))
                )
            }
            return duplicate
        }
    }
}

#if os(Linux)
private let socketStreamType = Int32(SOCK_STREAM.rawValue)
#else
private let socketStreamType = SOCK_STREAM
#endif

private func systemAccept(_ fd: Int32) -> Int32 {
    accept(fd, nil, nil)
}

private func systemBind(
    _ fd: Int32,
    _ address: UnsafePointer<sockaddr>,
    _ length: socklen_t
) -> Int32 {
    bind(fd, address, length)
}

private func systemRead(
    _ fd: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
    read(fd, buffer, count)
}

private func systemWrite(
    _ fd: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    write(fd, buffer, count)
}

private func systemShutdown(_ fd: Int32) {
    #if os(Linux)
    _ = shutdown(fd, Int32(SHUT_RDWR))
    #else
    _ = shutdown(fd, SHUT_RDWR)
    #endif
}

private func systemClose(_ fd: Int32) {
    _ = close(fd)
}
