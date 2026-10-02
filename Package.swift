// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacSCP", targets: ["MacSCP"]),
        .executable(name: "MacSCPAskPass", targets: ["MacSCPAskPass"])
    ],
    targets: [
        .target(name: "MacSCPCore"),
        .executableTarget(name: "MacSCP", dependencies: ["MacSCPCore"]),
        .executableTarget(name: "MacSCPAskPass", dependencies: ["MacSCPCore"]),
        .testTarget(name: "MacSCPCoreTests", dependencies: ["MacSCPCore"])
    ],
    swiftLanguageModes: [.v6]
)
