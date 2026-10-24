// THROWAWAY SPIKE (vaulthalla/desktop#2). Not product code.
import Foundation
import os
import Security

enum Spike {
    static let teamID = "QG2U5HNCG4"
    static let appGroup = "QG2U5HNCG4.sh.vaulthalla.desktop.spike"
    static let keychainGroup = "QG2U5HNCG4.sh.vaulthalla.desktop.spike"
    static let keyNamespace = "sh.vaulthalla.desktop.spike.device"
    static let nodeTag = "spike-node"
    static let secretService = "sh.vaulthalla.desktop.spike.secret"
    static let subsystem = "sh.vaulthalla.desktop.spike"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    struct NodeConfig: Codable {
        var host: String
        var port: UInt16
        var serverSPKIHex: String
        var vaultID: Int64
        var deviceID: String
    }

    static func loadConfig() throws -> NodeConfig {
        guard let container else { throw SpikeError("no App Group container") }
        let data = try Data(contentsOf: container.appending(path: "node.json"))
        return try JSONDecoder().decode(NodeConfig.self, from: data)
    }

    static func saveConfig(_ config: NodeConfig) throws {
        guard let container else { throw SpikeError("no App Group container") }
        let data = try JSONEncoder().encode(config)
        try data.write(to: container.appending(path: "node.json"))
    }

    private static let logger = Logger(subsystem: subsystem, category: ProcessInfo.processInfo.processName)
    private static let lock = NSLock()

    /// os_log (public, spike only) plus a line in <group container>/spike.log, so the log file itself proves the
    /// process can write the shared container.
    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: .now)) [\(ProcessInfo.processInfo.processName):\(getpid())] \(message)"
        logger.notice("\(line, privacy: .public)")
        print(line)
        lock.lock(); defer { lock.unlock() }
        guard let url = container?.appending(path: "spike.log") else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    // MARK: Shared keychain item (generic password in the shared access group, data protection keychain)

    static func putSecret(_ value: String) -> OSStatus {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: secretService,
            kSecAttrAccount: "spike",
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessGroup: keychainGroup,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = Data(value.utf8)
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    static func readSecret() -> (OSStatus, String?, String?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: secretService,
            kSecAttrAccount: "spike",
            kSecUseDataProtectionKeychain: true,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let attrs = result as? [CFString: Any] else { return (status, nil, nil) }
        let value = (attrs[kSecValueData] as? Data).map { String(decoding: $0, as: UTF8.self) }
        return (status, value, attrs[kSecAttrAccessGroup] as? String)
    }

    static func deleteSecret() -> OSStatus {
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: secretService,
            kSecUseDataProtectionKeychain: true,
            kSecAttrAccessGroup: keychainGroup,
        ]
        return SecItemDelete(base as CFDictionary)
    }

    static func describe(_ status: OSStatus) -> String {
        "\(status) (\((SecCopyErrorMessageString(status, nil) as String?) ?? "?"))"
    }
}

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
