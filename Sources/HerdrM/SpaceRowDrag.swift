import AppKit
import SwiftUI

/// AppKit drag/drop host. SwiftUI `.onDrag` on macOS does not start when a
/// `Button` (or even `onTapGesture`) owns mouseDown; a few points of movement
/// here begin an `NSDraggingSession` instead.
struct SpaceRowDragHost: NSViewRepresentable {
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

    func makeNSView(context: Context) -> SpaceRowDragNSView {
        SpaceRowDragNSView()
    }

    func updateNSView(_ view: SpaceRowDragNSView, context: Context) {
        view.entryID = entryID
        view.label = label
        view.onClick = onClick
        view.onRename = onRename
        view.onClose = onClose
        view.onDragStart = onDragStart
        view.onDragEnd = onDragEnd
        view.onDropHover = onDropHover
        view.onHoverExit = onHoverExit
        view.onDrop = onDrop
    }
}

final class SpaceRowDragNSView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("dev.bybee.herdrm.space-id")

    var entryID = ""
    var label = ""
    var onClick: (() -> Void)?
    var onRename: (() -> Void)?
    var onClose: (() -> Void)?
    var onDragStart: ((String) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDropHover: ((Bool) -> Void)?
    var onHoverExit: (() -> Void)?
    var onDrop: ((String, Bool) -> Void)?

    private var downEvent: NSEvent?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.pasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.pasteboardType])
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

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
        pbItem.setString(entryID, forType: Self.pasteboardType)
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
        let rename = menu.addItem(
            withTitle: String(localized: "Rename Space…"),
            action: #selector(renameSpace),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(.separator())
        let close = menu.addItem(
            withTitle: String(localized: "Close Space \"\(label)\"…"),
            action: #selector(closeSpace),
            keyEquivalent: ""
        )
        close.target = self
        return menu
    }

    @objc private func renameSpace() { onRename?() }
    @objc private func closeSpace() { onClose?() }

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
        sender.draggingPasteboard.string(forType: Self.pasteboardType)
    }
}
