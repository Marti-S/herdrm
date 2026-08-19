// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "HerdrKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"])
    ],
    targets: [
        .target(
            name: "HerdrKit",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(name: "HerdrKitTests", dependencies: ["HerdrKit"])
    ]
)
