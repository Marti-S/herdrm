import Foundation
import HerdrKit
import os

/// Main-actor cache owned by FleetBridgeServer, independent of listeners and credentials.
/// Device invalidation remains incremental even when there are no wire consumers.
@MainActor
final class FleetBridgeSnapshotCache {
    private struct CachedFleet {
        let snapshot: FleetSnapshot
        var encodedSnapshot: Data?
    }

    private(set) var revision: UInt64 = 1
    private var lastBroadcastRevision: UInt64 = 1
    private var dirtyDeviceIDs: Set<UUID> = []
    private var rebuildEntireFleet = false
    private var cachedDevicesByID: [UUID: FleetDeviceSnapshot] = [:]
    private var cachedDeviceOrder: [UUID] = []
    private var fleet: CachedFleet?
    private var suppressedFleetUpdates: UInt64 = 0
    private let log = Logger(subsystem: "dev.bybee.herdrm", category: "fleet-bridge")
    private let encode: (FleetSnapshot) throws -> Data

    init(encode: @escaping (FleetSnapshot) throws -> Data = { try JSONEncoder().encode($0) }) {
        self.encode = encode
    }

    func invalidate(deviceID: UUID) {
        dirtyDeviceIDs.insert(deviceID)
    }

    func invalidateTopology() {
        rebuildEntireFleet = true
    }

    func initialize(devices: [Device], deviceSnapshot: (Device) -> FleetDeviceSnapshot) throws {
        let snapshot = try refresh(
            devices: devices, deviceSnapshot: deviceSnapshot,
            force: true, incrementRevision: false
        )
        lastBroadcastRevision = snapshot.revision
    }

    /// A stop drops payloads and device caches, but preserves the server's revision counter.
    func reset() {
        dirtyDeviceIDs.removeAll()
        rebuildEntireFleet = false
        cachedDevicesByID.removeAll()
        cachedDeviceOrder.removeAll()
        fleet = nil
    }

    @discardableResult
    func refresh(
        devices: [Device],
        deviceSnapshot: (Device) -> FleetDeviceSnapshot,
        force: Bool = false,
        incrementRevision: Bool = true
    ) throws -> FleetSnapshot {
        if !force, !rebuildEntireFleet, dirtyDeviceIDs.isEmpty, let fleet {
            return fleet.snapshot
        }
        let deviceOrder = devices.map(\.id)
        let rebuildAll = force || fleet == nil || rebuildEntireFleet || cachedDeviceOrder != deviceOrder
        var nextDevicesByID = cachedDevicesByID
        if rebuildAll {
            nextDevicesByID.removeAll(keepingCapacity: true)
            for device in devices {
                nextDevicesByID[device.id] = deviceSnapshot(device)
            }
        } else {
            for deviceID in dirtyDeviceIDs {
                guard let device = devices.first(where: { $0.id == deviceID }) else {
                    nextDevicesByID.removeValue(forKey: deviceID)
                    continue
                }
                nextDevicesByID[deviceID] = deviceSnapshot(device)
            }
        }

        let snapshots = deviceOrder.compactMap { nextDevicesByID[$0] }
        dirtyDeviceIDs.removeAll()
        rebuildEntireFleet = false
        cachedDevicesByID = nextDevicesByID
        cachedDeviceOrder = deviceOrder

        if !force, let fleet, fleet.snapshot.devices == snapshots {
            suppressedFleetUpdates &+= 1
            log.debug("suppressed unchanged fleet update (total \(self.suppressedFleetUpdates))")
            return fleet.snapshot
        }
        if incrementRevision, fleet != nil {
            revision &+= 1
        }
        let snapshot = FleetSnapshot(revision: revision, devices: snapshots)
        // Semantic bookkeeping never serializes. The first wire consumer fills this slot.
        fleet = CachedFleet(snapshot: snapshot, encodedSnapshot: nil)
        return snapshot
    }

    /// Call refresh first so requests arriving before the debounce fires see current data.
    func encodedSnapshot() throws -> Data {
        guard var fleet else {
            throw CocoaError(.coderValueNotFound)
        }
        if let encodedSnapshot = fleet.encodedSnapshot { return encodedSnapshot }
        let encodedSnapshot = try encode(fleet.snapshot)
        fleet.encodedSnapshot = encodedSnapshot
        self.fleet = fleet
        return encodedSnapshot
    }

    /// Call refresh even while idle to maintain semantic revisions and invalidation.
    func pendingBroadcast(enabled: Bool, hasSubscribers: Bool) throws -> Data? {
        guard let fleet, fleet.snapshot.revision > lastBroadcastRevision else { return nil }
        guard enabled, hasSubscribers else {
            lastBroadcastRevision = fleet.snapshot.revision
            return nil
        }
        // Do not consume the broadcast revision if encoding fails; the next attempt retries.
        let encodedSnapshot = try encodedSnapshot()
        lastBroadcastRevision = fleet.snapshot.revision
        return encodedSnapshot
    }
}
