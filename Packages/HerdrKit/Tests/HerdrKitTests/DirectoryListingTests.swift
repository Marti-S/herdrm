import XCTest
@testable import HerdrKit

/// Local-device coverage for the New Space directory browser; every path lives in a
/// per-test temp directory. The SSH side reuses `runSSH` and is exercised by the
/// remote E2E suite.
final class DirectoryListingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hk-ls-\(UUID().uuidString.prefix(8))", isDirectory: true)
        for name in ["beta", "Alpha", ".hidden"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: root.appendingPathComponent("beta")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeLocalService() -> HerdrService {
        HerdrService(device: Device(name: "Test", kind: .local), localServer: nil)
    }

    func testListsOnlyVisibleDirectoriesSortedLikeFinder() async throws {
        let names = try await makeLocalService().listDirectories(at: root.path)
        // Files and dotfolders stay out; a symlinked directory still counts.
        XCTAssertEqual(names, ["Alpha", "beta", "linked"])
    }

    func testUnreadableDirectoryThrows() async {
        do {
            _ = try await makeLocalService().listDirectories(at: root.path + "/nope")
            XCTFail("expected a throw for a missing directory")
        } catch {}
    }

    func testTildeResolvesAgainstTheDeviceHome() async throws {
        let service = makeLocalService()
        let home = NSHomeDirectory()
        let bare = try await service.absolutePath("~")
        let nested = try await service.absolutePath("~/Projects/foo")
        let absolute = try await service.absolutePath("/opt/data")
        XCTAssertEqual(bare, home)
        XCTAssertEqual(nested, "\(home)/Projects/foo")
        XCTAssertEqual(absolute, "/opt/data")
    }

    func testShellQuotedSurvivesTheAwkwardCharacters() {
        XCTAssertEqual(HerdrService.shellQuoted("/plain/path"), "'/plain/path'")
        XCTAssertEqual(HerdrService.shellQuoted("/it's here"), "'/it'\\''s here'")
        // Single quotes keep $HOME and backticks literal; no escaping needed inside.
        XCTAssertEqual(HerdrService.shellQuoted("/a $HOME `b`"), "'/a $HOME `b`'")
    }
}
