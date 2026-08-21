import Foundation
import XCTest
@testable import HerdrKit

final class AgentDiscoveryTests: XCTestCase {
    func testRemotePathExportFindsNVMAndGrokBinaries() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let nvmBin = home.appendingPathComponent(".nvm/versions/node/v22.14.0/bin", isDirectory: true)
        let grokBin = home.appendingPathComponent(".grok/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: grokBin, withIntermediateDirectories: true)

        // Unique names: the export also prepends real machine directories
        // (/opt/homebrew/bin and friends), so a genuine codex/grok install on
        // the test machine would shadow the fixtures and break hermeticity.
        let marker = UUID().uuidString.lowercased().prefix(8)
        let codex = nvmBin.appendingPathComponent("hkt-codex-\(marker)")
        let grok = grokBin.appendingPathComponent("hkt-grok-\(marker)")
        for executable in [codex, grok] {
            XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "\(SSHTunnel.remotePathExport); command -v \(codex.lastPathComponent); command -v \(grok.lastPathComponent)",
        ]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let paths = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(paths, [codex.path, grok.path])
    }
}
