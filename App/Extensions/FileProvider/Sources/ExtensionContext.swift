import Foundation
import os
import VHCore
import VHFinder
import VHIdentity
import VHNodes

/// What the extension shares with the app: the registry in the App Group container and the device keys in the
/// shared keychain group, opened read-only (docs/architecture.md §3, "Credential ownership").
struct ExtensionContext: Sendable {
    static let log = Logger(subsystem: "sh.vaulthalla.desktop", category: "fileprovider")

    let environment: RegistryEnvironment
    /// The App Group's registry; nil in an unsigned build, which has no group.
    let registry: RegistryLocation?
    let reader: CredentialReader

    init(environment: RegistryEnvironment = .current()) {
        self.environment = environment
        // Only the group's registry: the sandbox can't see Application Support, and the extension never migrates.
        registry = RegistryLocation.appGroup(in: environment)
        // No lease: a consumer. Only the data protection keychain, where the app keeps Secure Enclave keys in the
        // shared group; an unsigned build's software keys live in the file keychain, outside the sandbox's reach.
        let keys = DeviceKeys(primary: DeviceIdentityStore(), development: nil)
        reader = CredentialReader(registry: registry.map { NodeStore(fileURL: $0.registryURL) }, keys: keys)
    }

    var registryDescription: String {
        registry?.description ?? "no App Group"
    }

    func readiness(for domainIdentifier: String) async -> ExtensionReadiness {
        await ExtensionReadiness.check(domainIdentifier: domainIdentifier, registry: registry, reader: reader)
    }
}

#if DEBUG
/// Debug builds: `VH_FILEPROVIDER_SELFCHECK=<domain identifier> <appex>/Contents/MacOS/VaulthallaFileProvider` runs
/// the extension's own binary, under its own signature and sandbox, prints what it can see, and exits. File Provider
/// starts no extension until the operator allows it in System Settings, so this is how its shared-state path is
/// checked before then. `SelfCheck.c` calls it before `NSExtensionMain`.
@_cdecl("vh_fileprovider_selfcheck")
func fileProviderSelfCheck(_ identifier: UnsafePointer<CChar>) {
    let domainIdentifier = String(cString: identifier)
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        let context = ExtensionContext()
        let sandbox = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none"
        var lines = [
            "bundle: \(Bundle.main.bundleIdentifier ?? "?")",
            "sandbox container: \(sandbox)",
            "app group: \(context.environment.appGroup ?? "none")",
            "registry: \(context.registryDescription)",
        ]
        if let store = context.reader.registry {
            do {
                lines.append("registry nodes: \(try store.reload().count)")
            } catch {
                lines.append("registry unreadable: \(error)")
            }
        }
        // The real home (the sandbox's is its container): the old registry location must stay out of reach.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let outside = URL(filePath: home).appending(path: "Library/Application Support/Vaulthalla")
        lines.append("Application Support readable: \(FileManager.default.isReadableFile(atPath: outside.path))")
        lines.append("readiness: \(await context.readiness(for: domainIdentifier).description)")
        for line in lines { print("selfcheck: \(line)") }
        finished.signal()
    }
    finished.wait()
}
#endif
