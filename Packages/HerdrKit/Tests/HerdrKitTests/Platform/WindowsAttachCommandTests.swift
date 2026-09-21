#if os(macOS)
import XCTest
@testable import HerdrKit

final class WindowsAttachCommandTests: XCTestCase {
    private func windowsDevice() -> Device {
        var device = Device(name: "Windows", kind: .ssh(target: "user@fixture.invalid:2222"))
        device.osID = "WiNdOwS"
        return device
    }

    func testWindowsAgentAndOrdinaryTerminalUseLocalCLIAndBridgeSocket() {
        let device = windowsDevice()
        let service = HerdrService(device: device, autoStartLocalServer: false)
        for target: TerminalAttachTarget in [.agent(paneID: "pane'1"), .terminal(terminalID: "term'1")] {
            let command = service.attachCommand(target: target, serverVersion: "0.9.0")
            XCTAssertEqual(command.executable, "/bin/sh")
            XCTAssertEqual(command.environment["HERDR_SOCKET_PATH"], SSHTunnel.localSocketPath(for: device.sshTarget!))
            XCTAssertNil(command.authorizationID)
            XCTAssertNil(command.environment[SSHCredentialStore.authorizationIDEnvironmentKey])
            for key in ["TERM", "COLUMNS", "LINES"] { XCTAssertNil(command.environment[key]) }
            let script = command.args.last ?? ""
            XCTAssertTrue(script.contains(HerdrService.attachBinarySelection(serverVersion: "0.9.0")))
            XCTAssertTrue(script.contains("'\\''1' --takeover"))
            XCTAssertFalse(command.args.contains("-tt"))
            switch target {
            case .agent: XCTAssertTrue(script.contains("agent attach"))
            case .terminal: XCTAssertTrue(script.contains("terminal attach"))
            }
        }
    }

    func testCachedServiceUsesCurrentMetadataForStructuredWindowsObserveAndControl() {
        var device = windowsDevice()
        device.osID = nil
        let service = HerdrService(device: device, autoStartLocalServer: false)
        device.osID = "windows"
        for mode: TerminalSessionMode in [.observe, .control(), .control(takeover: true)] {
            let command = service.terminalSessionCommand(
                target: .terminal(terminalID: "term'1"), mode: mode,
                size: TerminalSize(columns: 80, rows: 24), serverVersion: "0.9.0",
                currentDevice: device
            )
            XCTAssertEqual(command.executable, "/bin/sh")
            XCTAssertEqual(command.environment["HERDR_SOCKET_PATH"], SSHTunnel.localSocketPath(for: device.sshTarget!))
            XCTAssertNil(command.authorizationID)
            XCTAssertFalse(command.args.contains("-tt"))
            XCTAssertFalse(command.args.contains("-T"))
            XCTAssertEqual(command.args.last?.contains(" --takeover"), mode.takeover)
            XCTAssertTrue(command.args.last?.contains("terminal session \(mode.access.rawValue) 'term'\\''1'") == true)
        }
    }

    func testCurrentUnixMetadataCanClearAnOldWindowsSnapshot() {
        var device = windowsDevice()
        let service = HerdrService(device: device, autoStartLocalServer: false)
        device.osID = nil
        let command = service.terminalSessionCommand(
            target: .agent(paneID: "pane"), mode: .observe,
            size: TerminalSize(columns: 80, rows: 24), currentDevice: device
        )
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.args.contains("-T"))
        XCTAssertFalse(command.args.contains("-tt"))
        XCTAssertFalse(command.args.last?.contains("--takeover") == true)
    }

    func testWindowsOSIDDoesNotOverrideTailcatOrNamedLocalSocketRouting() {
        var tailcat = Device(name: "Tailcat", kind: .tailcat)
        tailcat.osID = "windows"
        let local = Device(name: "Named", kind: .local, socketPath: "/tmp/named-herdr.sock")
        for device in [tailcat, local] {
            let expected = device.isTailcat ? TailcatBridgeManager.localSocketPath(deviceID: device.id) : device.socketPath
            let service = HerdrService(device: device, autoStartLocalServer: false)
            let attach = service.attachCommand(target: .agent(paneID: "pane"))
            let structured = service.terminalSessionCommand(
                target: .agent(paneID: "pane"), mode: .observe, size: TerminalSize(columns: 80, rows: 24)
            )
            XCTAssertEqual(attach.environment["HERDR_SOCKET_PATH"], expected)
            XCTAssertEqual(structured.environment["HERDR_SOCKET_PATH"], expected)
        }
    }

    func testWindowsStandaloneShellStillUsesSSHWithoutRemotePOSIXScript() {
        let command = HerdrService(device: windowsDevice(), autoStartLocalServer: false).terminalCommand()
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        XCTAssertTrue(command.args.contains("-tt"))
        XCTAssertEqual(command.args.last, "ssh://user@fixture.invalid:2222")
    }
}
#endif
