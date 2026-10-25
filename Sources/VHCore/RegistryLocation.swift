public import Foundation

/// Where this process can keep the node registry: the inputs to ``RegistryLocation`` and ``RegistryMigration``,
/// injectable so tests use temporary directories.
public struct RegistryEnvironment: Sendable, Hashable {
    /// `~/Library/Application Support/Vaulthalla`: where every build kept the registry before the App Group, and where
    /// builds without the App Group (unsigned, ad hoc, `swift run`) still do.
    public var legacyDirectory: URL
    /// The App Group this process is entitled to; nil without one.
    public var appGroup: String?
    /// That group's container; nil without the group.
    public var groupContainer: URL?

    public init(legacyDirectory: URL, appGroup: String?, groupContainer: URL?) {
        self.legacyDirectory = legacyDirectory
        self.appGroup = appGroup
        self.groupContainer = groupContainer
    }

    /// This process's: its own App Group entitlement, if any, and Application Support.
    public static func current() -> RegistryEnvironment {
        let group = AppGroup.entitledIdentifier()
        return RegistryEnvironment(
            legacyDirectory: URL.applicationSupportDirectory.appending(path: "Vaulthalla", directoryHint: .isDirectory),
            appGroup: group,
            groupContainer: group.flatMap(AppGroup.containerURL(for:)))
    }

    public static let registryName = "nodes.json"
    /// The Application Support registry once it was copied to the App Group: kept, unchanged, as the backup.
    public static let backupName = "nodes.json.migrated"
    /// The marker a migration leaves in Application Support: where the registry went (``RegistryPointer``).
    public static let pointerName = "nodes.json.moved"
    /// The copy being written into the App Group, before it is verified and moved into place.
    public static let stagingName = "nodes.json.migrating"

    public var legacyRegistryURL: URL { legacyDirectory.appending(path: Self.registryName, directoryHint: .notDirectory) }
    public var backupURL: URL { legacyDirectory.appending(path: Self.backupName, directoryHint: .notDirectory) }
    public var pointerURL: URL { legacyDirectory.appending(path: Self.pointerName, directoryHint: .notDirectory) }

    /// `<group container>/nodes.json`; nil without the group.
    public var groupRegistryURL: URL? {
        groupContainer?.appending(path: Self.registryName, directoryHint: .notDirectory)
    }

    var stagingURL: URL? {
        groupContainer?.appending(path: Self.stagingName, directoryHint: .notDirectory)
    }

    /// The marker a migration left in Application Support, if any (and readable).
    public func pointer() -> RegistryPointer? {
        guard let data = try? Data(contentsOf: pointerURL) else { return nil }
        return try? RegistryPointer.decode(data)
    }
}

/// The marker a completed migration leaves in Application Support (``RegistryEnvironment/pointerName``): where the
/// registry lives now. Writing it is the switch: from then on every process, with or without the App Group, uses the
/// App Group's registry and its lease.
public struct RegistryPointer: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// The registry's path in the App Group container.
    public var registry: String
    public var appGroup: String
    /// SHA-256 (hex) of the file that was copied: the backup's contents.
    public var sha256: String
    public var migratedAt: Date

    public init(registry: String, appGroup: String, sha256: String, migratedAt: Date) {
        version = Self.currentVersion
        self.registry = registry
        self.appGroup = appGroup
        self.sha256 = sha256
        self.migratedAt = migratedAt
    }

    public var registryURL: URL { URL(filePath: registry, directoryHint: .notDirectory) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> RegistryPointer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RegistryPointer.self, from: data)
    }
}

/// The node registry a process uses, and with it the credential lease (``CredentialLease``, next to the registry)
/// (docs/architecture.md §3, "Signing and the shared container").
public struct RegistryLocation: Sendable, Hashable, CustomStringConvertible {
    public enum Source: String, Sendable, Hashable {
        /// The App Group container: signed builds, shared with the File Provider extension.
        case appGroup
        /// Application Support: builds without the App Group, or a registry the owner hasn't migrated yet.
        case applicationSupport
        /// A process without the App Group following the marker a migration left in Application Support.
        case forwarded
    }

    public let registryURL: URL
    public let source: Source

    public init(registryURL: URL, source: Source) {
        self.registryURL = registryURL
        self.source = source
    }

    public var leaseURL: URL { CredentialLease.fileURL(forRegistry: registryURL) }

    public var description: String { "\(registryURL.path(percentEncoded: false)) (\(source.rawValue))" }

    /// The registry a **consumer** reads (`vaulthalla-mcp`, a second app instance); it never migrates anything.
    ///
    /// With the App Group: the group's registry, unless it doesn't exist yet while Application Support still holds an
    /// unmigrated one (the owner migrates it at its next launch). Without the group: wherever a migration's marker
    /// points, else Application Support. Every process thereby agrees on one registry, and one lease.
    public static func resolve(in environment: RegistryEnvironment) -> RegistryLocation {
        let files = FileManager.default
        if let group = environment.groupRegistryURL {
            if files.fileExists(atPath: group.path) || files.fileExists(atPath: environment.pointerURL.path)
                || !files.fileExists(atPath: environment.legacyRegistryURL.path)
            {
                return RegistryLocation(registryURL: group, source: .appGroup)
            }
            return RegistryLocation(registryURL: environment.legacyRegistryURL, source: .applicationSupport)
        }
        if let pointer = environment.pointer() {
            return RegistryLocation(registryURL: pointer.registryURL, source: .forwarded)
        }
        return RegistryLocation(registryURL: environment.legacyRegistryURL, source: .applicationSupport)
    }

    /// The App Group's registry, whether or not it exists yet: for the sandboxed File Provider extension, which can't
    /// see Application Support. nil without the group.
    public static func appGroup(in environment: RegistryEnvironment) -> RegistryLocation? {
        environment.groupRegistryURL.map { RegistryLocation(registryURL: $0, source: .appGroup) }
    }
}
