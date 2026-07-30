// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ZulipMac",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "ZulipMac", targets: ["ZulipMac"]),
    ],
    targets: [
        .binaryTarget(
            name: "ZulipCoreFFI",
            path: "Vendor/ZulipCoreFFI.xcframework"
        ),
        .target(
            name: "ZulipCoreBindings",
            dependencies: ["ZulipCoreFFI"],
            path: "Sources/ZulipCoreBindings"
        ),
        .executableTarget(
            name: "ZulipMac",
            dependencies: ["ZulipCoreBindings"],
            path: "Sources/ZulipMac"
        ),
        .testTarget(
            name: "ZulipMacTests",
            dependencies: ["ZulipMac", "ZulipCoreBindings"],
            path: "Tests/ZulipMacTests"
        ),
    ]
)
