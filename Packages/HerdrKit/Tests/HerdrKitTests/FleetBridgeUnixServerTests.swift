import Foundation
@testable import HerdrKit
import XCTest

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class FleetBridgeUnixServerTests: XCTestCase {
    func testServesHandshakeAndPingOnPrivateSocket() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let snapshot = FleetSnapshot(revision: 1, devices: [])
        let host = FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe],
            initialSnapshot: snapshot,
            requestHandler: { .success(id: $0.id) }
        )
        let server = FleetBridgeUnixServer(host: host, socketPath: fixture.socketPath)
        try await server.start()

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.directory.path
        )
        XCTAssertEqual(
            (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        let socketAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.socketPath
        )
        XCTAssertEqual(socketAttributes[.type] as? FileAttributeType, .typeSocket)
        XCTAssertEqual(
            (socketAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )

        let client = try POSIXTestClient(path: fixture.socketPath)
        defer { client.close() }
        try client.write(
            FleetWireCodec.encode(
                .hello(
                    FleetClientHello(clientID: UUID(), clientName: "Phone")
                )
            )
        )
        guard case .welcome(let welcome) = try client.readMessage() else {
            return XCTFail("expected welcome")
        }
        XCTAssertEqual(welcome.bridgeName, "Studio")
        XCTAssertEqual(welcome.snapshot, snapshot)

        try client.write(FleetWireCodec.encode(.ping))
        XCTAssertEqual(try client.readMessage(), .pong)

        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socketPath))
    }

    func testDoesNotDeleteRegularFileAtSocketPath() async throws {
        let fixture = try Fixture(createDirectory: true)
        defer { fixture.cleanup() }
        try Data("do not delete".utf8).write(to: URL(fileURLWithPath: fixture.socketPath))
        let host = FleetBridgeHost(
            bridgeID: UUID(),
            bridgeName: "Studio",
            capabilities: [.observe],
            initialSnapshot: FleetSnapshot(revision: 1, devices: []),
            requestHandler: { .success(id: $0.id) }
        )
        let server = FleetBridgeUnixServer(host: host, socketPath: fixture.socketPath)

        do {
            try await server.start()
            XCTFail("expected invalid existing socket error")
        } catch let error as FleetBridgeUnixError {
            guard case .invalidExistingSocket(let path) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, fixture.socketPath)
        }
        await server.stop()
        XCTAssertEqual(
            try String(contentsOfFile: fixture.socketPath, encoding: .utf8),
            "do not delete"
        )
    }
}

private struct Fixture {
    let directory: URL
    var socketPath: String { directory.appendingPathComponent("bridge.sock").path }

    init(createDirectory: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-unix-test-\(UUID().uuidString)")
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class POSIXTestClient {
    private var fd: Int32
    private var decoder = FleetWireDecoder()

    init(path: String) throws {
        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, socketType, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            _ = systemClose(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            _ = systemClose(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.fd = fd
    }

    func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return systemWrite(fd, base.advanced(by: offset), raw.count - offset)
            }
            guard result > 0 else { throw POSIXError(.EIO) }
            offset += result
        }
    }

    func readMessage() throws -> FleetWireMessage {
        while true {
            if let message = try decoder.nextMessage() { return message }
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = systemRead(fd, &bytes, bytes.count)
            guard count > 0 else { throw POSIXError(.ECONNRESET) }
            try decoder.append(Data(bytes.prefix(count)))
        }
    }

    func close() {
        guard fd >= 0 else { return }
        _ = systemClose(fd)
        fd = -1
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

private func systemRead(
    _ fd: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.read(fd, buffer, count)
    #else
    Glibc.read(fd, buffer, count)
    #endif
}

private func systemWrite(
    _ fd: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    #if canImport(Darwin)
    Darwin.write(fd, buffer, count)
    #else
    Glibc.write(fd, buffer, count)
    #endif
}
