import Foundation
import HerdrKit

/// vertical = panes side by side with a vertical divider (iTerm2's convention).
enum SplitAxis { case vertical, horizontal }

/// Identifies one of the two panes in the Command-D split. Used for focus tracking and
/// keyboard-driven resize.
enum SplitSide { case agent, shell }

/// Holds a split shell's view without keeping it alive. The view hierarchy owns it,
/// and the runtime only needs it while it is on screen.
final class WeakTerminalViewBox {
    weak var view: LineBreakTerminalView?

    init(_ view: LineBreakTerminalView?) {
        self.view = view
    }
}

/// A standalone local or SSH shell shown as its own sidebar entry. It is app-owned,
/// outside any herdr space and not the Command-D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let device: Device
}
