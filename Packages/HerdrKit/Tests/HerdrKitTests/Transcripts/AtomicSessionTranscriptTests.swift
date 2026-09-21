import Foundation
import XCTest
@testable import HerdrKit

final class AtomicSessionTranscriptTests: XCTestCase {
    private let lines = [
        #"{"type":"session","version":3,"id":"s1","timestamp":"2026-09-07T12:03:07.173Z","cwd":"/Users/me/dev/app"}"#,
        #"{"type":"model_change","id":"m0","parentId":null,"timestamp":"t","provider":"anthropic","modelId":"x"}"#,
        #"{"type":"message","id":"u1","parentId":"m0","timestamp":"t","message":{"role":"user","content":[{"type":"text","text":"fix the build"}]}}"#,
        #"{"type":"message","id":"a1","parentId":"u1","timestamp":"t","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Looking at it.\n"},{"type":"toolCall","id":"call1","name":"bash","arguments":{"command":"swift build\n2>&1"}},{"type":"toolCall","id":"call2","name":"read","arguments":{"path":"Package.swift"}}],"stopReason":"toolUse"}}"#,
        #"{"type":"message","id":"r1","parentId":"a1","timestamp":"t","message":{"role":"toolResult","toolCallId":"call1","toolName":"bash","content":[{"type":"text","text":"error: boom"}],"isError":true}}"#,
    ]

    func testParsesUserAssistantAndToolRows() {
        var parser = AtomicSessionTranscriptParser()
        parser.append(Data((lines.joined(separator: "\n") + "\n").utf8))

        XCTAssertEqual(parser.sessionCwd, "/Users/me/dev/app")
        XCTAssertEqual(parser.items.count, 2)

        let user = parser.items[0]
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.blocks, [.markdown("fix the build")])

        let assistant = parser.items[1]
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.blocks.count, 3)
        XCTAssertEqual(assistant.blocks[0], .markdown("Looking at it."))
        XCTAssertEqual(
            assistant.blocks[1],
            .tool(name: "bash", status: .failed, detail: "swift build\nerror: boom")
        )
        XCTAssertEqual(
            assistant.blocks[2],
            .tool(name: "read", status: .running, detail: "Package.swift")
        )
        XCTAssertTrue(parser.hasRunningTools, "call2 has no result yet")
    }

    func testPartialLinesWaitForTheNextChunk() {
        var parser = AtomicSessionTranscriptParser()
        let joined = lines.joined(separator: "\n") + "\n"
        let bytes = Array(joined.utf8)
        let cut = bytes.count / 2
        parser.append(Data(bytes[..<cut]))
        let afterFirstChunk = parser.items.count
        parser.append(Data(bytes[cut...]))

        XCTAssertLessThanOrEqual(afterFirstChunk, 2)
        XCTAssertEqual(parser.items.count, 2)
        XCTAssertEqual(parser.sequence, UInt64(lines.count))
    }

    func testBashExecutionAndDisplayedCustomMessages() {
        var parser = AtomicSessionTranscriptParser()
        parser.append(Data((
            #"{"type":"message","id":"b1","parentId":null,"timestamp":"t","message":{"role":"bashExecution","command":"ls","output":"a\nb","exitCode":0,"cancelled":false,"truncated":false}}"# + "\n"
            + #"{"type":"message","id":"c1","parentId":"b1","timestamp":"t","message":{"role":"custom","customType":"x","content":"Compacted context","display":true}}"# + "\n"
            + #"{"type":"message","id":"c2","parentId":"c1","timestamp":"t","message":{"role":"custom","customType":"x","content":"hidden","display":false}}"# + "\n"
        ).utf8))

        XCTAssertEqual(parser.items.map(\.role), [.tool, .system])
        XCTAssertEqual(parser.items[0].blocks, [.tool(name: "bash", status: .succeeded, detail: "ls\na\nb")])
        XCTAssertEqual(parser.items[1].blocks, [.notice("Compacted context")])
    }

    func testFileRangeShellOutputRoundTrip() throws {
        let payload = Data("12\nhello world\n".utf8)
        let read = try FileRangeRead.parse(payload)
        XCTAssertEqual(read.totalSize, 12)
        XCTAssertEqual(read.data, Data("hello world\n".utf8))

        XCTAssertTrue(FileRangeRead.isAllowedSessionPath("/Users/me/.atomic/agent/sessions/--x--/a.jsonl"))
        XCTAssertFalse(FileRangeRead.isAllowedSessionPath("/Users/me/.ssh/id_ed25519"))
        XCTAssertFalse(FileRangeRead.isAllowedSessionPath("/Users/me/.atomic/agent/sessions/../../.ssh/x.jsonl"))
    }

    func testAgentInfoDecodesSessionPath() throws {
        let json = #"{"agent":"pi","agent_session":{"agent":"pi","kind":"path","source":"herdr:pi","value":"/Users/me/.atomic/agent/sessions/--x--/a.jsonl"},"agent_status":"idle","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1"}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.agentSessionPath, "/Users/me/.atomic/agent/sessions/--x--/a.jsonl")
    }
}

final class FileRangeTailWindowTests: XCTestCase {
    func testNegativeOffsetReadsTailWindowLocally() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        try Data("0123456789".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = try FileRangeRead.readLocal(path: url.path, offset: -4, limit: 100)
        XCTAssertEqual(tail.totalSize, 10)
        XCTAssertEqual(String(decoding: tail.data, as: UTF8.self), "6789")
        XCTAssertEqual(FileRangeRead.startOffset(offset: -4, totalSize: 10), 6)
        XCTAssertEqual(FileRangeRead.startOffset(offset: -40, totalSize: 10), 0)

        let rest = try FileRangeRead.readLocal(path: url.path, offset: 10, limit: 100)
        XCTAssertTrue(rest.data.isEmpty)
        XCTAssertEqual(rest.totalSize, 10)
    }

    func testShellCommandUsesTailForNegativeOffset() {
        let command = FileRangeRead.shellCommand(path: "/tmp/a b.jsonl", offset: -512, limit: 1024)
        XCTAssertTrue(command.contains("tail -c 512 \"$f\" | head -c 1024"))
        XCTAssertTrue(command.contains("'/tmp/a b.jsonl'"))
        let forward = FileRangeRead.shellCommand(path: "/tmp/a.jsonl", offset: 99, limit: 7)
        XCTAssertTrue(forward.contains("tail -c +100 \"$f\" | head -c 7"))
    }
}
