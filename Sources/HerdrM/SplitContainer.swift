import AppKit
import SwiftUI

/// A two-pane split with a draggable divider and a persisted ratio. `axis == nil` shows
/// `first()` filling the whole area; the second pane and the divider are what come and go.
///
/// The `GeometryReader` and the layout are present in every state on purpose, and the axis
/// is switched with `AnyLayout` rather than by branching. Do not "simplify" this into
/// `if axis != nil { … } else { first() }`: SwiftUI does not preserve identity across a
/// `_ConditionalContent` branch swap, so `first()` would be destroyed and rebuilt on every
/// split — which killed the agent's attach process and relaunched it with `--takeover`.
struct SplitContainer<First: View, Second: View>: View {
    let axis: SplitAxis?
    @Binding var ratio: Double
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    /// The ratio when the current drag began. `DragGesture.translation` is a delta,
    /// so the divider follows the mouse from wherever it was; `location` would be
    /// measured against the divider's own origin, not the container's, and make the
    /// divider jump on mouse-down.
    @State private var dragStartRatio: Double?

    var body: some View {
        // One structural position for first()/second(), always. Putting first() in two
        // branches of a conditional made SwiftUI destroy and rebuild it on every split:
        // identity does not survive a _ConditionalContent branch swap, .id() included, so
        // the agent's attach process was killed and relaunched with --takeover. AnyLayout
        // swaps the axis without touching child identity.
        GeometryReader { proxy in
            let total = axis == .vertical ? proxy.size.width : proxy.size.height
            let firstLength = total * SplitContainerRatioBounds.clamp(ratio)
            let layout = axis == .horizontal
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 0))
            layout {
                first()
                    .frame(
                        width: axis == .vertical ? firstLength : nil,
                        height: axis == .horizontal ? firstLength : nil
                    )
                if let axis {
                    divider(axis: axis, total: total)
                    second()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A gesture cancelled without onEnded leaves a stale anchor;
            // clearing on axis change covers the case that shows.
            .onChange(of: axis) { _, _ in dragStartRatio = nil }
        }
    }

    private func divider(axis: SplitAxis, total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
            .overlay(
                Rectangle()
                    .fill(.clear)
                    .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard total > 0 else { return }
                                let start = dragStartRatio ?? SplitContainerRatioBounds.clamp(ratio)
                                if dragStartRatio == nil { dragStartRatio = start }
                                let travelled = axis == .vertical
                                    ? value.translation.width
                                    : value.translation.height
                                ratio = SplitContainerRatioBounds.clamp(start + travelled / total)
                            }
                            .onEnded { _ in dragStartRatio = nil }
                    )
                    // set() instead of push()/pop(): closing the split with the
                    // pointer over the divider never delivers onHover(false), and an
                    // unbalanced push leaves the resize cursor stuck app-wide.
                    .onHover { hovering in
                        if hovering {
                            (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
            )
    }
}

private enum SplitContainerRatioBounds {
    static let bounds = 0.2...0.8

    static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, bounds.lowerBound), bounds.upperBound)
    }
}
