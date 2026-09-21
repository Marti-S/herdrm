import Foundation
import HerdrKit

enum MobileAttach {
    static let pathExport = #"export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin""#

    static let bootstrapMarker =
        Data([0x1B, 0x5F]) + Data("herdrm-attach".utf8) + Data([0x1B, 0x5C])
    private static let markerPrintf = #"printf '\033_herdrm-attach\033\\'"#

    static func structuredCommand(
        target: TerminalAttachTarget,
        mode: TerminalSessionMode,
        size: TerminalSize
    ) -> String {
        let targetValue: String
        switch target {
        case .agent(let paneID):
            targetValue = paneID
        case .terminal(let terminalID):
            targetValue = terminalID
        }

        let action: String
        switch mode.access {
        case .observe:
            action = "observe"
        case .control:
            action = "control"
        }
        let takeoverFlag = mode.takeover ? " --takeover" : ""
        let sessionCommand = "herdr terminal session \(action) "
            + ShellQuoting.quoted(targetValue)
            + takeoverFlag
            + " --cols \(size.columns) --rows \(size.rows)"
        let script = "\(pathExport); "
            + "stty -echo -icanon -opost min 1 time 0; "
            + "\(markerPrintf); exec \(sessionCommand)"
        return "/bin/sh -c \(ShellQuoting.quoted(script))"
    }
}
