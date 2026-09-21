import AppKit
import HerdrKit
import SwiftUI

/// Path field with an inline folder browser: type freely, click a row to descend,
/// arrow-up to the parent. Local devices list through FileManager (and keep the
/// native panel behind Browse…); remote devices list over one-shot SSH. A path
/// segment that isn't a directory yet filters its parent's listing instead, so
/// "~/de" narrows to Desktop and Developer as you type.
struct DirectoryPickerField: View {
    @ObservedObject var model: FleetStore
    let device: Device
    @Binding var path: String

    /// The directory whose children are on screen. Clicks resolve against it, so a
    /// half-typed path keeps showing (and completing from) its parent's folders.
    @State private var listedRoot = ""
    /// The device `listedRoot`/`entries` belong to. Without this, switching the
    /// device picker while the path still reads "~" matches the stale root and
    /// keeps showing the previous device's folders.
    @State private var listedDeviceID: UUID?
    @State private var entries: [String] = []
    /// Case-insensitive prefix applied to `entries` while the last typed segment
    /// isn't a directory of its own.
    @State private var filter = ""
    @State private var isListing = false
    @State private var hoveredEntry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    path = Self.parent(of: listedRoot.isEmpty ? path : listedRoot)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Up to the parent folder")
                .disabled(atRoot)
                TextField("~/Projects/foo", text: $path)
                    .textFieldStyle(.roundedBorder)
                if device.isLocal {
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            path = (url.path as NSString).abbreviatingWithTildeInPath
                        }
                    }
                }
            }
            browser
        }
        .task(id: "\(device.id.uuidString)|\(path)") {
            // Debounce: retyping cancels this task before the sleep ends.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await refreshListing()
        }
    }

    private var visibleEntries: [String] {
        guard !filter.isEmpty else { return entries }
        return entries.filter { $0.range(of: filter, options: [.caseInsensitive, .anchored]) != nil }
    }

    private var browser: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(visibleEntries, id: \.self) { name in
                    Button {
                        // Trailing slash so the next keystrokes filter inside the
                        // folder instead of rewriting its name.
                        path = (listedRoot == "/" ? "/\(name)" : "\(listedRoot)/\(name)") + "/"
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            Text(name)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(hoveredEntry == name ? Theme.itemWash : .clear)
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            hoveredEntry = name
                        } else if hoveredEntry == name {
                            hoveredEntry = nil
                        }
                    }
                }
                if visibleEntries.isEmpty && !isListing {
                    Text(entries.isEmpty ? String(localized: "No subfolders") : String(localized: "No folders match \"\(filter)\""))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textGhost)
                        .padding(8)
                }
            }
            .padding(4)
        }
        .frame(height: 150)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            if isListing {
                ProgressView()
                    .controlSize(.small)
                    .padding(6)
            }
        }
    }

    private var atRoot: Bool {
        let current = Self.normalized(listedRoot.isEmpty ? path : listedRoot)
        return current == "/" || current == "~"
    }

    @MainActor
    private func refreshListing() async {
        let service = model.service(for: device)
        if listedDeviceID != device.id {
            listedDeviceID = device.id
            listedRoot = ""
            entries = []
            filter = ""
        }
        let typed = path.trimmingCharacters(in: .whitespaces)
        let root = Self.normalized(typed.isEmpty ? "~" : typed)
        if root == listedRoot {
            filter = ""
            return
        }
        let partial = Self.lastComponent(of: root)
        // Typing inside the directory already on screen filters it right away; the
        // fetch below still lets a fully typed (or dot-hidden) folder take over. A
        // trailing slash is an explicit "list this folder", never a filter.
        if !typed.hasSuffix("/"), Self.parent(of: root) == listedRoot {
            filter = partial
        }
        isListing = true
        defer { isListing = false }
        for candidate in [root, Self.parent(of: root)] {
            if candidate == listedRoot {
                // Already on screen; keep the listing, keep the filter, skip the fetch.
                filter = partial
                return
            }
            guard let names = try? await service.listDirectories(at: candidate) else { continue }
            // A slow reply for a path the user already left must not clobber the new one.
            guard !Task.isCancelled else { return }
            listedRoot = candidate
            entries = names
            filter = candidate == root ? "" : partial
            return
        }
        guard !Task.isCancelled else { return }
        entries = []
        filter = ""
    }

    /// "~/a/b" → "b"; the segment the filter matches against.
    static func lastComponent(of path: String) -> String {
        (normalized(path) as NSString).lastPathComponent
    }

    /// "~/a/b" → "~/a"; stops at "~" and "/".
    static func parent(of path: String) -> String {
        let normalized = normalized(path)
        if normalized == "~" || normalized == "/" { return normalized }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "~" : parent
    }

    /// Trims trailing slashes so paths compose predictably ("/" itself survives).
    static func normalized(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
