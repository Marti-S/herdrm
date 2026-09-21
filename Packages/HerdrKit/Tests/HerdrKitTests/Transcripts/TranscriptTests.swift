import Foundation
import XCTest
@testable import HerdrKit

final class TranscriptTests: XCTestCase {
    func testPaneReadResultDecodesTypedWirePayload() throws {
        let data = Data(#"""
        {
          "pane_id": "w1:p2",
          "workspace_id": "w1",
          "tab_id": "w1:t1",
          "source": "recent_unwrapped",
          "format": "text",
          "text": "one\ntwo\n",
          "revision": 42,
          "truncated": true
        }
        """#.utf8)

        let result = try JSONDecoder().decode(TerminalReadResult.self, from: data)
        XCTAssertEqual(result.paneID, "w1:p2")
        XCTAssertEqual(result.source, .recentUnwrapped)
        XCTAssertEqual(result.format, .text)
        XCTAssertEqual(result.revision, 42)
        XCTAssertTrue(result.truncated)
    }

    func testTranscriptReducerPreservesStableItemIdentity() {
        let item = ConversationItem(
            id: "assistant-1",
            sequence: 1,
            role: .assistant,
            blocks: [.markdown("Hello")],
            state: .streaming
        )
        let initial = TranscriptSnapshot(
            providerID: "test",
            source: .semantic,
            sequence: 1,
            items: [item]
        )

        let streamed = initial.applying(
            .blockDelta(
                sequence: 2,
                itemID: "assistant-1",
                blockIndex: 0,
                text: " world"
            )
        )
        let completed = streamed.applying(
            .itemCompleted(sequence: 3, itemID: "assistant-1")
        )

        XCTAssertEqual(completed.items.map(\.id), ["assistant-1"])
        XCTAssertEqual(completed.items.first?.blocks, [.markdown("Hello world")])
        XCTAssertEqual(completed.items.first?.state, .complete)
        XCTAssertEqual(completed.sequence, 3)
    }

    func testTerminalDerivedRowsRemainExplicitlyNonSemantic() {
        let item = ConversationItem(
            id: "pane:terminal",
            sequence: 7,
            role: .terminal,
            blocks: [.terminalText("rendered terminal output")],
            state: .complete
        )
        let snapshot = TranscriptSnapshot(
            providerID: "pane",
            source: .terminalRecentUnwrapped,
            sequence: 7,
            items: [item]
        )

        XCTAssertEqual(snapshot.source, .terminalRecentUnwrapped)
        XCTAssertEqual(snapshot.items.first?.role, .terminal)
    }
}
