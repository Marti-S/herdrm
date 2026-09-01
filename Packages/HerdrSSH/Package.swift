// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdrSSH",
    platforms: [.iOS(.v18)],
    products: [.library(name: "HerdrSSH", targets: ["HerdrSSH"])],
    targets: [
        .binaryTarget(name: "CLibSSH2", path: "Artifacts/CLibSSH2.xcframework"),
        .binaryTarget(name: "COpenSSL", path: "Artifacts/COpenSSL.xcframework"),
        .target(
            name: "CHerdrSSHSupport",
            path: "Sources/CHerdrSSHSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "HerdrSSH",
            dependencies: ["CLibSSH2", "COpenSSL", "CHerdrSSHSupport"]
        ),
        .testTarget(name: "HerdrSSHTests", dependencies: ["HerdrSSH"]),
    ],
    // The package requires SwiftPM 6.2 for its current binary-target setup,
    // but its native-pointer actor code intentionally remains in Swift 5 mode.
    swiftLanguageModes: [.v5]
)
