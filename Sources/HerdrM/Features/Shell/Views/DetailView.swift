import AppKit
import HerdrKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var model: FleetStore
    @Binding var sidebarCollapsed: Bool
    @State private var hasOpenedFileManager = false

    var body: some View {
        VStack(spacing: 0) {
            titlebar
                .background(Theme.contentBackground)
                .zIndex(1)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            detailContent
                // Cmd+D is Space-scoped. Changing the selected pane restores only
                // that Space's sidecar shell; shells in other Spaces stay mounted.
                .onChange(of: model.attachedSpaceRef) { _, space in
                    model.activateSplitSession(for: space)
                    splitTracker.shellView = model.splitShellView
                }
                // Losing the selected agent tears the SplitContainer down without
                // resetting the axis, which would leave the same phantom split.
                //
                // Load-bearing beyond that: this is the ONLY thing that clears the axis
                // when the agent goes away. `dismantleNSView` nils the coordinator's
                // onExit before killing the shell, so the shell's own onExit never fires
                // on teardown. Remove this and "split open with no agent selected"
                // becomes reachable, which is a state a deferred focus request can be
                // armed into with nothing left in the tree to consume it.
                .onChange(of: model.selectedAttachedEntry?.id) { _, id in
                    if id == nil {
                        model.shellSplitAxis = nil
                        // The placeholder tore every kept-alive attach down along with
                        // the SplitContainer. Empty the session list and per-entry state
                        // so a later selection doesn't resurrect them all at once.
                        model.attachSessions = []
                        endedAttach = [:]
                        attachRetry = [:]
                    }
                }
                .onChange(of: model.isFileManagerActive) { _, active in
                    if active { hasOpenedFileManager = true }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
    }

    private var detailContent: some View {
        ZStack {
            terminal
                .clipped()
                .opacity(model.isFileManagerActive ? 0 : 1)
                .allowsHitTesting(!model.isFileManagerActive)
            if hasOpenedFileManager {
                DeviceFilesView(model: model)
                    .opacity(model.isFileManagerActive ? 1 : 0)
                    .allowsHitTesting(model.isFileManagerActive)
            }
        }
        .onAppear {
            if model.isFileManagerActive { hasOpenedFileManager = true }
        }
        // The kept-alive working set is bounded, and panes close, so entries leave
        // `attachSessions` on their own. Evict the per-entry state of everything no
        // longer mounted: a stale `endedAttach` would otherwise put a dead terminal's
        // reconnect overlay back over a freshly reopened pane with the same id.
        .onChange(of: model.attachSessions.map(\.id)) { _, ids in
            let live = Set(ids)
            endedAttach = endedAttach.filter { live.contains($0.key) }
            attachRetry = attachRetry.filter { live.contains($0.key) }
        }
    }

    // MARK: - Titlebar strip (28pt, traditional)

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarCollapsed {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", help: "Show Sidebar (⌘B)") {
                    sidebarCollapsed = false
                }
            }
            Group {
                if model.isFileManagerActive {
                    Image(systemName: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text("Files")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                } else if let shell = model.selectedShell {
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(shell.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(shell.device.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                } else if let attached = model.selectedAttachedEntry {
                    switch attached {
                    case .agent(let entry):
                        let agent = entry.agent
                        statusGlyph(agent.status)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help((agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        AgentKindBadge(kind: agent.agent)
                        Text("\u{b7}")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textGhost)
                        Text(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        if let branch = model.branchName(for: entry) {
                            Text("\u{b7}")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textGhost)
                            Text(branch)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .help(branch)
                        }
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                        statusPill(agent.status)
                    case .terminal(let entry):
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help((entry.pane.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                        Spacer(minLength: 12)
                        Text(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                        if model.showsRowDeviceBadges {
                            DeviceChip(device: entry.device)
                        }
                    }
                } else {
                    Text("No terminal selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
        .windowTitlebarInteraction()
        // The branch of the selected agent's worktree, polled while it is on screen.
        .task(id: selectedAgentBranchTaskID) {
            guard let entry = model.selectedEntry else { return }
            while !Task.isCancelled {
                await model.refreshBranch(for: entry)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var selectedAgentBranchTaskID: String {
        guard let entry = model.selectedEntry else { return "none" }
        return "\(entry.id)|\(entry.agent.cwd ?? "")"
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            SpinnerView(color: Theme.working).frame(width: 13, height: 13)
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            EmptyView()
        case .idle, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func statusPill(_ status: AgentStatus) -> some View {
        let label: String? = {
            switch status {
            case .working: return String(localized: "Working")
            case .blocked: return String(localized: "Needs input")
            case .done: return String(localized: "Done")
            case .idle, .unknown: return nil
            }
        }()
        if let label {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.statusColor(status))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Theme.statusColor(status).opacity(0.13), in: Capsule())
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var terminalMouseReporting = true
    @Environment(\.colorScheme) private var colorScheme
    /// Per-entry attach state, keyed by `AttachedEntry.id`. `endedAttach` holds the exit
    /// code of a dead attach (nil code = no status, e.g. killed by a signal); a present
    /// key drives that entry's reconnect overlay. `attachRetry` is a generation the
    /// Reconnect button bumps to rebuild just that one terminal. Per-entry so one dead
    /// terminal's overlay never covers another and Reconnect rebuilds only its own.
    @State private var endedAttach: [String: Int32?] = [:]
    @State private var attachRetry: [String: Int] = [:]
    /// Ids of the attaches with an upload in flight. Per-entry like `endedAttach`
    /// and `attachRetry`: several attaches stay mounted, so a background pane
    /// finishing its upload must not clear the selected pane's indicator.
    @State private var uploadingAttachment: Set<String> = []
    @State private var splitTracker = SplitFocusTracker()

    @ViewBuilder
    private var terminal: some View {
        ZStack {
            attachedTerminal
            // Standalone shells stay in the hierarchy while deselected: unlike a
            // herdr pane, an app-owned shell has no server side to reattach to,
            // so tearing the view down would kill whatever is running in it.
            ForEach(model.shellSessions) { session in
                ShellTerminalView(
                    sessionID: session.id,
                    device: session.device,
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    dark: colorScheme == .dark,
                    mouseReporting: terminalMouseReporting,
                    surfaceVisible: model.selectedShellID == session.id,
                    onExit: { _ in model.closeShellSession(session.id) }
                )
                    .id("shell-\(session.id)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    // Solid backdrop inside the opacity compositing group so
                    // glyph AA on Ghostty's non-opaque Metal layer stays crisp
                    // (see attachChild) instead of rendering pale.
                    .background(Theme.terminalBackground)
                    .opacity(model.selectedShellID == session.id ? 1 : 0)
                    .allowsHitTesting(model.selectedShellID == session.id)
                    .accessibilityHidden(model.selectedShellID != session.id)
            }
        }
        .background(Theme.terminalBackground)
    }

    @ViewBuilder
    private var attachedTerminal: some View {
        if let entry = model.selectedAttachedEntry {
            SplitContainer(
                axis: model.shellSplitAxis,
                activeSide: model.activeSplitSide,
                ratio: $model.splitRatio
            ) {
                // One structural position holding every kept-alive attach. Each child
                // keeps a stable identity and is toggled by opacity, so switching the
                // selection — or opening/closing the split — never tears a terminal
                // down: its content survives the round trip. Do not key this on the
                // selection; that rebuild-on-switch is exactly what this removes.
                ZStack {
                    ForEach(model.attachSessions) { session in
                        attachChild(session, isSelected: session.id == entry.id)
                    }
                }
            } second: {
                splitShellTerminals
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment.contains(entry.id) { uploadIndicator }
            }
            .onAppear {
                // Single source of truth: the tracker writes straight into the model
                // instead of holding its own copy for a second onChange to mirror.
                splitTracker.onSideChanged = { model.activeSplitSide = $0 }
                // The ⌘D shell is per-Space, so the tracker's shell side follows the
                // Space the selection is in.
                model.activateSplitSession(for: model.attachedSpaceRef)
                splitTracker.shellView = model.splitShellView
                splitTracker.isAgentView = { view in
                    AttachViewRegistry.liveViews.contains { $0 === view }
                }
                splitTracker.start()
            }
            .onChange(of: entry.id) { _, newID in
                // A re-selected kept-alive view does not self-focus (makeNSView ran once
                // at creation), so hand it the keyboard explicitly — matching how every
                // selection used to focus the freshly built terminal.
                AttachViewRegistry.focus(newID)
            }
            // Keyed on the window becoming key rather than on a delay: that is the event
            // that follows the sheet's responder restore. Filtered to the terminal's own
            // window and consumed no matter which window it was, so a pending request can
            // never survive to a later, unrelated activation — coming back from ⌘Tab or
            // closing Settings would otherwise yank the keyboard into a live pane.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard model.pendingSplitAgentFocus else { return }
                model.pendingSplitAgentFocus = false
                guard let window = note.object as? NSWindow,
                      window === model.splitAgentView?.window
                else { return }
                focusTerminal(model.splitAgentView)
            }
            // Splitting moves the keyboard to the shell, so closing the split has to
            // hand it back — by ⌘W or by the shell exiting on its own. Reset the
            // tracked side to the agent so the next split starts predictably.
            .onChange(of: model.shellSplitAxis) { _, axis in
                if axis == nil {
                    model.activeSplitSide = .agent
                    model.pendingSplitAgentFocus = false
                    focusRemainingTerminal(preferring: model.splitAgentView)
                } else {
                    splitTracker.shellView = model.splitShellView
                }
            }
        } else {
            // The .onReceive below only exists on the branch above, so a request armed
            // while no pane is selected would have no consumer and would be cashed in by
            // some later activation. Revealing a pane that has since gone away lands here.
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
                Text(placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                if showsStartAgentShortcut {
                    Button("New Agent…") {
                        model.showNewAgent = true
                    }
                    .controlSize(.small)
                } else if model.hasReconnectableDevice {
                    Button("Reconnect") {
                        model.reconnectFailedDevices()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .onAppear { model.pendingSplitAgentFocus = false }
        }
    }

    /// One kept-alive attach. Stays in the hierarchy while deselected (opacity 0, no hit
    /// testing) so its content survives; the selected one is visible and interactive.
    @ViewBuilder
    private func attachChild(_ session: FleetStore.AttachedEntry, isSelected: Bool) -> some View {
        let attachmentCapabilities: AgentAttachmentCapabilities? = {
            guard case .agent(let agentEntry) = session else { return nil }
            return model.attachmentCapabilities(
                deviceID: agentEntry.device.id,
                agentKind: agentEntry.agent.agentKindRaw
            )
        }()
        ZStack {
            AttachTerminalView(
                device: session.device,
                target: session.attachTarget,
                sessionID: session.id,
                serverVersion: model.serverVersion(deviceID: session.device.id),
                attachmentCapabilities: attachmentCapabilities,
                fontName: terminalFontName,
                fontSize: terminalFontSize,
                thinStrokes: terminalThinStrokes,
                fontWeight: terminalFontWeight,
                lineSpacing: terminalLineSpacing,
                dark: colorScheme == .dark,
                mouseReporting: terminalMouseReporting,
                // A deselected child stays mounted and keeps draining its PTY, but
                // Ghostty stops rendering it: occluded surfaces release the display
                // link instead of drawing frames nobody can see.
                surfaceVisible: isSelected,
                onAttachmentError: { model.actionError = $0 },
                onAttachmentUploadingChanged: { uploading in
                    if uploading {
                        uploadingAttachment.insert(session.id)
                    } else {
                        uploadingAttachment.remove(session.id)
                    }
                },
                onExit: { code in endedAttach[session.id] = code }
            )
                // Keyed on the retry generation only — NOT colorScheme. A theme toggle
                // must re-theme live via updateNSView (as the split shell already does);
                // rebuilding here would tear down every kept-alive terminal at once and
                // throw away the very content this keeps alive.
                .id("attach-\(session.id)-\(attachRetry[session.id] ?? 0)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if isSelected, endedAttach[session.id] != nil {
                attachEndedOverlay(session)
            }
        }
        // Ghostty's Metal layer is non-opaque (clear background), and the
        // `.opacity` below forces SwiftUI to composite this child offscreen —
        // where glyph anti-aliasing falls back to a transparent backdrop and
        // renders pale (worst on dense CJK strokes). A solid backdrop inside
        // the compositing group gives the text an opaque background to blend
        // against, matching the pre-keep-alive single-view rendering.
        .background(Theme.terminalBackground)
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        // A kept-alive child stays in the view tree, so VoiceOver would otherwise
        // reach every hidden terminal alongside the visible one.
        .accessibilityHidden(!isSelected)
    }

    /// The ⌘D sidecar shells, one per Space that has opened a split. Every shell stays
    /// mounted while another Space is selected — an app-owned shell has no server side
    /// to reattach to, so tearing its view down would kill what is running in it.
    private var splitShellTerminals: some View {
        ZStack {
            ForEach(model.spaceSplitSessions) { session in
                let active = model.attachedSpaceRef == session.space
                ShellTerminalView(
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    dark: colorScheme == .dark,
                    mouseReporting: terminalMouseReporting,
                    surfaceVisible: active,
                    onExit: { _ in model.closeSplitSession(for: session.space) },
                    onViewReady: { view in
                        model.registerSplitShellView(view, for: session.space)
                        if active {
                            splitTracker.shellView = view
                        }
                    }
                )
                    // Deliberately not keyed on colorScheme like the attach above:
                    // a new id tears the view down and kills the shell with whatever
                    // was running in it, and unlike a herdr pane a local shell has no
                    // server-side state to reattach to. updateNSView re-themes it.
                    .id("space-shell-\(session.id.uuidString)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    // Solid backdrop inside the opacity compositing group so glyph AA
                    // on Ghostty's non-opaque Metal layer stays crisp (see attachChild).
                    .background(Theme.terminalBackground)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
            }
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, the pane going away, herdr stopping).
    private func attachEndedOverlay(_ entry: FleetStore.AttachedEntry) -> some View {
        let dropped = (endedAttach[entry.id] ?? nil) == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttach[entry.id] = nil
                attachRetry[entry.id, default: 0] += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    private var showsStartAgentShortcut: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil
                && model.visibleAgents.isEmpty
                && model.visibleTerminals.isEmpty {
                return String(localized: "No agents or terminals in this space yet")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}
