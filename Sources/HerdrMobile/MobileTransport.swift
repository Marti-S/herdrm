import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// How the phone reaches a device's herdr session. Today: direct SSH with a
/// `direct-streamlocal` channel per RPC (herdr is one-request-per-connection).
/// A bridge transport slots in behind the same semantic interface later.
protocol MobileTransport: Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error>
    func openTerminalSession(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession
    func close() async
}

extension MobileTransport {
    func request<T: Decodable>(
        method: String,
        params: JSONValue = .object([:]),
        as type: T.Type
    ) async throws -> T {
        let result = try await request(method: method, params: params)
        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.malformedResponse("\(method): \(error)")
        }
    }
}

enum MobileTransportError: LocalizedError {
    case hostKeyChanged(fingerprint: String)
    case missingPassword
    case homeProbeFailed
    case unsupportedTerminalMode
    case invalidTerminalSize

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let fingerprint):
            return String(
                localized: "This device's SSH host key changed (\(fingerprint)). If the host was reinstalled, remove and re-add the device."
            )
        case .missingPassword:
            return String(localized: "No password saved for this device.")
        case .homeProbeFailed:
            return String(localized: "Could not resolve the home directory on the device.")
        case .unsupportedTerminalMode:
            return String(localized: "Direct SSH does not support read-only terminal observation yet.")
        case .invalidTerminalSize:
            return String(localized: "Terminal columns and rows must be greater than zero.")
        }
    }
}

/// Owns one authenticated SSH connection to a device. RPCs each open a fresh
/// streamlocal channel (herdr closes the socket after one reply); the event
/// subscription holds a long-lived channel and streams NDJSON lines.
final class SSHDirectTransport: MobileTransport {
    private let connection: SSHConnection
    private let socketPath: String

    private static let requestTimeout: Duration = .seconds(15)

    private init(connection: SSHConnection, socketPath: String) {
        self.connection = connection
        self.socketPath = socketPath
    }

    /// Connects, verifies the pinned host key (TOFU on first contact),
    /// authenticates (device key or Keychain password), and resolves the
    /// remote herdr socket path against the remote $HOME.
    static func connect(device: MobileDevice) async throws -> SSHDirectTransport {
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: device.host, port: device.port),
            timeout: .seconds(10)
        )
        do {
            let hostKey = connection.hostKey
            let fingerprint = Self.fingerprint(hostKey.key)
            if let pinned = KnownHostsStore.fingerprint(
                host: device.host, port: device.port, algorithm: hostKey.algorithm
            ) {
                guard pinned == fingerprint else {
                    throw MobileTransportError.hostKeyChanged(fingerprint: fingerprint)
                }
            } else {
                KnownHostsStore.pin(
                    host: device.host, port: device.port,
                    algorithm: hostKey.algorithm, fingerprint: fingerprint
                )
            }

            switch device.authMethod {
            case .deviceKey:
                // The private key stays in CryptoKit; libssh2 only ever sees
                // the signature produced by this closure.
                let key = DeviceKey.ensure()
                try await connection.authenticate(
                    username: device.username,
                    publicKey: DeviceKey.publicKeyBlob(key),
                    signer: { challenge in try key.signature(for: challenge) },
                    timeout: .seconds(15)
                )
            case .password:
                guard let password = MobileSecretStore.password(for: device.id) else {
                    throw MobileTransportError.missingPassword
                }
                try await connection.authenticate(
                    username: device.username,
                    password: password,
                    timeout: .seconds(15)
                )
            }

            let socketPath: String
            if let override = device.socketPath, !override.isEmpty {
                socketPath = override
            } else {
                // sshd exec is not a login shell, but $HOME is always set.
                let result = try await connection.execute(
                    "printf '%s' \"$HOME\"", timeout: .seconds(10)
                )
                guard let home = String(data: result.stdout, encoding: .utf8),
                      home.hasPrefix("/")
                else { throw MobileTransportError.homeProbeFailed }
                socketPath = home + "/.config/herdr/herdr.sock"
            }
            return SSHDirectTransport(connection: connection, socketPath: socketPath)
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    static func fingerprint(_ key: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString()
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        let payload = SocketRPC.encodeRequest(
            id: UUID().uuidString, method: method, params: params
        )
        let reply: Data
        do {
            reply = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: payload,
                timeout: Self.requestTimeout
            )
        } catch SSHError.streamLocalOpenFailed {
            throw HerdrError.remoteHerdrDown(target: "device", socketPath: socketPath)
        }
        // exchangeStreamLocal returns up to the first newline-terminated chunk;
        // trim a trailing newline before decoding.
        var line = reply
        if line.last == 0x0A { line.removeLast() }
        return try SocketRPC.decodeResponse(line)
    }

    func events(kinds: [String]) -> AsyncThrowingStream<HerdrEvent, Error> {
        let connection = connection
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let channel = try await connection.openStreamLocal(
                        socketPath: socketPath, timeout: .seconds(10)
                    )
                    defer { Task { try? await channel.close(timeout: .seconds(2)) } }
                    let subscribe = JSONValue.object([
                        "subscriptions": .array(kinds.map { .object(["type": .string($0)]) })
                    ])
                    try await channel.write(
                        SocketRPC.encodeRequest(id: "events", method: "events.subscribe", params: subscribe),
                        timeout: .seconds(10)
                    )
                    var buffer = Data()
                    var sawAck = false
                    while !Task.isCancelled {
                        // Long timeout: herdr only writes when something happens.
                        guard let chunk = try await channel.read(timeout: .seconds(3600)) else { break }
                        buffer.append(chunk)
                        while let index = buffer.firstIndex(of: 0x0A) {
                            let line = buffer.prefix(upTo: index)
                            buffer.removeSubrange(...index)
                            guard !line.isEmpty else { continue }
                            guard sawAck else {
                                sawAck = true  // first line is the subscribe ack
                                continue
                            }
                            if let value = try? JSONDecoder().decode(JSONValue.self, from: line) {
                                let kind = value["event"]?["type"]?.stringValue
                                    ?? value["type"]?.stringValue
                                    ?? value["kind"]?.stringValue
                                    ?? "unknown"
                                continuation.yield(HerdrEvent(kind: kind, payload: value))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens the current direct-SSH PTY implementation behind the semantic
    /// terminal session boundary. Read-only observation will be implemented by
    /// a structured Herdr terminal-session adapter rather than by pretending a
    /// PTY takeover is an observer.
    func openTerminalSession(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession {
        guard mode.access == .control else {
            throw MobileTransportError.unsupportedTerminalMode
        }
        guard size.isValid else {
            throw MobileTransportError.invalidTerminalSize
        }

        let channel = try await connection.openPTY(
            command: MobileAttach.command(target: target, takeover: mode.takeover),
            columns: size.columns,
            rows: size.rows,
            timeout: .seconds(15)
        )
        return SSHPTYTerminalSession(
            channel: channel,
            mode: mode,
            initialSize: size
        )
    }

    func close() async {
        try? await connection.close(timeout: .seconds(3))
    }
}

enum MobileAttach {
    /// Non-login sshd exec leaves PATH at /usr/bin:/bin; herdr usually lives in
    /// a user prefix. Mirrors the Mac app's remote attach PATH handling.
    static let pathExport = #"export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin""#

    /// APC marker printed just before exec. sshd runs the command through the
    /// user's shell, whose rc chatter would otherwise leak into the terminal.
    static let bootstrapMarker =
        Data([0x1B, 0x5F]) + Data("herdrm-attach".utf8) + Data([0x1B, 0x5C])
    private static let markerPrintf = #"printf '\033_herdrm-attach\033\\'"#

    /// The remote command for attaching to an agent pane or a bare terminal.
    static func command(target: TerminalAttachTarget, takeover: Bool) -> String {
        let attach: String
        switch target {
        case .agent(let paneID):
            attach = "herdr agent attach \(ShellQuoting.quoted(paneID))"
        case .terminal(let terminalID):
            attach = "herdr terminal attach \(ShellQuoting.quoted(terminalID))"
        }
        let takeoverFlag = takeover ? " --takeover" : ""
        let script = "\(pathExport); \(markerPrintf); exec \(attach)\(takeoverFlag)"
        return "/bin/sh -c \(ShellQuoting.quoted(script))"
    }
}
