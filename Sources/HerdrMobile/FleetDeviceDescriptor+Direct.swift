import Foundation
import HerdrKit

/// Adapts a directly configured SSH source into the bridge's deliberately
/// sanitized device descriptor. The exact SSH target stays on the source row;
/// fleet device metadata exposes only local-versus-remote identity.
extension FleetDeviceDescriptor {
    init(
        id: UUID,
        name: String,
        subtitle _: String,
        isLocal: Bool,
        osID: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            kind: isLocal ? .local : .remote,
            osID: osID
        )
    }
}
