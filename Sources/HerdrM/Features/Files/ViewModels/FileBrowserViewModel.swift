import AppKit
import HerdrKit
import SwiftUI

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published private(set) var device: Device = .local
    @Published private(set) var currentPath = "~"
    @Published var pathText = "~"
    @Published private(set) var entries: [DeviceFileEntry] = []
    @Published var selectedPath: String?
    @Published var includesHidden = false
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private var service = DeviceFileService(device: .local)
    private var generation = 0

    var selectedEntry: DeviceFileEntry? {
        selectedPath.flatMap { path in entries.first { $0.path == path } }
    }

    func configure(for device: Device) async {
        guard self.device.id != device.id || entries.isEmpty else { return }
        generation += 1
        self.device = device
        service = DeviceFileService(device: device)
        currentPath = "~"
        pathText = "~"
        entries = []
        selectedPath = nil
        error = nil
        await refresh()
    }

    func refresh() async {
        await load(pathText)
    }

    func navigate(to path: String) async {
        await load(path)
    }

    func open(_ entry: DeviceFileEntry) async {
        if entry.kind == .directory {
            await load(entry.path)
        } else {
            selectedPath = entry.path
        }
    }

    func goUp() async {
        guard currentPath != "/" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? "/" : parent)
    }

    func goHome() async {
        await load("~")
    }

    func toggleHidden() async {
        includesHidden.toggle()
        await load(currentPath)
    }

    private func load(_ requestedPath: String) async {
        generation += 1
        let requestGeneration = generation
        isLoading = true
        error = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }
        do {
            let listing = try await service.listDirectory(
                at: requestedPath,
                includingHidden: includesHidden
            )
            guard requestGeneration == generation, !Task.isCancelled else { return }
            currentPath = listing.path
            pathText = (listing.path as NSString).abbreviatingWithTildeInPath
            entries = listing.entries
            if let selectedPath, !entries.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class FileTransferViewModel: ObservableObject {
    enum Direction {
        case upload
        case download
    }

    @Published private(set) var isTransferring = false
    @Published private(set) var progress: FileTransferProgress?
    @Published private(set) var label = ""
    @Published var error: String?

    private var task: Task<Void, Never>?

    func start(
        direction: Direction,
        entry: DeviceFileEntry,
        targetDevice: Device,
        localDirectory: String,
        targetDirectory: String,
        conflictPolicy: FileConflictPolicy,
        onFinished: @escaping @MainActor () async -> Void
    ) {
        guard !isTransferring else { return }
        isTransferring = true
        progress = nil
        error = nil
        label = direction == .upload
            ? String(localized: "Uploading \(entry.name)")
            : String(localized: "Downloading \(entry.name)")

        let progressHandler: DeviceFileService.ProgressHandler = { [weak self] value in
            Task { @MainActor in self?.progress = value }
        }
        task = Task { [weak self] in
            do {
                let service = DeviceFileService(device: targetDevice)
                switch direction {
                case .upload:
                    _ = try await service.uploadFile(
                        from: URL(fileURLWithPath: entry.path),
                        toDirectory: targetDirectory,
                        conflictPolicy: conflictPolicy,
                        progress: progressHandler
                    )
                case .download:
                    _ = try await service.downloadFile(
                        at: entry.path,
                        toLocalDirectory: URL(
                            fileURLWithPath: localDirectory,
                            isDirectory: true
                        ),
                        conflictPolicy: conflictPolicy,
                        progress: progressHandler
                    )
                }
                await onFinished()
            } catch is CancellationError {
                // Explicit cancellation should not produce a failure alert.
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isTransferring = false
            self?.progress = nil
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    deinit {
        task?.cancel()
    }
}
