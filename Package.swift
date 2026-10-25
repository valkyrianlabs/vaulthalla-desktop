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
        .library(name: "VHOnePassword", targets: ["VHOnePassword"]),
        .library(name: "VHKeyBackup", targets: ["VHKeyBackup"]),
        .library(name: "VHMCP", targets: ["VHMCP"]),
        .library(name: "VHFinder", targets: ["VHFinder"]),
        .executable(name: "vaulthalla-mcp", targets: ["vaulthalla-mcp"]),
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
        // Recovery keys (docs/architecture.md §6): vault key backup to 1Password, change detection and restore.
        .target(
            name: "VHKeyBackup",
            dependencies: ["VHCore", "VHContract", "VHTransport", "VHNodes", "VHOnePassword"],
            swiftSettings: strict
        ),
        // The MCP bridge (docs/architecture.md §5): the library, and the stdio helper the app embeds in Contents/Helpers.
        .target(
            name: "VHMCP",
            dependencies: ["VHCore", "VHContract", "VHTransport", "VHIdentity", "VHNodes"],
            swiftSettings: strict
        ),
        // Finder integration (docs/architecture.md §7, File Provider): domain identity, naming and management, and the
        // extension's readiness, without the FileProvider framework, so `swift test` covers them.
        .target(
            name: "VHFinder",
            dependencies: ["VHCore", "VHIdentity", "VHNodes"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "vaulthalla-mcp",
            dependencies: ["VHMCP", "VHCore", "VHNodes"],
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
            dependencies: ["VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity", "VHKeyBackup", "VHOnePassword"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHMCPTests",
            dependencies: ["VHMCP", "VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHFinderTests",
            dependencies: ["VHFinder", "VHCore", "VHIdentity", "VHNodes"],
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
