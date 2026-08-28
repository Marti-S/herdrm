import AppKit
import SwiftUI

enum SidebarContextMenuItem {
    case item(title: String, action: () -> Void)
    case destructive(title: String, action: () -> Void)
    case separator
}

/// AppKit drag/drop host. SwiftUI `.onDrag` on macOS does not start when a
/// `Button` (or even `onTapGesture`) owns mouseDown; a few points of movement
/// here begin an `NSDraggingSession` instead.
struct SidebarRowDragHost: NSViewRepresentable {
    let entryID: String
    let pasteboardType: NSPasteboard.PasteboardType
    let menuItems: [SidebarContextMenuItem]
    let onClick: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    func makeNSView(context: Context) -> SidebarRowDragNSView {
        // Non-zero seed frame: a SwiftUI overlay NSView that starts at .zero
        // can stay 0-size, so clicks and drags never arrive (#42).
        let view = SidebarRowDragNSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.pasteboardType = pasteboardType
        view.registerForDraggedTypes([pasteboardType])
        return view
    }

    func updateNSView(_ view: SidebarRowDragNSView, context: Context) {
        if view.pasteboardType != pasteboardType {
            view.unregisterDraggedTypes()
            view.pasteboardType = pasteboardType
            view.registerForDraggedTypes([pasteboardType])
        }
        view.entryID = entryID
        view.menuItems = menuItems
        view.onClick = onClick
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onDropHover = onDropHover
        view.onHoverExit = onHoverExit
        view.onDrop = onDrop
    }
}

struct SpaceRowDragHost: View {
    let entryID: String
    let label: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.spacePasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Space…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Space \"\(label)\"…"), action: onClose),
            ],
            onClick: onClick,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

struct AgentRowDragHost: View {
    let entryID: String
    let onClick: () -> Void
    let onRename: () -> Void
    let onClose: () -> Void
    let onDragStart: (String) -> Void
    let onDragEnd: () -> Void
    let onDropHover: (Bool) -> Void
    let onHoverExit: () -> Void
    let onDrop: (String, Bool) -> Void

    var body: some View {
        SidebarRowDragHost(
            entryID: entryID,
            pasteboardType: SidebarRowDragNSView.agentPasteboardType,
            menuItems: [
                .item(title: String(localized: "Rename Agent…"), action: onRename),
                .separator,
                .destructive(title: String(localized: "Close Agent…"), action: onClose),
            ],
            onClick: onClick,
            onDragStart: onDragStart,
            onDragEnd: onDragEnd,
            onDropHover: onDropHover,
            onHoverExit: onHoverExit,
            onDrop: onDrop
        )
    }
}

final class SidebarRowDragNSView: NSView, NSDraggingSource {
    static let spacePasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.space-id")
    static let agentPasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.agent-id")

    var pasteboardType = SidebarRowDragNSView.spacePasteboardType
    var entryID = ""
    var menuItems: [SidebarContextMenuItem] = []
    var onClick: (() -> Void)?
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?

    private var downEvent: NSEvent?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Explicit hit-test so a 0-size overlay cannot silently drop clicks.
        // AppKit passes the point in the superview's coordinate space.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !didDrag else { return }
        let start = convert(down.locationInWindow, from: nil)
        let now = convert(event.locationInWindow, from: nil)
        guard hypot(now.x - start.x, now.y - start.y) >= 4 else { return }
        didDrag = true
        onDragStart?(entryID)
        let pbItem = NSPasteboardItem()
        pbItem.setString(entryID, forType: pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pbItem)
        item.setDraggingFrame(bounds, contents: nil)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onClick?() }
        downEvent = nil
        didDrag = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for item in menuItems {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case .item(let title, let action):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = MenuAction(action)
            case .destructive(let title, let action):
                let menuItem = menu.addItem(withTitle: title, action: #selector(runMenuItem(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = MenuAction(action)
            }
        }
        return menu
    }

    @objc private func runMenuItem(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnd?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(from: sender) != nil else { return [] }
        onDropHover?(placeAfter(sender))
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedID(from: sender) != nil else { return [] }
        onDropHover?(placeAfter(sender))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHoverExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        draggedID(from: sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let sourceID = draggedID(from: sender) else { return false }
        let after = placeAfter(sender)
        onDrop?(sourceID, after)
        return true
    }

    private func placeAfter(_ sender: NSDraggingInfo) -> Bool {
        convert(sender.draggingLocation, from: nil).y > bounds.midY
    }

    private func draggedID(from sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: pasteboardType)
    }
}

/// NSMenu `representedObject` must be an object; a closure is not.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
