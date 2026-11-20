// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Kadmos",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "KadmosCore",
            targets: ["KadmosCore"]
        )
    ],
    targets: [
        .target(
            name: "KadmosCore",
            path: "Sources/KadmosCore"
        ),
        .testTarget(
            name: "KadmosCoreTests",
            dependencies: ["KadmosCore"],
            path: "Tests/KadmosCoreTests"
        )
    ]
)
