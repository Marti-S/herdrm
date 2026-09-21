import Foundation

/// Persists the device list as JSON under Application Support.
public final class DeviceStore: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.bybee.herdrm.devices")

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("devices.json")
    }

    public func load() -> [Device] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let devices = try? JSONDecoder().decode([Device].self, from: data),
                  !devices.isEmpty
            else { return [.local] }
            // Local is always present and always first.
            var list = devices.filter { !$0.isLocal }
            list.insert(.local, at: 0)
            return list
        }
    }

    public func save(_ devices: [Device]) {
        queue.sync {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(devices) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
