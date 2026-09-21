import GhosttyTerminal
import XCTest
@testable import herdrm

@MainActor
final class TerminalLinkOpeningTests: XCTestCase {
    func testWebAndMailSchemesAreCaseInsensitive() {
        for string in ["http://example.com", "HTTPS://example.com/a", "MAILTO:user@example.com"] {
            XCTAssertNotNil(LineBreakTerminalView.clickedLinkURL(string), string)
        }
    }

    func testProducerControlledTargetsCannotLaunchFilesOrApplications() {
        for string in ["file:///etc/passwd", "javascript:alert(1)", "herdrm://open", "ssh://host",
                       "relative/path", "//example.com", "", "://broken", "https://["] {
            XCTAssertNil(LineBreakTerminalView.clickedLinkURL(string), string)
        }
    }

    func testBothCoordinatorsDeliverAllowedURLsExactlyOnceForEveryLinkKind() {
        var opened: [URL] = []
        let delegates: [any TerminalSurfaceOpenURLDelegate] = [
            AttachTerminalView.Coordinator(linkOpener: { opened.append($0) }),
            ShellTerminalView.Coordinator(linkOpener: { opened.append($0) }),
        ]
        for delegate in delegates {
            for kind: TerminalOpenURLKind in [.unknown, .text, .html] {
                for target in ["http://example.com", "HTTPS://example.com/a", "MAILTO:user@example.com"] {
                    opened.removeAll()
                    delegate.terminalDidRequestOpenURL(target, kind: kind)
                    XCTAssertEqual(opened, [URL(string: target)!], "\(type(of: delegate)), \(kind), \(target)")
                }
            }
        }
    }

    func testBothCoordinatorsRejectUnsafeURLsWithoutCallingTheOpener() {
        var opened: [URL] = []
        let delegates: [any TerminalSurfaceOpenURLDelegate] = [
            AttachTerminalView.Coordinator(linkOpener: { opened.append($0) }),
            ShellTerminalView.Coordinator(linkOpener: { opened.append($0) }),
        ]
        for delegate in delegates {
            for kind: TerminalOpenURLKind in [.unknown, .text, .html] {
                for target in ["file:///etc/passwd", "javascript:alert(1)", "herdrm://open", "ssh://host",
                               "relative/path", "//example.com", "", "://broken", "https://["] {
                    delegate.terminalDidRequestOpenURL(target, kind: kind)
                    XCTAssertTrue(opened.isEmpty, "\(type(of: delegate)), \(kind), \(target)")
                }
            }
        }
    }
}
