import XCTest
@testable import herdrm

final class AppLanguageTests: XCTestCase {
    func testRelaunchHelperWaitsForThisPidThenOpensTheQuotedBundle() {
        let command = AppLanguage.relaunchHelperCommand(
            pid: 42,
            bundlePath: "/Applications/O'Brien/herdrm.app"
        )
        XCTAssertEqual(
            command,
            "while /bin/kill -0 42 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open '/Applications/O'\\''Brien/herdrm.app'"
        )
    }

    func testFollowSystemDoesNotRelaunchWhenTheMacIsAlreadyEnglish() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.system, running: "en", systemLanguages: ["en-US", "zh-Hans-CN"])
        )
    }

    func testExplicitEnglishDoesNotRelaunchWhenAlreadyRunningEnglish() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.english, running: "en", systemLanguages: ["zh-Hans-CN"])
        )
    }

    func testFollowSystemRelaunchesWhenTheMacIsChineseAndTheUIIsEnglish() {
        XCTAssertTrue(
            AppLanguage.needsRelaunch(.system, running: "en", systemLanguages: ["zh-Hans-CN"])
        )
    }

    func testChineseRelaunchesWhenTheUIIsEnglish() {
        XCTAssertTrue(
            AppLanguage.needsRelaunch(.simplifiedChinese, running: "en", systemLanguages: ["en-US"])
        )
    }

    func testFollowSystemDoesNotRelaunchWhenTheMacIsAlreadyChinese() {
        XCTAssertFalse(
            AppLanguage.needsRelaunch(.system, running: "zh-Hans", systemLanguages: ["zh-Hans-CN"])
        )
    }

    func testFollowSystemRemovesOnlyTheAppOverride() throws {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("kept", forKey: "unrelated")
        AppLanguage.apply(.simplifiedChinese, defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["zh-Hans"])
        AppLanguage.apply(.system, defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "kept")
        XCTAssertEqual(AppLanguage.current(defaults: defaults), .system)
    }

    func testReturningToRunningLanguageHidesRelaunch() {
        XCTAssertTrue(AppLanguage.needsRelaunch(.simplifiedChinese, running: "en-GB", systemLanguages: ["en-US"]))
        XCTAssertFalse(AppLanguage.needsRelaunch(.english, running: "en-GB", systemLanguages: ["en-US"]))
        XCTAssertFalse(AppLanguage.needsRelaunch(.system, running: "en-GB", systemLanguages: ["en-US"]))
    }

    func testRegionalAndUnsupportedLanguagesResolveToBundledStrings() {
        XCTAssertEqual(AppLanguage.canonicalize("en-GB"), "en")
        XCTAssertEqual(AppLanguage.canonicalize("zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(AppLanguage.effectiveCode(for: .system, systemLanguages: ["fr-FR"]), "en")
    }

    @MainActor
    func testFailedRelaunchHelperReportsManualRecoveryWithoutTermination() {
        var terminated = false
        var reported = false
        AppLanguage.relaunch(spawnHelper: { nil }, terminate: { terminated = true }, reportFailure: { reported = true })
        XCTAssertTrue(reported)
        XCTAssertFalse(terminated)
    }

    @MainActor
    func testSuccessfulRelaunchHelperUsesTheNormalTerminationPath() {
        var terminated = false
        var reported = false
        AppLanguage.relaunch(spawnHelper: { 42 }, terminate: { terminated = true }, reportFailure: { reported = true })
        XCTAssertTrue(terminated)
        XCTAssertFalse(reported)
    }
}
