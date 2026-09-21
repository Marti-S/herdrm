import Combine
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class FleetStorePlatformTests: XCTestCase {
    private let windows = SSHTunnel.RemotePlatform.windows(home: "C:\\Users\\fixture", herdrExecutable: "C:\\herdr.exe")

    private func fixture() -> (FleetStore, DeviceStore, Device, HerdrService) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeviceStore(directory: directory)
        let device = Device(name: "Fixture", kind: .ssh(target: "fixture.invalid"))
        store.save([.local, device])
        let model = FleetStore(store: store)
        model.sessions[device.id] = DeviceSessionState()
        let service = model.service(for: device)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (model, store, device, service)
    }

    func testMetadataPersistsAndPublishesOnlyOnRealChange() async {
        let (model, store, device, service) = fixture()
        var changes = 0
        let subscription = model.fleetStateDidChange.sink { change in
            if case .device(let id) = change, id == device.id { changes += 1 }
        }
        defer { subscription.cancel() }
        let first = await model.synchronizeSSHPlatform(deviceID: device.id, using: service, load: { self.windows })
        XCTAssertTrue(first)
        XCTAssertEqual(model.device(device.id)?.osID, "windows")
        XCTAssertEqual(store.load().first { $0.id == device.id }?.osID, "windows")
        XCTAssertEqual(changes, 1)
        let second = await model.synchronizeSSHPlatform(deviceID: device.id, using: service, load: { self.windows })
        XCTAssertTrue(second)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(model.service(for: device) === service, "metadata must not replace the live owner")
        await model.shutdownAllSessions()
    }

    func testLatePlatformIsRejectedAfterRemovalEditReplacementShutdownAndCancellation() async {
        for mutation in ["remove", "edit", "replace", "shutdown", "cancel"] {
            let (model, store, device, service) = fixture()
            let gate = PlatformGate()
            let task = Task {
                await model.synchronizeSSHPlatform(deviceID: device.id, using: service, load: { await gate.wait() })
            }
            await fulfillment(of: [gate.entered], timeout: 2)
            switch mutation {
            case "remove":
                model.removeDevice(device)
            case "edit":
                // Change the same-ID command target without starting a real SSH
                // connection. The resolver also checks generation/service identity.
                if let index = model.devices.firstIndex(where: { $0.id == device.id }) {
                    model.devices[index].kind = .ssh(target: "replacement.invalid")
                }
            case "replace":
                await model.shutdownAllSessions()
                model.sessions[device.id] = DeviceSessionState()
                _ = model.service(for: device)
            case "shutdown":
                await model.shutdownAllSessions()
            default:
                task.cancel()
            }
            var lateChanges = 0
            let subscription = model.fleetStateDidChange.sink { _ in lateChanges += 1 }
            gate.release(windows)
            let accepted = await task.value
            XCTAssertFalse(accepted, mutation)
            XCTAssertNil(model.device(device.id)?.osID, mutation)
            XCTAssertNil(store.load().first { $0.id == device.id }?.osID, mutation)
            XCTAssertEqual(lateChanges, 0, mutation)
            subscription.cancel()
            await model.shutdownAllSessions()
        }
    }

    func testShutdownInvalidatesConnectedSessionsAndExposesFleetRecovery() async {
        let (model, _, device, _) = fixture()
        model.setDeviceFilter(device.id)
        model.sessions[device.id]?.connection = .connected(version: "fixture")
        var stoppedChanges = 0
        let subscription = model.fleetStateDidChange.sink { change in
            if case .device(let id) = change, id == device.id,
               case .failed = model.session(id).connection {
                stoppedChanges += 1
            }
        }
        defer { subscription.cancel() }
        let stopped = await model.shutdownAllSessions()
        XCTAssertTrue(stopped)
        guard case .failed(let reason) = model.session(device.id).connection else {
            return XCTFail("Shutdown must not leave a connected snapshot without an owner")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(model.hasReconnectableDevice)
        XCTAssertEqual(stoppedChanges, 1)
    }

    func testUnixDiscoveryClearsStaleWindowsRouting() async {
        let (model, _, device, service) = fixture()
        _ = await model.synchronizeSSHPlatform(deviceID: device.id, using: service, load: { self.windows })
        _ = await model.synchronizeSSHPlatform(deviceID: device.id, using: service, load: { .unix(home: "/home/fixture") })
        XCTAssertNil(model.device(device.id)?.osID)
        await model.shutdownAllSessions()
    }
}

@MainActor
private final class PlatformGate {
    let entered = XCTestExpectation(description: "platform lookup entered")
    private var continuation: CheckedContinuation<SSHTunnel.RemotePlatform?, Never>?
    private var deadline: Task<Void, Never>?

    func wait() async -> SSHTunnel.RemotePlatform? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 3_000_000_000) }
                catch { return }
                XCTFail("platform fixture was not released before its deadline")
                self?.release(nil)
            }
        }
    }

    func release(_ value: SSHTunnel.RemotePlatform?) {
        deadline?.cancel()
        deadline = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: value)
    }
}
