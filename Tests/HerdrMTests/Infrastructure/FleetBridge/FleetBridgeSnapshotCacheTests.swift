import Foundation
import HerdrKit
import XCTest
#if !FLEET_BRIDGE_CACHE_TESTS
@testable import herdrm
#endif

/// Synchronous production-cache tests: no network, app host, credentials, or unbounded waits.
final class FleetBridgeSnapshotCacheTests: XCTestCase {
    @MainActor
    func testDisabledChangesDoNotEncodeEvenWithRetainedSubscribers() throws {
        for hasSubscribers in [false, true] {
            let f = Fixture()
            try f.initialize()
            XCTAssertEqual(f.encodes.count, 0, "Startup must not serialize an unconsumed fleet")
            for version in ["2", "3"] {
                f.changeVersion(version)
                let snapshot = try f.refresh()
                XCTAssertEqual(snapshot.devices[0].connection.version, version)
                XCTAssertNil(try f.cache.pendingBroadcast(enabled: false, hasSubscribers: hasSubscribers))
            }
            XCTAssertEqual(f.cache.revision, 3, "Disabled updates still advance semantic revisions")
            XCTAssertEqual(f.encodes.count, 0)
            let current = try f.request()
            XCTAssertEqual(current.revision, 3)
            XCTAssertEqual(current.devices[0].connection.version, "3")
            XCTAssertEqual(f.encodes.count, 1)
        }
    }

    @MainActor
    func testEnabledWithoutSubscribersEncodesOnlyTheLatestRequestedRevision() throws {
        let f = Fixture()
        try f.initialize()
        for version in ["2", "3", "4"] {
            f.changeVersion(version)
            try f.refresh()
            XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: false))
        }
        XCTAssertEqual(f.cache.revision, 4)
        XCTAssertEqual(f.encodes.count, 0)
        XCTAssertEqual(try f.request().devices[0].connection.version, "4")
        XCTAssertEqual(try f.request().revision, 4)
        XCTAssertEqual(f.encodes.map(\.revision), [4])
    }

    @MainActor
    func testOneSubscriberEncodesOncePerSemanticRevisionAndSuppressesNoOps() throws {
        let f = Fixture()
        try f.initialize()
        let initial = try f.request() // Initial subscription response.
        XCTAssertEqual(initial.revision, 1)
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))

        f.changeVersion("2")
        try f.refresh()
        let update = try XCTUnwrap(f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(try JSONDecoder().decode(FleetSnapshot.self, from: update).revision, 2)
        XCTAssertEqual(try f.request().revision, 2)
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))

        f.changeVersion("2") // Semantic duplicate despite an explicit device invalidation.
        try f.refresh()
        f.cache.invalidateTopology() // Rebuilt identical fleet is also a no-op.
        try f.refresh()
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(try f.cache.encodedSnapshot(), update)
        XCTAssertEqual(f.cache.revision, 2)
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2])
    }

    @MainActor
    func testMultipleSubscribersSharePayloadButKeepIndividualWireEnvelopes() throws {
        let f = Fixture()
        try f.initialize()
        let requestIDs = [UUID(), UUID(), UUID()]
        for requestID in requestIDs {
            let snapshot = try f.refresh()
            try assertEnvelope(requestID: requestID, payload: f.cache.encodedSnapshot(), snapshot: snapshot)
        }
        XCTAssertEqual(f.encodes.map(\.revision), [1])

        f.changeVersion("2")
        let snapshot = try f.refresh()
        let payload = try XCTUnwrap(f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        for requestID in requestIDs {
            try assertEnvelope(requestID: requestID, payload: payload, snapshot: snapshot)
        }
        // A joining subscriber and a one-shot request share this same encoding too.
        XCTAssertEqual(try f.cache.encodedSnapshot(), payload)
        XCTAssertEqual(try f.request(), snapshot)
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2])
        XCTAssertEqual(FleetBridgeProtocol.version, 2)
    }

    @MainActor
    func testRequestBeforeDebouncedPublishIsFreshAndBroadcastReusesIt() throws {
        let f = Fixture()
        try f.initialize()
        _ = try f.request()
        f.changeVersion("2")
        // The server request path refreshes pending invalidations before encoding.
        let requested = try f.request()
        XCTAssertEqual(requested.revision, 2)
        XCTAssertEqual(requested.devices[0].connection.version, "2")
        let published = try XCTUnwrap(f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(try JSONDecoder().decode(FleetSnapshot.self, from: published), requested)
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2])
    }

    @MainActor
    func testDeviceInvalidationRebuildsOnlyDirtyDeviceAndDropsOldEncoding() throws {
        let f = Fixture()
        try f.initialize()
        let old = try f.request()
        f.builtDeviceIDs.removeAll()
        f.changeVersion("new")
        let current = try f.refresh()
        XCTAssertEqual(f.builtDeviceIDs, [f.devices[0].id])
        XCTAssertEqual(current.devices[1], old.devices[1])
        XCTAssertEqual(f.encodes.count, 1, "Invalidation must drop, not replace, encoded bytes")
        XCTAssertEqual(try f.request(), current)
        XCTAssertNotEqual(current, old)
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2])
    }

    @MainActor
    func testTopologyInvalidationPreservesOrderIdentityRemovalAndFreshMetadata() throws {
        let f = Fixture()
        try f.initialize()
        _ = try f.request()
        f.devices.reverse()
        f.devices[0].name = "Renamed"
        f.devices.append(Device(name: "Added", kind: .local))
        f.cache.invalidateTopology()
        let changed = try f.request()
        XCTAssertEqual(changed.devices.map(\.id), f.devices.map(\.id))
        XCTAssertEqual(changed.devices[0].device.name, "Renamed")
        XCTAssertEqual(changed.revision, 2)

        let removedID = f.devices.remove(at: 1).id
        // Device-order mismatch during an invalidated refresh also forces a full rebuild.
        f.cache.invalidate(deviceID: removedID)
        let removed = try f.request()
        XCTAssertEqual(removed.devices.map(\.id), f.devices.map(\.id))
        XCTAssertNil(removed.device(removedID))
        XCTAssertEqual(removed.revision, 3)
        f.devices.removeAll()
        f.cache.invalidateTopology()
        XCTAssertEqual(try f.request().devices, [])
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2, 3, 4])
    }

    @MainActor
    func testLastSubscriberLeavesThenNewSubscriberGetsLatestState() throws {
        let f = Fixture()
        try f.initialize()
        _ = try f.request()
        for version in ["2", "3"] {
            f.changeVersion(version)
            try f.refresh()
            XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: false))
        }
        XCTAssertEqual(f.encodes.map(\.revision), [1])
        let newSubscriber = try f.request()
        XCTAssertEqual(newSubscriber.revision, 3)
        XCTAssertEqual(newSubscriber.devices[0].connection.version, "3")
        XCTAssertEqual(f.encodes.map(\.revision), [1, 3])
        f.changeVersion("4")
        try f.refresh()
        XCTAssertNotNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(f.encodes.map(\.revision), [1, 3, 4])
    }

    @MainActor
    func testStopRestartClearsPayloadAndDirtyStateWithoutResettingRevision() throws {
        let f = Fixture()
        try f.initialize()
        _ = try f.request()
        f.changeVersion("2")
        _ = try f.request()
        f.changeVersion("never-published")
        f.cache.reset() // FleetBridgeServer.stop uses this exact reset.
        XCTAssertEqual(f.cache.revision, 2)
        XCTAssertThrowsError(try f.cache.encodedSnapshot())
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))

        f.devices = [Device(name: "Replacement", kind: .local)]
        try f.initialize() // start forces a rebuild and establishes its broadcast watermark.
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2])
        XCTAssertEqual(f.cache.revision, 2)
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        let restarted = try f.request()
        XCTAssertEqual(restarted.devices.map(\.id), f.devices.map(\.id))
        XCTAssertEqual(restarted.devices[0].device.name, "Replacement")
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2, 2], "Same revision across stop must not reuse stale bytes")
        f.changeVersion("3")
        try f.refresh()
        XCTAssertNotNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2, 2, 3])
    }

    @MainActor
    func testEncodingFailureDoesNotPoisonSnapshotOrConsumeBroadcastRevision() throws {
        let f = Fixture()
        try f.initialize()
        _ = try f.request()
        f.changeVersion("2")
        f.failEncoding = true
        let current = try f.refresh()
        XCTAssertEqual(current.revision, 2, "Semantic refresh must not depend on JSON encoding")
        XCTAssertThrowsError(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(try f.refresh(), current)
        f.failEncoding = false
        let retried = try XCTUnwrap(f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
        XCTAssertEqual(try JSONDecoder().decode(FleetSnapshot.self, from: retried), current)
        XCTAssertEqual(try f.cache.encodedSnapshot(), retried)
        XCTAssertEqual(f.encodes.map(\.revision), [1, 2, 2])
        XCTAssertNil(try f.cache.pendingBroadcast(enabled: true, hasSubscribers: true))
    }

    @MainActor
    func testRepeatedStartForcesFreshDataWithoutEncodingOrRevisionReset() throws {
        let f = Fixture()
        try f.initialize()
        let old = try f.request()
        f.devices[0].name = "Changed while stopped"
        // Reinitialization must not require a pending invalidation to replace cached bytes.
        try f.initialize()
        XCTAssertEqual(f.encodes.count, 1)
        let current = try f.request()
        XCTAssertEqual(current.revision, old.revision)
        XCTAssertEqual(current.devices[0].device.name, "Changed while stopped")
        XCTAssertNotEqual(current, old)
        XCTAssertEqual(f.encodes.count, 2)
    }

    private func assertEnvelope(requestID: UUID, payload: Data, snapshot: FleetSnapshot) throws {
        let bytes = try FleetBridgeWire.encodeSnapshot(requestID: requestID, encodedSnapshot: payload)
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(
            try FleetBridgeWire.decodeServer(bytes),
            .snapshot(FleetBridgeSnapshotRecord(requestID: requestID, snapshot: snapshot))
        )
    }
}

@MainActor
private final class Fixture {
    var devices = [
        Device(name: "Local fixture", kind: .local, osID: "macos"),
        Device(name: "Remote fixture", kind: .ssh(target: "unused@invalid"), osID: "linux"),
    ]
    var versions: [UUID: String] = [:]
    var builtDeviceIDs: [UUID] = []
    var encodes: [FleetSnapshot] = []
    var failEncoding = false
    lazy var cache = FleetBridgeSnapshotCache { [unowned self] snapshot in
        encodes.append(snapshot)
        if failEncoding { throw CocoaError(.coderInvalidValue) }
        return try JSONEncoder().encode(snapshot)
    }

    func initialize() throws {
        try cache.initialize(devices: devices, deviceSnapshot: makeDeviceSnapshot)
    }

    @discardableResult
    func refresh() throws -> FleetSnapshot {
        try cache.refresh(devices: devices, deviceSnapshot: makeDeviceSnapshot)
    }

    func request() throws -> FleetSnapshot {
        try refresh()
        return try JSONDecoder().decode(FleetSnapshot.self, from: cache.encodedSnapshot())
    }

    func changeVersion(_ version: String) {
        versions[devices[0].id] = version
        cache.invalidate(deviceID: devices[0].id)
    }

    private func makeDeviceSnapshot(_ device: Device) -> FleetDeviceSnapshot {
        builtDeviceIDs.append(device.id)
        return FleetDeviceSnapshot(
            device: FleetDeviceDescriptor(
                id: device.id, name: device.name,
                kind: device.isLocal ? .local : .remote, osID: device.osID
            ),
            connection: .connected(version: versions[device.id] ?? "1"),
            snapshot: nil,
            availableAgentKinds: ["codex"]
        )
    }
}
