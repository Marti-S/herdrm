#if os(macOS)
import Foundation

/// Serves the existing socket protocol over one SSH stdio channel per client.
/// Windows OpenSSH cannot forward drive-letter AF_UNIX paths with `-L`.
final class SSHRemoteAPIBridge: @unchecked Sendable {
    let localSocketPath: String
    let target: String
    let herdrExecutable: String
    let credentialID: UUID?
    let sessionName: String

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var stopped = false
    private var children: [ObjectIdentifier: Child] = [:]
    private var errorText = ""
    // Separate from byte-pump lifetime: closed pipes do not prove process exit.
    private let ownedExits = DispatchGroup()
    // Local process fixtures exercise the actual listener and byte pumps without SSH.
    private let configureProcess: ((Process) -> Void)?
    private let makeAuthentication: () -> SSHAuthenticationConfiguration
    private let acceptClient: (Int32) -> Int32

    private final class Child: @unchecked Sendable {
        let process: Process
        let clientFD: Int32
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        private let lock = NSLock()
        private var cancelled = false
        private var authorization: SSHAuthenticationConfiguration?

        init(process: Process, clientFD: Int32, authentication: SSHAuthenticationConfiguration) {
            self.process = process
            self.clientFD = clientFD
            self.authorization = authentication
        }

        func discardAuthorization() {
            lock.lock()
            let authorization = self.authorization
            self.authorization = nil
            lock.unlock()
            authorization?.discardAuthorization()
        }

        /// Wake the pumps, but never close a descriptor another thread is using.
        /// Their dispatch group owns the final close after both directions drain.
        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            Darwin.shutdown(clientFD, SHUT_RDWR)
            if process.isRunning { process.terminate() }
            lock.unlock()
            discardAuthorization()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                defer { lock.unlock() }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        func closeAfterDraining() {
            cancel()
            close(clientFD)
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    init(
        localSocketPath: String,
        target: String,
        herdrExecutable: String,
        credentialID: UUID?,
        sessionName: String = "default",
        configureProcess: ((Process) -> Void)? = nil,
        makeAuthentication: (() -> SSHAuthenticationConfiguration)? = nil,
        acceptClient: @escaping (Int32) -> Int32 = { Darwin.accept($0, nil, nil) }
    ) {
        self.localSocketPath = localSocketPath
        self.target = target
        self.herdrExecutable = herdrExecutable
        self.credentialID = credentialID
        self.sessionName = sessionName
        self.configureProcess = configureProcess
        self.acceptClient = acceptClient
        self.makeAuthentication = makeAuthentication ?? {
            SSHTunnel.authenticationConfiguration(for: credentialID)
        }
    }

    func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { throw HerdrError.tunnelFailed("bridge has stopped") }
        guard listenerFD < 0 else { return }

        let directory = (localSocketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrError.tunnelFailed("socket(): \(String(cString: strerror(errno)))")
        }
        var bound = false
        var started = false
        defer {
            if !started {
                close(fd)
                if bound { try? FileManager.default.removeItem(atPath: localSocketPath) }
            }
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(localSocketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HerdrError.tunnelFailed("bridge socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            throw HerdrError.tunnelFailed("bind(\(localSocketPath)): \(String(cString: strerror(errno)))")
        }
        bound = true
        _ = chmod(localSocketPath, 0o600)
        guard listen(fd, 32) == 0 else {
            throw HerdrError.tunnelFailed("listen(): \(String(cString: strerror(errno)))")
        }
        listenerFD = fd
        started = true
        let thread = Thread { [weak self] in
            // Only this thread closes the listener, after accept has returned.
            defer { close(fd) }
            while let self {
                self.lock.lock()
                let running = !self.stopped
                self.lock.unlock()
                guard running else { return }
                let client = self.acceptClient(fd)
                if client < 0 {
                    let acceptError = errno
                    if acceptError == EINTR { continue }
                    self.lock.lock()
                    // Retire ownership before the thread closes fd. stop() must
                    // never shutdown a descriptor the OS may already have reused,
                    // nor may late cleanup unlink a replacement listener's path.
                    if self.listenerFD == fd {
                        self.listenerFD = -1
                        self.errorText = String((self.errorText
                            + "accept(): \(String(cString: strerror(acceptError)))\n").suffix(16_384))
                        try? FileManager.default.removeItem(atPath: self.localSocketPath)
                    }
                    self.lock.unlock()
                    return
                }
                self.spawnProxy(clientFD: client)
            }
        }
        thread.name = "herdrm.windows-api-bridge"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        let active = Array(children.values)
        // Remove the pathname before another instance can bind it. Old cleanup
        // only closes its own descriptors, never the replacement's socket path.
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        lock.unlock()
        for child in active { child.cancel() }
    }

    /// Cancellation-independent, bounded shutdown of only our directly spawned
    /// proxies. Intentionally persistent SSH masters are not in this group.
    func stopAndWait() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                let deadline = DispatchTime.now() + 4
                let stopped = DispatchSemaphore(value: 0)
                DispatchQueue.global().async { [self] in
                    stop()
                    stopped.signal()
                }
                // Include launch-lock contention in the deadline. On timeout,
                // keep ownership and refuse affirmative application termination.
                let didStop = stopped.wait(timeout: deadline) == .success
                let exited = didStop && ownedExits.wait(timeout: deadline) == .success
                continuation.resume(returning: exited)
            }
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listenerFD >= 0 && !stopped
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return errorText.isEmpty ? nil : errorText
    }

    var activeClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return children.count
    }

    private func recordError(_ text: String) {
        lock.lock()
        errorText = String((errorText + text).suffix(16_384))
        lock.unlock()
    }

    private func spawnProxy(clientFD: Int32) {
        // Registration and launch share stop's lock: stop cannot miss an accepted
        // client or leave a child spawned after it captured the active set.
        lock.lock()
        guard !stopped else { lock.unlock(); close(clientFD); return }
        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        var noSigPipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        let authentication = makeAuthentication()
        let process = Process()
        let child = Child(process: process, clientFD: clientFD, authentication: authentication)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = authentication.arguments + [
            "-T",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=4",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", "ControlPath=\(Self.controlPath(for: target))",
            SSHTunnel.sshDestination(target),
            Self.remoteCommand(herdrExecutable: herdrExecutable, sessionName: sessionName),
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(authentication.environment) { _, new in new }
        configureProcess?(process)
        process.standardInput = child.stdinPipe
        process.standardOutput = child.stdoutPipe
        process.standardError = child.stderrPipe
        // SO_NOSIGPIPE applies to sockets; F_SETNOSIGPIPE protects pipe writes.
        _ = fcntl(child.stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        ownedExits.enter()
        let exits = ownedExits
        process.terminationHandler = { [weak child] _ in
            child?.discardAuthorization()
            exits.leave()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            ownedExits.leave()
            errorText = error.localizedDescription
            lock.unlock()
            child.closeAfterDraining()
            return
        }
        let id = ObjectIdentifier(process)
        children[id] = child
        lock.unlock()

        // Keep the one-shot askpass handoff through authentication, not just
        // Process.run(). Consumption/exit/stop/expiry each safely remove it.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak child] in
            child?.discardAuthorization()
        }
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            Self.copy(from: clientFD, to: child.stdinPipe.fileHandleForWriting.fileDescriptor)
            try? child.stdinPipe.fileHandleForWriting.close()
        }
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            Self.copy(from: child.stdoutPipe.fileHandleForReading.fileDescriptor, to: clientFD)
            // Process exit is not a drain signal. Deliver all buffered stdout
            // before shutting down the client and waking the input pump.
            child.cancel()
        }
        group.enter()
        Thread.detachNewThread { [weak self] in
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(child.stderrPipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                self?.recordError(String(decoding: buffer.prefix(n), as: UTF8.self))
            }
        }
        group.notify(queue: .global()) { [weak self] in
            child.closeAfterDraining()
            guard let self else { return }
            self.lock.lock()
            self.children.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private static func copy(from input: Int32, to output: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(input, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            var offset = 0
            while offset < n {
                let written = buffer.withUnsafeBytes {
                    write(output, $0.baseAddress!.advanced(by: offset), n - offset)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// OpenSSH remote argv: PowerShell EncodedCommand running remote-api-bridge.
    static func remoteCommand(herdrExecutable: String, sessionName: String = "default") -> String {
        let exe = herdrExecutable.replacingOccurrences(of: "'", with: "''")
        let session = sessionName.replacingOccurrences(of: "'", with: "''")
        let argument = sessionName == "default" ? "default" : "'\(session)'"
        let script = "& '\(exe)' --session \(argument) remote-api-bridge"
        return SSHTunnel.powershellEncodedCommand(script)
    }

    static func controlPath(for target: String) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-ssh-cm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(SSHTunnel.targetIdentifier(for: target)).sock").path
    }
}
#endif
