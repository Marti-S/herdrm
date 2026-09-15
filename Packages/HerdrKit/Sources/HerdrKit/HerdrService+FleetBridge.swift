#if os(macOS)
import Foundation

extension HerdrService {
    /// A machine-readable terminal-session process suitable for a bridge.
    /// Unlike the embedded Mac terminal attach, this command never requests a
    /// PTY and never takes over unless the caller explicitly asks for control.
    public nonisolated func terminalSessionCommand(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize,
        serverVersion: String? = nil
    ) -> TerminalCommand {
        let targetValue: String
        switch target {
        case .agent(let paneID): targetValue = paneID
        case .terminal(let terminalID): targetValue = terminalID
        }

        let action = mode.access == .observe ? "observe" : "control"
        let takeover = mode.takeover ? " --takeover" : ""
        let arguments = "terminal session \(action) \(Self.shellQuoted(targetValue))"
            + takeover
            + " --cols \(size.columns) --rows \(size.rows)"

        switch device.kind {
        case .local, .tailcat:
            var environment = (ShellEnvironment.cached ?? .empty).launchEnvironment(binary: nil)
            environment.removeValue(forKey: "TERM")
            environment.removeValue(forKey: "COLUMNS")
            environment.removeValue(forKey: "LINES")
            // Same socket overrides as `attachCommand`: a tailcat device runs
            // the LOCAL herdr CLI against the tunnel's bridge socket, so the
            // session stream rides the same WireGuard tunnel as the RPCs, and a
            // named-session Local device must not fall back to the default
            // session's socket.
            if device.isTailcat {
                environment["HERDR_SOCKET_PATH"] =
                    TailcatBridgeManager.localSocketPath(deviceID: device.id)
            } else if let socketPath = device.socketPath {
                environment["HERDR_SOCKET_PATH"] = socketPath
            }
            let script = "\(Self.attachBinarySelection(serverVersion: serverVersion)); "
                + "exec \"$hb\" \(arguments)"
            return TerminalCommand(
                executable: "/bin/sh",
                args: ["-c", script],
                environment: environment,
                authorizationID: nil
            )

        case .ssh(let target):
            let script = "\(SSHTunnel.remotePathExport); "
                + "\(Self.attachBinarySelection(serverVersion: serverVersion)); "
                + "exec \"$hb\" \(arguments)"
            let remote = "exec /bin/sh -c \(Self.shellQuoted(script))"
            let authentication = SSHTunnel.authenticationConfiguration(for: device.id)
            var environment = (ShellEnvironment.cached ?? .empty).launchEnvironment(binary: nil)
            environment.merge(authentication.environment) { _, authenticationValue in
                authenticationValue
            }
            environment.removeValue(forKey: "TERM")
            environment.removeValue(forKey: "COLUMNS")
            environment.removeValue(forKey: "LINES")
            return TerminalCommand(
                executable: "/usr/bin/ssh",
                args: authentication.arguments + [
                    "-T",
                    "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3",
                    SSHTunnel.sshDestination(target),
                    remote,
                ],
                environment: environment,
                authorizationID: authentication.authorizationID
            )
        }
    }
}
#endif
