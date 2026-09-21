#if os(macOS)
import XCTest
@testable import HerdrKit

final class WindowsSSHProbeTests: XCTestCase {
    func testUnixHomeRequiresAbsolutePath() {
        XCTAssertTrue(SSHTunnel.isUnixHome("/home/david"))
        XCTAssertTrue(SSHTunnel.isUnixHome("/Users/david"))
        XCTAssertFalse(SSHTunnel.isUnixHome("$HOME"))
        XCTAssertFalse(SSHTunnel.isUnixHome("\"$HOME\""))
        XCTAssertFalse(SSHTunnel.isUnixHome(#"C:\Users\david"#))
    }

    func testWindowsHomeAcceptsDriveLetterPaths() {
        XCTAssertTrue(SSHTunnel.isWindowsHome(#"C:\Users\david"#))
        XCTAssertTrue(SSHTunnel.isWindowsHome("C:/Users/david"))
        XCTAssertTrue(SSHTunnel.isWindowsHome(#"d:\Users\david"#))
        XCTAssertFalse(SSHTunnel.isWindowsHome("/home/david"))
        XCTAssertFalse(SSHTunnel.isWindowsHome("Users\\david"))
        XCTAssertFalse(SSHTunnel.isWindowsHome("C:"))
    }

    func testParseWindowsEnvironmentProbe() {
        let home = Data(#"C:\Users\david"#.utf8).base64EncodedString()
        let exe = Data(#"C:\Users\david\.herdr\packages\standalone\current\herdr.exe"#.utf8)
            .base64EncodedString()
        let output = """
        herdr-windows-home:1:\(home)
        herdr-windows-herdr:1:\(exe)
        """
        let parsed = SSHTunnel.parseWindowsEnvironmentProbe(output)
        XCTAssertEqual(parsed?.home, #"C:\Users\david"#)
        XCTAssertEqual(
            parsed?.herdrExecutable,
            #"C:\Users\david\.herdr\packages\standalone\current\herdr.exe"#
        )
    }

    func testParseWindowsEnvironmentProbeRejectsIncompleteOutput() {
        XCTAssertNil(SSHTunnel.parseWindowsEnvironmentProbe("herdr-windows-home:1:QzpcdG1w"))
        XCTAssertNil(SSHTunnel.parseWindowsEnvironmentProbe("not-a-probe"))
    }

    func testRemoteAPIBridgeCommandUsesPowerShellEncodedCommand() {
        let command = SSHRemoteAPIBridge.remoteCommand(
            herdrExecutable: #"C:\Users\david\.herdr\herdr.exe"#
        )
        XCTAssertTrue(command.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "))
        let encoded = String(command.split(separator: " ").last!)
        let data = try! XCTUnwrap(Data(base64Encoded: encoded))
        let script = String(data: data, encoding: .utf16LittleEndian)
            ?? String(bytes: data, encoding: .utf16LittleEndian)
        // EncodedCommand is UTF-16LE; reconstruct via utf16 pairs if needed.
        let decoded: String = {
            if let direct = String(data: data, encoding: .utf16LittleEndian) { return direct }
            var scalars: [UInt16] = []
            let bytes = [UInt8](data)
            var i = 0
            while i + 1 < bytes.count {
                scalars.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            return String(decoding: scalars, as: UTF16.self)
        }()
        XCTAssertEqual(decoded, #"& 'C:\Users\david\.herdr\herdr.exe' --session default remote-api-bridge"#)
        _ = script
    }

    func testLocalSocketPathIsStableForTarget() {
        let a = SSHTunnel.localSocketPath(for: "z7m")
        let b = SSHTunnel.localSocketPath(for: "z7m")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".sock"))
    }

    func testProbePreservesUnicodeQuotesAndSpacesAmidBannerAndCRLF() {
        let home = #"C:\Users\李 O'Brien"#
        let exe = #"D:\Program Files\工具 O'Brien\herdr.exe"#
        let output = "banner\r\nherdr-windows-home:1:\(Data(home.utf8).base64EncodedString())\r\n"
            + "herdr-windows-herdr:1:\(Data(exe.utf8).base64EncodedString())\r\n"
        let parsed = SSHTunnel.parseWindowsEnvironmentProbe(output)
        XCTAssertEqual(parsed?.home, home)
        XCTAssertEqual(parsed?.herdrExecutable, exe)
    }

    func testProbeRejectsInvalidBase64EmptyFieldsVersionsAndLiteralHome() {
        let home = Data(#"C:\Users\user"#.utf8).base64EncodedString()
        let exe = Data(#"C:\herdr.exe"#.utf8).base64EncodedString()
        for output in [
            "herdr-windows-home:1:!invalid!\nherdr-windows-herdr:1:\(exe)",
            "herdr-windows-home:1:\(home)\nherdr-windows-herdr:1:",
            "herdr-windows-home:2:\(home)\nherdr-windows-herdr:2:\(exe)",
            "herdr-windows-home:1:\(Data("$HOME".utf8).base64EncodedString())\nherdr-windows-herdr:1:\(exe)",
        ] {
            XCTAssertNil(SSHTunnel.parseWindowsEnvironmentProbe(output))
        }
    }

    func testEncodedCommandPreservesWholeScriptAndQuotesLiteralArguments() throws {
        let command = SSHRemoteAPIBridge.remoteCommand(
            herdrExecutable: #"C:\工具 O'Brien\herdr.exe"#, sessionName: "one'; Write-Output bad"
        )
        let encoded = try XCTUnwrap(command.split(separator: " ").last)
        let data = try XCTUnwrap(Data(base64Encoded: String(encoded)))
        XCTAssertEqual(String(data: data, encoding: .utf16LittleEndian),
                       #"& 'C:\工具 O''Brien\herdr.exe' --session 'one''; Write-Output bad' remote-api-bridge"#)
        let probe = SSHTunnel.powershellEncodedCommand(SSHTunnel.windowsEnvironmentProbeScript)
        let probeData = try XCTUnwrap(Data(base64Encoded: String(try XCTUnwrap(probe.split(separator: " ").last))))
        XCTAssertEqual(String(data: probeData, encoding: .utf16LittleEndian), SSHTunnel.windowsEnvironmentProbeScript)
    }
}
#endif
