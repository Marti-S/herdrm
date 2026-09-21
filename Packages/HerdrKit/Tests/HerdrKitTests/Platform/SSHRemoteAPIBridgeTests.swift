#if os(macOS)
import Darwin
import XCTest
@testable import HerdrKit

final class SSHRemoteAPIBridgeTests: XCTestCase {
    func testSocketNamesUseRepeatable64BitTargetDigestWithinUnixPathLimit() {
        let local = SSHTunnel.localSocketPath(for: "abc")
        let control = SSHRemoteAPIBridge.controlPath(for: "abc")
        for path in [local, control] {
            XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "ba7816bf8f01cfea.sock")
            XCTAssertLessThan(path.utf8.count, 104)
            // Foundation can append the app bundle identifier to the macOS
            // per-user temporary directory. Preserve room for that app path.
            let appTemporaryDirectory = URL(fileURLWithPath:
                "/var/folders/sz/ll9qyhx152n00qhxv5p2r9rc0000gn/T/dev.bybee.herdrm")
            let appPath = appTemporaryDirectory
                .appendingPathComponent(URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent)
                .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
            XCTAssertLessThan(appPath.utf8.count, 104)
        }
        XCTAssertEqual(local, SSHTunnel.localSocketPath(for: "abc"))
        XCTAssertEqual(control, SSHRemoteAPIBridge.controlPath(for: "abc"))
        XCTAssertNotEqual(local, SSHTunnel.localSocketPath(for: "abd"))
        XCTAssertNotEqual(control, SSHRemoteAPIBridge.controlPath(for: "abd"))
        XCTAssertEqual(URL(fileURLWithPath: local).deletingLastPathComponent().lastPathComponent, "herdrm-tunnels")
        XCTAssertEqual(URL(fileURLWithPath: control).deletingLastPathComponent().lastPathComponent, "herdrm-ssh-cm")
    }

    func testUnexpectedAcceptFailureRetiresListenerBeforeReplacement() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let failed = SSHRemoteAPIBridge(
            localSocketPath: "/tmp/herdrm-accept-\(UUID().uuidString).sock",
            target: "unused", herdrExecutable: "unused", credentialID: nil,
            acceptClient: { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
                errno = EMFILE
                return -1
            }
        )
        defer { failed.stop() }
        try failed.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(failed.isRunning)
        release.signal()
        let deadline = Date().addingTimeInterval(2)
        while failed.isRunning && Date() < deadline { usleep(1_000) }
        XCTAssertFalse(failed.isRunning)
        XCTAssertTrue(failed.lastError?.contains("accept():") == true)
        XCTAssertTrue(failed.lastError?.contains(String(cString: strerror(EMFILE))) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.localSocketPath))
        guard !failed.isRunning else { return }
        let replacement = try bridge(socketPath: failed.localSocketPath)
        failed.stop()
        failed.stop()
        let client = try connect(replacement)
        defer { close(client) }
        try send("replacement\n", to: client)
        XCTAssertEqual(try read(client, count: 12), Data("replacement\n".utf8))
    }

    private func bridge(
        executable: String = "/bin/cat",
        arguments: [String] = [],
        socketPath: String? = nil,
        authentication: SSHAuthenticationConfiguration? = nil,
        configure: ((Process) -> Void)? = nil
    ) throws -> SSHRemoteAPIBridge {
        let bridge = SSHRemoteAPIBridge(
            localSocketPath: socketPath ?? "/tmp/herdrm-bridge-\(UUID().uuidString).sock",
            target: "fixture.invalid:2222", herdrExecutable: "herdr.exe", credentialID: nil,
            configureProcess: { process in
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                configure?(process)
            },
            makeAuthentication: {
                authentication ?? SSHAuthenticationConfiguration(arguments: [], environment: [:], authorizationID: nil)
            }
        )
        try bridge.start()
        addTeardownBlock {
            bridge.stop()
            let deadline = Date().addingTimeInterval(4)
            while bridge.activeClientCount != 0 && Date() < deadline { usleep(10_000) }
            XCTAssertEqual(bridge.activeClientCount, 0, "pumps failed to stop before the fixture deadline")
        }
        return bridge
    }

    private func connect(_ bridge: SSHRemoteAPIBridge) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, 4)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(bridge.localSocketPath.utf8)) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    private func send(_ text: String, to fd: Int32) throws {
        let data = Data(text.utf8)
        let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard n == data.count else { throw POSIXError(.EIO) }
    }

    private func read(_ fd: Int32, count: Int? = nil) throws -> Data {
        let deadline = Date().addingTimeInterval(3)
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready == 0 { continue }
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw POSIXError(.EIO) }
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n == 0 { return data }
            guard n > 0 else { throw POSIXError(.EIO) }
            data.append(contentsOf: bytes.prefix(n))
            if let count, data.count >= count { return data }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func testSequentialAndConcurrentClientsRoundTripSplitAndCoalescedRecords() throws {
        let bridge = try bridge()
        for _ in 0..<10 {
            let fd = try connect(bridge)
            defer { close(fd) }
            try send("{\"id\":", to: fd)
            try send("1}\n{\"id\":2}\n", to: fd)
            shutdown(fd, SHUT_WR)
            XCTAssertEqual(try read(fd), Data("{\"id\":1}\n{\"id\":2}\n".utf8))
        }
        let clients = try (0..<4).map { _ in try connect(bridge) }
        defer { clients.forEach { close($0) } }
        for fd in clients { try send("event\n", to: fd) }
        for fd in clients { XCTAssertEqual(try read(fd, count: 6), Data("event\n".utf8)) }
    }

    func testImmediateChildExitDrainsAllBufferedStdout() throws {
        let bridge = try bridge(executable: "/usr/bin/head", arguments: ["-c", "262144", "/dev/zero"])
        let fd = try connect(bridge)
        defer { close(fd) }
        // Give the producer a chance to exit before the consumer starts draining.
        usleep(100_000)
        XCTAssertEqual(try read(fd), Data(repeating: 0, count: 262_144))
    }

    func testEventsContinueAfterAcknowledgementAndIdle() throws {
        let bridge = try bridge(executable: "/bin/sh", arguments: [
            "-c", "printf 'ack\\n'; /bin/sleep 0.15; printf 'event\\n'; exec /bin/cat",
        ])
        let fd = try connect(bridge)
        defer { close(fd) }
        XCTAssertEqual(try read(fd, count: 4), Data("ack\n".utf8))
        XCTAssertEqual(try read(fd, count: 6), Data("event\n".utf8))
        try send("input\n", to: fd)
        XCTAssertEqual(try read(fd, count: 6), Data("input\n".utf8))
    }

    func testStopDuringReadAndAcceptIsIdempotentAndAllowsReplacement() throws {
        let bridge = try bridge(executable: "/bin/sleep", arguments: ["30"])
        let fd = try connect(bridge)
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(2)
        while bridge.activeClientCount == 0 && Date() < deadline { usleep(1_000) }
        XCTAssertEqual(bridge.activeClientCount, 1)
        bridge.stop()
        bridge.stop()
        XCTAssertFalse(bridge.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bridge.localSocketPath))
        XCTAssertEqual(try read(fd), Data())
        let replacement = try self.bridge(socketPath: bridge.localSocketPath)
        bridge.stop()
        let next = try connect(replacement)
        defer { close(next) }
        try send("new\n", to: next)
        XCTAssertEqual(try read(next, count: 4), Data("new\n".utf8))
    }

    func testAwaitedShutdownEscalatesAndConfirmsExitEvenWhenCallerIsCancelled() async throws {
        let processReady = expectation(description: "process configured")
        var process: Process?
        let bridge = try bridge(executable: "/bin/sh", arguments: [
            "-c", "trap '' TERM; printf 'ready\\n'; while :; do :; done",
        ], configure: {
            process = $0
            processReady.fulfill()
        })
        let fd = try connect(bridge)
        defer { close(fd) }
        await fulfillment(of: [processReady], timeout: 2)
        XCTAssertEqual(try read(fd, count: 6), Data("ready\n".utf8))
        let shutdown = Task { await bridge.stopAndWait() }
        shutdown.cancel()
        let stopped = await shutdown.value
        XCTAssertTrue(stopped)
        XCTAssertEqual(process?.isRunning, false)
        XCTAssertEqual(process?.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process?.terminationStatus, SIGKILL)
        let stoppedAgain = await bridge.stopAndWait()
        XCTAssertTrue(stoppedAgain)
    }

    func testShutdownDeadlineDoesNotAffirmExitWhileLaunchIsBlocked() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let bridge = try bridge(configure: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 7)
        })
        let fd = try connect(bridge)
        defer { close(fd); release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        let premature = await bridge.stopAndWait()
        XCTAssertFalse(premature)
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        release.signal()
        let exited = await bridge.stopAndWait()
        XCTAssertTrue(exited)
    }

    func testStopCannotMissChildWhoseLaunchIsPending() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let bridge = try bridge(configure: { _ in
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
        })
        let fd = try connect(bridge)
        defer { close(fd) }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { bridge.stop(); stopped.signal() }
        release.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try read(fd), Data())
        let exited = await bridge.stopAndWait()
        XCTAssertTrue(exited)
    }

    func testFailedExecRetainsSSHDiagnosticsAndLaunchFailureClosesClient() throws {
        let bridge = try bridge(executable: "/bin/sh", arguments: ["-c", "echo 'Permission denied' >&2; exit 23"])
        let fd = try connect(bridge)
        defer { close(fd) }
        XCTAssertEqual(try read(fd), Data())
        let deadline = Date().addingTimeInterval(2)
        while bridge.lastError == nil && Date() < deadline { usleep(1_000) }
        XCTAssertTrue(bridge.lastError?.contains("Permission denied") == true)

        let invalid = try self.bridge(executable: "/nonexistent/herdrm-fixture")
        let other = try connect(invalid)
        defer { close(other) }
        XCTAssertEqual(try read(other), Data())
        XCTAssertNotNil(invalid.lastError)
    }

    func testAuthorizationSurvivesLaunchUntilConsumptionAndStopRemovesUnusedGrant() throws {
        let authorizationID = UUID()
        let path = SSHCredentialStore.authorizationFilePath(authorizationID)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture-only".utf8).write(to: url)
        defer { try? SSHCredentialStore.removeAuthorization(authorizationID) }
        let authentication = SSHAuthenticationConfiguration(arguments: [], environment: [:], authorizationID: authorizationID)
        let bridge = try bridge(authentication: authentication)
        let fd = try connect(bridge)
        defer { close(fd) }
        try send("started\n", to: fd)
        XCTAssertEqual(try read(fd, count: 8), Data("started\n".utf8))
        XCTAssertEqual(try SSHCredentialStore.consumePassword(authorizationID: authorizationID), "fixture-only")
        try Data("unused-fixture".utf8).write(to: url)
        bridge.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFailedBindDoesNotRemoveAnotherListenersSocket() throws {
        let first = try bridge()
        let second = SSHRemoteAPIBridge(localSocketPath: first.localSocketPath,
                                       target: "unused", herdrExecutable: "unused", credentialID: nil)
        XCTAssertThrowsError(try second.start())
        second.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localSocketPath))
    }
}
#endif
