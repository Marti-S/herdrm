import XCTest
@testable import HerdrKit

final class FleetBridgeNetworkTests: XCTestCase {
    func testTailscaleIPv4RangeBoundaries() {
        XCTAssertTrue(FleetBridgeNetworkSelector.isTailscaleIPv4("100.64.0.0"))
        XCTAssertTrue(FleetBridgeNetworkSelector.isTailscaleIPv4("100.127.255.255"))

        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("100.63.255.255"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("100.128.0.0"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("10.0.0.1"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("192.168.1.10"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("100.64.0"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("100.64.0.256"))
        XCTAssertFalse(FleetBridgeNetworkSelector.isTailscaleIPv4("100.064.0.1x"))
    }

    func testDefaultSelectionBindsOnlyTheTailscaleAddress() {
        let identity = FleetBridgeNetworkSelector.select(
            interfaces: [
                FleetBridgeIPv4Interface(name: "en0", address: "192.168.1.8"),
                FleetBridgeIPv4Interface(name: "utun7", address: "100.101.2.3"),
            ],
            bindAllInterfaces: false,
            fallbackHost: "studio.local"
        )

        XCTAssertEqual(
            identity,
            FleetBridgeNetworkIdentity(
                bindHost: "100.101.2.3",
                pairingHost: "100.101.2.3",
                scope: .tailscale
            )
        )
    }

    func testDefaultSelectionFallsBackToLoopback() {
        let identity = FleetBridgeNetworkSelector.select(
            interfaces: [
                FleetBridgeIPv4Interface(name: "en0", address: "192.168.1.8"),
                FleetBridgeIPv4Interface(
                    name: "utun7",
                    address: "100.88.0.9",
                    isUp: false
                ),
            ],
            bindAllInterfaces: false,
            fallbackHost: "studio.local"
        )

        XCTAssertEqual(identity, .loopback)
        XCTAssertTrue(identity.loopbackOnly)
    }

    func testNonTunnelCGNATInterfaceIsNotTreatedAsTailscale() {
        let identity = FleetBridgeNetworkSelector.select(
            interfaces: [
                FleetBridgeIPv4Interface(name: "en0", address: "100.70.0.1")
            ],
            bindAllInterfaces: false,
            fallbackHost: "studio.local"
        )

        XCTAssertEqual(identity, .loopback)
        XCTAssertNil(
            FleetBridgeNetworkSelector.preferredTailscaleInterface(
                from: [FleetBridgeIPv4Interface(name: "en0", address: "100.70.0.1")]
            )
        )
    }

    func testAllInterfacesIsExplicitAndUsesTailscaleForPairingWhenAvailable() {
        let identity = FleetBridgeNetworkSelector.select(
            interfaces: [
                FleetBridgeIPv4Interface(name: "en0", address: "192.168.1.8"),
                FleetBridgeIPv4Interface(name: "utun7", address: "100.99.0.4"),
            ],
            bindAllInterfaces: true,
            fallbackHost: "studio.local"
        )

        XCTAssertNil(identity.bindHost)
        XCTAssertEqual(identity.pairingHost, "100.99.0.4")
        XCTAssertEqual(identity.scope, .allInterfaces)
        XCTAssertFalse(identity.loopbackOnly)
    }

    func testAllInterfacesUsesFallbackHostWithoutTailscale() {
        let identity = FleetBridgeNetworkSelector.select(
            interfaces: [
                FleetBridgeIPv4Interface(name: "en0", address: "192.168.1.8")
            ],
            bindAllInterfaces: true,
            fallbackHost: "studio.local"
        )

        XCTAssertNil(identity.bindHost)
        XCTAssertEqual(identity.pairingHost, "studio.local")
        XCTAssertEqual(identity.scope, .allInterfaces)
    }

    func testPreferredInterfaceOrderingIsStable() {
        let interfaces = [
            FleetBridgeIPv4Interface(name: "other", address: "100.70.0.1"),
            FleetBridgeIPv4Interface(name: "utun8", address: "100.80.0.1"),
            FleetBridgeIPv4Interface(name: "tailscale0", address: "100.90.0.1"),
            FleetBridgeIPv4Interface(name: "tailscale1", address: "100.65.0.1"),
        ]

        XCTAssertEqual(
            FleetBridgeNetworkSelector.preferredTailscaleInterface(from: interfaces),
            FleetBridgeIPv4Interface(name: "tailscale1", address: "100.65.0.1")
        )
        XCTAssertEqual(
            FleetBridgeNetworkSelector.preferredTailscaleInterface(
                from: Array(interfaces.reversed())
            ),
            FleetBridgeIPv4Interface(name: "tailscale1", address: "100.65.0.1")
        )
    }

    func testDownAndLoopbackInterfacesAreIgnored() {
        XCTAssertNil(
            FleetBridgeNetworkSelector.preferredTailscaleInterface(
                from: [
                    FleetBridgeIPv4Interface(
                        name: "utun1",
                        address: "100.70.0.1",
                        isUp: false
                    ),
                    FleetBridgeIPv4Interface(
                        name: "utun2",
                        address: "100.71.0.1",
                        isLoopback: true
                    ),
                ]
            )
        )
    }
}
