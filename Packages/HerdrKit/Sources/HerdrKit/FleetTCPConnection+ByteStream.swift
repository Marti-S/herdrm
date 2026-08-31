#if canImport(Network)
import Foundation

public extension FleetTCPConnection {
    /// Byte-stream spelling used by bridge protocol adapters.
    func read(maximumBytes: Int = 64 * 1024) async throws -> Data? {
        try await receive(maximumBytes: maximumBytes)
    }

    /// Byte-stream spelling used by bridge protocol adapters.
    func write(_ data: Data) async throws {
        try await send(data)
    }

    /// Async close spelling for stream protocols whose teardown is awaitable.
    func closeStream() async {
        close()
    }
}
#endif