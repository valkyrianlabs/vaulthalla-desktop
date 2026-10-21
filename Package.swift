// swift-tools-version: 6.2
// VaulthallaKit: everything in Vaulthalla Desktop that isn't a view. The Xcode app target (App/) links these
// libraries; `swift test` runs their tests without the app.

import PackageDescription

let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "VaulthallaKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "VHCore", targets: ["VHCore"]),
        .library(name: "VHContract", targets: ["VHContract"]),
        .library(name: "VHTransport", targets: ["VHTransport"]),
        .library(name: "VHIdentity", targets: ["VHIdentity"]),
        .library(name: "VHNodes", targets: ["VHNodes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
    ],
    targets: [
        .target(name: "VHCore", swiftSettings: strict),
        .target(name: "VHContract", dependencies: ["VHCore"], swiftSettings: strict),
        .target(name: "VHTransport", dependencies: ["VHCore", "VHContract"], swiftSettings: strict),
        .target(name: "VHOnePassword", dependencies: ["VHCore"], swiftSettings: strict),
        .target(
            name: "VHIdentity",
            dependencies: ["VHCore", .product(name: "X509", package: "swift-certificates")],
            swiftSettings: strict
        ),
        .target(
            name: "VHNodes",
            dependencies: ["VHCore", "VHContract", "VHTransport", "VHIdentity"],
            swiftSettings: strict
        ),
        .testTarget(name: "VHCoreTests", dependencies: ["VHCore"], swiftSettings: strict),
        .testTarget(name: "VHContractTests", dependencies: ["VHContract"], swiftSettings: strict),
        .testTarget(name: "VHTransportTests", dependencies: ["VHTransport"], swiftSettings: strict),
        .testTarget(name: "VHOnePasswordTests", dependencies: ["VHOnePassword", "VHCore"], swiftSettings: strict),
        .testTarget(
            name: "VHIdentityTests",
            dependencies: ["VHIdentity", .product(name: "X509", package: "swift-certificates")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHNodesTests",
            dependencies: ["VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity"],
            swiftSettings: strict
        ),
        // Opt-in: runs only with VH_LIVE_NODE set, against a live daemon (docs/interop-testing.md).
        .testTarget(
            name: "VHNodesLiveTests",
            dependencies: ["VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity"],
            swiftSettings: strict
        ),
    ]
)
