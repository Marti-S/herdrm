import Foundation
import XCTest
@testable import HerdrKit

final class TerminalTranscriptPerformanceTests: XCTestCase {
    private func read(_ text: String, revision: UInt64 = 1, pane: String = "pane") -> TerminalReadResult {
        TerminalReadResult(paneID: pane, workspaceID: "workspace", tabID: "tab",
                           source: .recentUnwrapped, format: .text, text: text,
                           revision: revision, truncated: false)
    }

    func testUTF8PatchesRoundTripRedrawsAndSlidingHistory() throws {
        let fixtures = ["", "a", "ab", "a\nb", "progress 10%\rprogress 20%", "😀", "😁", "é", "e\u{301}",
                        "中文\n第二行", "👨‍👩‍👧‍👦", "\n\n", "old\nretained\n", "retained\nnew\n"]
        for old in fixtures {
            for new in fixtures {
                XCTAssertEqual(try TerminalTextPatch(from: old, to: new).applying(to: old), new)
            }
        }
    }

    func testRandomUnicodePatchesRoundTrip() throws {
        // Deterministic pseudo-random fixtures: repeatable without an external fuzzing dependency.
        var seed: UInt64 = 0xCAFE
        let alphabet = ["a", "\n", "😀", "😁", "中", "\u{301}", "é", "\r", " ", "👩‍💻"]
        func next() -> UInt64 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return seed
        }
        func text() -> String {
            (0..<Int(next() % 60)).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }.joined()
        }
        for _ in 0..<1_000 {
            let old = text(), new = text()
            XCTAssertEqual(try TerminalTextPatch(from: old, to: new).applying(to: old), new)
        }
    }

    func testInvalidPatchOffsetsFailRatherThanCorruptText() throws {
        for (prefix, removed) in [(-1, 0), (99, 0), (0, 99), (1, 0), (0, 1)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "prefixBytes": prefix, "removedBytes": removed, "insertedText": "x"
            ])
            let patch = try JSONDecoder().decode(TerminalTextPatch.self, from: data)
            XCTAssertThrowsError(try patch.applying(to: "😀"))
        }
    }

    func testSubscriptionAppliesPatchesAndIgnoresDuplicateDelivery() throws {
        let before = read(String(repeating: "history\n", count: 100))
        let after = read(before.text + "new 😀 output", revision: 2)
        let initial = TerminalTranscriptUpdate(sequence: 1, read: before)
        let update = TerminalTranscriptUpdate(sequence: 2, baseSequence: 1, previous: before, next: after)
        XCTAssertNotNil(update.patch)
        XCTAssertLessThan(try JSONEncoder().encode(update).count, try JSONEncoder().encode(after).count)
        var accumulator = TerminalTranscriptAccumulator()
        XCTAssertEqual(try accumulator.apply(initial), before)
        XCTAssertEqual(try accumulator.apply(update), after)
        XCTAssertEqual(try accumulator.apply(update), after)
        XCTAssertEqual(try accumulator.apply(initial), after)
    }

    func testMissingBaseAndSequenceGapAreRejected() throws {
        let before = read(String(repeating: "history\n", count: 100))
        let after = read(before.text + "new", revision: 2)
        let patch = TerminalTranscriptUpdate(sequence: 3, baseSequence: 2, previous: before, next: after)
        var accumulator = TerminalTranscriptAccumulator()
        XCTAssertThrowsError(try accumulator.apply(patch)) { error in
            XCTAssertEqual(error as? TerminalTranscriptUpdateError, .missingSnapshot)
        }
        try accumulator.apply(TerminalTranscriptUpdate(sequence: 1, read: before))
        XCTAssertThrowsError(try accumulator.apply(patch)) { error in
            XCTAssertEqual(error as? TerminalTranscriptUpdateError, .sequenceGap)
        }
        // An authoritative full snapshot can resynchronize without an append approximation.
        XCTAssertEqual(try accumulator.apply(TerminalTranscriptUpdate(sequence: 4, read: after)), after)
    }

    func testMetadataChangeUsesAuthoritativeSnapshot() {
        let before = read(String(repeating: "same", count: 100), pane: "old")
        let after = read(before.text, pane: "new")
        let update = TerminalTranscriptUpdate(sequence: 2, baseSequence: 1, previous: before, next: after)
        XCTAssertEqual(update.read, after)
        XCTAssertNil(update.patch)
    }

    func testChunkedRowsPreserveTextAndStablePrefixIdentity() {
        let text = (0..<30).map { "Line \($0) 😀" }.joined(separator: "\n") + "\n"
        let first = TerminalTranscriptItems.make(text: text, providerID: "pane")
        let second = TerminalTranscriptItems.make(text: text + "next", providerID: "pane")
        XCTAssertEqual(first.dropLast().map(\.id), second.dropLast().map(\.id))
        let reconstructed = first.map { item -> String in
            guard case .terminalText(let text) = item.blocks[0] else { return "invalid" }
            XCTAssertLessThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 12)
            XCTAssertEqual(item.role, .terminal)
            return text
        }.joined(separator: "\n")
        XCTAssertEqual(reconstructed, text)
    }

    func testRepeatedChunksHaveDistinctIDsAndEmptyTextHasNoRows() {
        let items = TerminalTranscriptItems.make(text: "same\nsame\nsame", providerID: "pane", maximumLinesPerItem: 1)
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
        XCTAssertTrue(TerminalTranscriptItems.make(text: "", providerID: "pane").isEmpty)
    }
}
