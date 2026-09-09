import Foundation
#if canImport(os)
import os
private let performanceLog = OSLog(subsystem: "dev.bybee.herdrm", category: "performance")
#endif

/// Immutable signpost identity. No prompts, tokens, terminal text, or hostnames
/// are recorded. The non-Apple implementation is intentionally a no-op.
public struct PerformanceInterval: @unchecked Sendable {
    private let name: StaticString
    #if canImport(os)
    private let id: OSSignpostID
    #endif

    public init(_ name: StaticString) {
        self.name = name
        #if canImport(os)
        id = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: name, signpostID: id)
        #endif
    }

    public func end(bytes: Int = 0) {
        #if canImport(os)
        os_signpost(.end, log: performanceLog, name: name, signpostID: id,
                    "bytes=%{public}ld", bytes)
        #endif
    }
}
