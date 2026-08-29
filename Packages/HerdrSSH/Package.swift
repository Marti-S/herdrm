// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HerdrSSH",
    platforms: [
        .iOS(.v18),
    ],
    products: [
        .library(name: "HerdrSSH", targets: ["HerdrSSH"]),
    ],
    targets: [
        .binaryTarget(
            name: "COpenSSL",
            path: "Artifacts/COpenSSL.xcframework"
        ),
        .binaryTarget(
            name: "CLibSSH2",
            path: "Artifacts/CLibSSH2.xcframework"
        ),
        .target(
            name: "CHerdrSSHSupport",
            dependencies: ["CLibSSH2"]
        ),
        .target(
            name: "HerdrSSH",
            dependencies: ["CLibSSH2", "COpenSSL", "CHerdrSSHSupport"]
        ),
        .testTarget(
            name: "HerdrSSHTests",
            dependencies: ["HerdrSSH"]
        ),
    ]
)
