import XCTest
@testable import HerdrKit

final class DeviceFileServiceTests: XCTestCase {
    func testLocalListingClassifiesSortsAndFiltersEntries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        let hidden = root.appendingPathComponent(".secret")
        let link = root.appendingPathComponent("shortcut")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("notes".utf8).write(to: file)
        try Data("hidden".utf8).write(to: hidden)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let service = DeviceFileService(device: .local)
        let visible = try await service.listDirectory(at: root.path)
        XCTAssertEqual(visible.entries.map(\.name), ["Folder", "notes.txt", "shortcut"])
        XCTAssertEqual(visible.entries[0].kind, .directory)
        XCTAssertEqual(visible.entries[1].kind, .regularFile)
        XCTAssertEqual(visible.entries[1].size, 5)
        XCTAssertEqual(visible.entries[2].kind, .symbolicLink)

        let all = try await service.listDirectory(at: root.path, includingHidden: true)
        XCTAssertTrue(all.entries.contains(where: { $0.name == ".secret" && $0.isHidden }))
    }

    func testLocalCopySupportsReplaceAndFinderStyleKeepBoth() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destinationDirectory.appendingPathComponent("report.txt"))

        let service = DeviceFileService(device: .local)
        let kept = try await service.uploadFile(
            from: source,
            toDirectory: destinationDirectory.path,
            conflictPolicy: .keepBoth
        )
        XCTAssertEqual((kept as NSString).lastPathComponent, "report 2.txt")
        XCTAssertEqual(try String(contentsOfFile: kept, encoding: .utf8), "new")

        let replaced = try await service.uploadFile(
            from: source,
            toDirectory: destinationDirectory.path,
            conflictPolicy: .replace
        )
        XCTAssertEqual((replaced as NSString).lastPathComponent, "report.txt")
        XCTAssertEqual(try String(contentsOfFile: replaced, encoding: .utf8), "new")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
                .contains(where: { $0.contains(".herdrm-") })
        )
    }

    func testRemoteListingUsesNullDelimitedNames() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-ssh")
        let arguments = root.appendingPathComponent("arguments")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(HerdrService.shellQuoted(arguments.path))
        printf '%s\\0%s\\0%s\\0%s\\0' Folder directory 0 1770000000
        printf '%s\\0%s\\0%s\\0%s\\0' 'line
        break.txt' 'regular file' 12 1770000001
        """
        try makeExecutable(script, at: executable)

        let device = Device(name: "Remote", kind: .ssh(target: "user@example.test"))
        let service = DeviceFileService(device: device, sshExecutableURL: executable)
        let listing = try await service.listDirectory(at: "/srv/project")

        XCTAssertEqual(listing.entries.map(\.name), ["Folder", "line\nbreak.txt"])
        XCTAssertEqual(listing.entries[0].kind, .directory)
        XCTAssertEqual(listing.entries[1].kind, .regularFile)
        XCTAssertEqual(listing.entries[1].size, 12)
        let captured = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertTrue(captured.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(captured.contains("find . ! -name . -prune"))
    }

    func testRemoteListingCommandHandlesMacOSAndUnusualNames() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        let unusual = root.appendingPathComponent("quote's\nnotes.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("notes".utf8).write(to: unusual)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            DeviceFileService.remoteListingCommand(path: root.path),
        ]
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(
                data: errorOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
        let entries = try DeviceFileService.parseRemoteListing(
            output.fileHandleForReading.readDataToEndOfFile(),
            directory: root.path
        )
        XCTAssertEqual(
            entries.map(\.name).sorted(),
            ["Folder", "quote's\nnotes.txt"].sorted()
        )
        XCTAssertEqual(entries.first(where: { $0.name == "Folder" })?.kind, .directory)
        XCTAssertEqual(
            entries.first(where: { $0.name == "quote's\nnotes.txt" })?.kind,
            .regularFile
        )
    }

    func testRemoteUploadStreamsBytesToAtomicTemporaryDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-ssh")
        let captured = root.appendingPathComponent("captured")
        let arguments = root.appendingPathComponent("arguments")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(HerdrService.shellQuoted(arguments.path))
        case "$*" in
          *"if [ -e "*) printf 0 ;;
          *) cat > \(HerdrService.shellQuoted(captured.path)) ;;
        esac
        """
        try makeExecutable(script, at: executable)
        let source = root.appendingPathComponent("design's notes.txt")
        let payload = Data([0x00, 0x0A, 0x42, 0xFF])
        try payload.write(to: source)

        let device = Device(name: "Remote", kind: .ssh(target: "user@example.test"))
        let service = DeviceFileService(device: device, sshExecutableURL: executable)
        let destination = try await service.uploadFile(
            from: source,
            toDirectory: "/srv/project"
        )

        XCTAssertEqual(destination, "/srv/project/design's notes.txt")
        XCTAssertEqual(try Data(contentsOf: captured), payload)
        let capturedArguments = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertTrue(capturedArguments.contains(".part"))
        XCTAssertTrue(capturedArguments.contains("trap"))
        XCTAssertTrue(capturedArguments.contains("ln"))
        XCTAssertTrue(capturedArguments.contains("design"))
        XCTAssertTrue(capturedArguments.contains("notes.txt"))
    }

    func testRemoteDownloadStagesThenAtomicallyInstallsFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-ssh")
        let payload = "remote payload"
        let script = """
        #!/bin/sh
        case "$*" in
          *"wc -c"*) printf \(payload.utf8.count) ;;
          *) printf '%s' \(HerdrService.shellQuoted(payload)) ;;
        esac
        """
        try makeExecutable(script, at: executable)
        let destinationDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)

        let device = Device(name: "Remote", kind: .ssh(target: "user@example.test"))
        let service = DeviceFileService(device: device, sshExecutableURL: executable)
        let result = try await service.downloadFile(
            at: "/srv/project/result.txt",
            toLocalDirectory: destinationDirectory
        )

        XCTAssertEqual(result.lastPathComponent, "result.txt")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), payload)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
                .contains(where: { $0.contains(".herdrm-") })
        )
    }

    func testCancellingRemoteDownloadRemovesPartialFile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-ssh")
        let script = """
        #!/bin/sh
        case "$*" in
          *"wc -c"*) printf 100 ;;
          *) exec sleep 10 ;;
        esac
        """
        try makeExecutable(script, at: executable)
        let destinationDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)

        let device = Device(name: "Remote", kind: .ssh(target: "user@example.test"))
        let service = DeviceFileService(device: device, sshExecutableURL: executable)
        let transfer = Task {
            try await service.downloadFile(
                at: "/srv/project/result.txt",
                toLocalDirectory: destinationDirectory
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        transfer.cancel()

        do {
            _ = try await transfer.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDirectory.appendingPathComponent("result.txt").path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
                .contains(where: { $0.contains(".herdrm-") })
        )
    }

    func testKeepBothNamePreservesExtension() {
        XCTAssertEqual(DeviceFileService.keepBothName("archive.tar.gz", index: 2), "archive.tar 2.gz")
        XCTAssertEqual(DeviceFileService.keepBothName("README", index: 3), "README 3")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
