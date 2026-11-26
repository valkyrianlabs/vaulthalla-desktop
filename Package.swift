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
        .library(name: "VHReports", targets: ["VHReports"]),
        .library(name: "VHOnePassword", targets: ["VHOnePassword"]),
        .library(name: "VHKeyBackup", targets: ["VHKeyBackup"]),
        .library(name: "VHRecovery", targets: ["VHRecovery"]),
        .library(name: "VHKeykit", targets: ["VHKeykit"]),
        .library(name: "VHCloud", targets: ["VHCloud"]),
        .library(name: "VHMCP", targets: ["VHMCP"]),
        .library(name: "VHAgents", targets: ["VHAgents"]),
        .library(name: "VHFinder", targets: ["VHFinder"]),
        .library(name: "VHVaultKeys", targets: ["VHVaultKeys"]),
        .library(name: "VHVaultEngine", targets: ["VHVaultEngine"]),
        .library(name: "VHVault", targets: ["VHVault"]),
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
        // Problem reports (docs/mac-experience.md §8): the vh-report/1 document, redaction (vh-redact/1) and the
        // bundle a person can read before anything is sent. No dependencies: it handles only what it is given.
        .target(name: "VHReports", swiftSettings: strict),
        // Vaulthalla's recovery formats in Swift (CryptoKit): KEV1 envelopes, the recovery seed, uids and the recovery
        // kit, byte for byte the server's and Vaulthalla Cloud's (vectors.json, vendored in its tests). #49.
        .target(name: "VHRecovery", dependencies: ["VHCore"], swiftSettings: strict),
        // vl-keykit's C API (static, built from the pinned source by tools/keykit/build-vlkeykit.sh; never committed).
        .binaryTarget(name: "VLKeykit", path: "build/vlkeykit/VLKeykit.xcframework"),
        // The account recovery key's formats (statements, chains, KAK1, holder proofs, labels, policies, codes) through
        // VLKeykit: Swift marshals, the library implements every format and construction.
        .target(name: "VHKeykit", dependencies: ["VHCore", "VLKeykit"], swiftSettings: strict),
        // Vaulthalla Cloud (optional): this Mac as a linked installation (VHC1-Ed25519 signed requests, its key in the
        // keychain) and the delivering side of a cloud restore: re-wrapping a vault's keys from a recovery kit.
        // The keychain items: the account's app-only group, and the group the app shares with the File Provider extension
        // for Desktop-only vaults (vault keys, the bucket key). No cloud client: the extension links it.
        .target(name: "VHVaultKeys", dependencies: ["VHCore"], swiftSettings: strict),
        .target(name: "VHCloud", dependencies: ["VHCore", "VHRecovery", "VHKeykit", "VHVaultKeys"], swiftSettings: strict),
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
        // Adding the MCP bridge to AI apps (docs/architecture.md §5, "Registration"): Claude Code and Codex through their
        // CLIs (argument arrays, never a shell), the Claude desktop app through an MCP Bundle.
        .target(name: "VHAgents", dependencies: ["VHCore"], swiftSettings: strict),
        // Finder integration (docs/architecture.md §7, File Provider): domain identity, naming and management, the
        // extension's readiness, and the replica (items, versions, errors, conflicts, anchors, the per-domain database,
        // enumeration, fetches and writes) without the FileProvider framework, so `swift test` covers them.
        .target(
            name: "VHFinder",
            dependencies: ["VHCore", "VHContract", "VHTransport", "VHIdentity", "VHNodes"],
            swiftSettings: strict
        ),
        // vl-vaultfmt's C API (the vault format and the Desktop-only engine; static, built from the pinned source by
        // tools/vaultfmt/build-vlvaultfmt.sh; never committed). It holds vl-vaultfmt alone: vl-keykit and libcrypto are
        // VLKeykit's, so every target linking it links VLKeykit too.
        .binaryTarget(name: "VLVaultfmt", path: "build/vlvaultfmt/VLVaultfmt.xcframework"),
        // Desktop-only vaults (docs/desktop-vaults.md): the engine's C API in Swift (the bucket over S3 with SigV4, this
        // Mac's vault keys, the state file), the vault's lifecycle with the cloud, and the engine-backed Finder replica.
        // The engine, the S3 store and the engine-backed Finder replica, with no cloud client: what the File Provider
        // extension links (it reads keys from the shared group and never talks to the cloud).
        .target(
            name: "VHVaultEngine",
            dependencies: ["VHCore", "VHRecovery", "VHFinder", "VHVaultKeys", "VLVaultfmt", "VLKeykit"],
            swiftSettings: strict
        ),
        .target(
            name: "VHVault",
            dependencies: ["VHVaultEngine", "VHCore", "VHRecovery", "VHKeykit", "VHCloud", "VHFinder"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "vaulthalla-mcp",
            dependencies: ["VHMCP", "VHCore", "VHNodes"],
            swiftSettings: strict
        ),
        .testTarget(name: "VHCoreTests", dependencies: ["VHCore"], swiftSettings: strict),
        .testTarget(name: "VHContractTests", dependencies: ["VHContract"], swiftSettings: strict),
        .testTarget(name: "VHCloudTests", dependencies: ["VHCloud", "VHRecovery", "VHCore", "VHKeykit", "VHVault"],
                    swiftSettings: strict),
        .testTarget(
            name: "VHKeykitTests",
            dependencies: ["VHKeykit", "VHCore", "VHRecovery"],
            resources: [.copy("Resources")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHRecoveryTests",
            dependencies: ["VHRecovery", "VHCore"],
            resources: [.copy("Resources")],
            swiftSettings: strict
        ),
        .testTarget(name: "VHTransportTests", dependencies: ["VHTransport"], swiftSettings: strict),
        .testTarget(name: "VHOnePasswordTests", dependencies: ["VHOnePassword", "VHCore"], swiftSettings: strict),
        .testTarget(
            name: "VHIdentityTests",
            dependencies: ["VHIdentity", .product(name: "X509", package: "swift-certificates")],
            swiftSettings: strict
        ),
        .testTarget(name: "VHReportsTests", dependencies: ["VHReports"], swiftSettings: strict),
        .testTarget(
            name: "VHNodesTests",
            dependencies: ["VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity"],
            resources: [.copy("Resources")],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHMCPTests",
            dependencies: ["VHMCP", "VHNodes", "VHCore", "VHContract", "VHTransport", "VHIdentity"],
            swiftSettings: strict
        ),
        .testTarget(name: "VHAgentsTests", dependencies: ["VHAgents", "VHCore"], swiftSettings: strict),
        .testTarget(
            name: "VHKeyBackupTests",
            dependencies: ["VHKeyBackup", "VHNodes", "VHCore", "VHContract", "VHTransport"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "VHFinderTests",
            dependencies: ["VHFinder", "VHCore", "VHContract", "VHTransport", "VHIdentity", "VHNodes"],
            swiftSettings: strict
        ),
        // VHVault's tests; VHVaultTests/Live runs only with VH_LIVE_S3 set (tools/vaultfmt/live-s3.sh).
        .testTarget(
            name: "VHVaultTests",
            dependencies: ["VHVault", "VHVaultEngine", "VHVaultKeys", "VHCloud", "VHCore", "VHRecovery", "VHKeykit", "VHFinder"],
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
