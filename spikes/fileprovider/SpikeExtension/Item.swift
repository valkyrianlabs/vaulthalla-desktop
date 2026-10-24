// THROWAWAY SPIKE (vaulthalla/desktop#2). Read-only items keyed by vault path.
import FileProvider
import UniformTypeIdentifiers
import VHContract

final class Item: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let contentModificationDate: Date?
    let creationDate: Date?

    static func identifier(for path: String) -> NSFileProviderItemIdentifier {
        path == "/" || path.isEmpty ? .rootContainer : NSFileProviderItemIdentifier(path)
    }

    static func path(for identifier: NSFileProviderItemIdentifier) -> String {
        identifier == .rootContainer ? "/" : identifier.rawValue
    }

    static func root() -> Item { Item(rootNamed: "Vault") }

    private init(rootNamed name: String) {
        itemIdentifier = .rootContainer
        parentItemIdentifier = .rootContainer
        filename = name
        contentType = .folder
        documentSize = nil
        capabilities = [.allowsReading, .allowsContentEnumerating]
        itemVersion = NSFileProviderItemVersion(contentVersion: Data("root".utf8), metadataVersion: Data("root".utf8))
        contentModificationDate = nil
        creationDate = nil
    }

    init(_ entry: WsModel.FsEntry) {
        let iso = ISO8601DateFormatter()
        itemIdentifier = Item.identifier(for: entry.path)
        let parent = (entry.path as NSString).deletingLastPathComponent
        parentItemIdentifier = Item.identifier(for: parent)
        filename = entry.name
        let isDirectory = entry.type == "directory" || entry.type == "dir"
        contentType = isDirectory ? .folder : (UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data)
        documentSize = isDirectory ? nil : NSNumber(value: entry.sizeBytes)
        capabilities = isDirectory ? [.allowsReading, .allowsContentEnumerating] : [.allowsReading, .allowsEvicting]
        let version = Data("\(entry.sizeBytes)|\(entry.updatedAt)".utf8)
        itemVersion = NSFileProviderItemVersion(contentVersion: version, metadataVersion: version)
        contentModificationDate = iso.date(from: entry.updatedAt)
        creationDate = iso.date(from: entry.createdAt)
    }
}
