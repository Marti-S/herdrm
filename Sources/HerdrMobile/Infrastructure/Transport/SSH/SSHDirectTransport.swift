import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// Owns one authenticated SSH connection to a device. RPCs each open a fresh
/// streamlocal channel (herdr is one-request-per-connection); terminal streams
/// and attachment SFTP transfers share the same authenticated SSH session.
final class SSHDirectTransport: MobileTransport {
    private let connection: SSHConnection
    private let socketPath: String
    private let homeDirectory: String

    private static let requestTimeout: Duration = .seconds(15)

    private init(
        connection: SSHConnection,
        socketPath: String,
        homeDirectory: String
    ) {
        self.connection = connection
        self.socketPath = socketPath
        self.homeDirectory = homeDirectory
    }

    /// Connects, verifies the pinned host key (TOFU on first contact),
    /// authenticates, and resolves the remote home/socket paths.
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

            // sshd exec is not a login shell, but HOME is always set. Resolve
            // it even with a socket override because attachment staging needs a
            // stable private cache on the remote device.
            let result = try await connection.execute(
                "printf '%s' \"$HOME\"", timeout: .seconds(10)
            )
            let home = String(data: result.stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.exitStatus == 0,
                  let home,
                  home.hasPrefix("/")
            else { throw MobileTransportError.homeProbeFailed }

            let socketPath: String
            if let override = device.socketPath, !override.isEmpty {
                socketPath = override
            } else {
                socketPath = home + "/.config/herdr/herdr.sock"
            }
            return SSHDirectTransport(
                connection: connection,
                socketPath: socketPath,
                homeDirectory: home
            )
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
        var line = reply
        if line.last == 0x0A { line.removeLast() }
        return try SocketRPC.decodeResponse(line)
    }

    func events(
        kinds: [String],
        statusPaneIDs: [String]
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        let connection = connection
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var scopedPaneIDs = statusPaneIDs
                    subscriptionAttempt: while !Task.isCancelled {
                        let channel = try await connection.openStreamLocal(
                            socketPath: socketPath, timeout: .seconds(10)
                        )
                        var retryWithoutScopedStatus = false
                        do {
                            let subscribe = SocketRPC.eventSubscriptionParams(
                                kinds: kinds,
                                statusPaneIDs: scopedPaneIDs
                            )
                            try await channel.write(
                                SocketRPC.encodeRequest(
                                    id: "events",
                                    method: "events.subscribe",
                                    params: subscribe
                                ),
                                timeout: .seconds(10)
                            )
                            var buffer = Data()
                            var sawAck = false
                            eventRead: while !Task.isCancelled {
                                // Long timeout: herdr only writes when something happens.
                                guard let chunk = try await channel.read(timeout: .seconds(3600)) else { break }
                                buffer.append(chunk)
                                while let index = buffer.firstIndex(of: 0x0A) {
                                    let line = buffer.prefix(upTo: index)
                                    buffer.removeSubrange(...index)
                                    guard !line.isEmpty else { continue }
                                    guard sawAck else {
                                        do {
                                            _ = try SocketRPC.decodeResponse(Data(line))
                                        } catch where SocketRPC.shouldRetryStatusSubscription(
                                            after: error,
                                            statusPaneIDs: scopedPaneIDs
                                        ) {
                                            retryWithoutScopedStatus = true
                                            break eventRead
                                        }
                                        sawAck = true
                                        continuation.yield(HerdrEvent(
                                            kind: HerdrEvent.subscriptionStartedKind,
                                            payload: .object([:])
                                        ))
                                        continue
                                    }
                                    if let event = SocketRPC.decodeEvent(Data(line)) {
                                        continuation.yield(event)
                                    }
                                }
                            }
                        } catch {
                            try? await channel.close(timeout: .seconds(2))
                            throw error
                        }
                        try? await channel.close(timeout: .seconds(2))
                        if retryWithoutScopedStatus {
                            scopedPaneIDs = []
                            continue subscriptionAttempt
                        }
                        if Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: HerdrError.connectionFailed(
                                "event stream ended"
                            ))
                        }
                        return
                    }
                    if !Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openTerminalSession(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) async throws -> any TerminalSession {
        guard size.isValid else {
            throw MobileTransportError.invalidTerminalSize
        }

        let channel = try await connection.openPTY(
            command: MobileAttach.structuredCommand(
                target: target,
                mode: mode,
                size: size
            ),
            columns: size.columns,
            rows: size.rows,
            timeout: .seconds(15)
        )
        return SSHStructuredTerminalSession(
            channel: channel,
            mode: mode,
            initialSize: size
        )
    }

    func readFileRange(path: String, offset: Int64, limit: Int) async throws -> FileRangeRead {
        let result = try await connection.execute(
            FileRangeRead.shellCommand(path: path, offset: offset, limit: limit),
            timeout: .seconds(30)
        )
        guard result.exitStatus == 0 else {
            throw HerdrError.fileOperationFailed(
                String(data: result.stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "session read failed"
            )
        }
        return try FileRangeRead.parse(result.stdout)
    }

    func stageAttachment(_ attachment: MobileAttachmentPayload) async throws -> String {
        guard attachment.bytes.count <= FleetAttachment.maximumBytes else {
            throw MobileAttachmentError.tooLarge(limit: FleetAttachment.maximumBytes)
        }

        let root = homeDirectory + "/.cache/herdrm/mobile-uploads"
        let setup = try await connection.execute(
            "umask 077; mkdir -p \(ShellQuoting.quoted(root))",
            timeout: .seconds(15)
        )
        guard setup.exitStatus == 0 else {
            let detail = String(data: setup.stderr, encoding: .utf8)
                ?? "remote mkdir exited \(setup.exitStatus)"
            throw HerdrError.fileTransferFailed(detail)
        }

        let safeName = FleetAttachment.sanitizedFileName(attachment.fileName)
        let identifier = UUID().uuidString.lowercased()
        let finalPath = root + "/" + identifier + "-" + safeName
        let partialPath = finalPath + ".partial-" + UUID().uuidString.lowercased()
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: .seconds(15))
        } catch {
            throw HerdrError.fileTransferFailed("could not open SFTP: \(error)")
        }

        var file: SSHSFTPFile?
        do {
            let opened = try await sftp.openFileForWriting(
                at: partialPath,
                permissions: 0o600,
                timeout: .seconds(15)
            )
            file = opened

            let chunkSize = 256 * 1024
            var offset = attachment.bytes.startIndex
            while offset < attachment.bytes.endIndex {
                let remaining = attachment.bytes.distance(
                    from: offset,
                    to: attachment.bytes.endIndex
                )
                let next = attachment.bytes.index(
                    offset,
                    offsetBy: min(chunkSize, remaining)
                )
                try await opened.write(
                    Data(attachment.bytes[offset..<next]),
                    timeout: .seconds(30)
                )
                offset = next
            }
            try await opened.close(timeout: .seconds(10))
            file = nil
            try await sftp.setPermissions(
                at: partialPath,
                permissions: 0o600,
                timeout: .seconds(10)
            )
            try await sftp.renameFileAtomically(
                from: partialPath,
                to: finalPath,
                timeout: .seconds(15)
            )
            try? await sftp.close(timeout: .seconds(5))
            return finalPath
        } catch {
            if let file { try? await file.close(timeout: .seconds(3)) }
            try? await sftp.removeFileForCompensation(
                at: partialPath,
                timeout: .seconds(5)
            )
            try? await sftp.close(timeout: .seconds(5))
            throw HerdrError.fileTransferFailed("direct SSH upload failed: \(error)")
        }
    }

    func close() async {
        try? await connection.close(timeout: .seconds(3))
    }
}
