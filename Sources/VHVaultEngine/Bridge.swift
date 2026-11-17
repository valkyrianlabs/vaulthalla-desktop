import Foundation
import VLVaultfmt

// The three callback tables in Swift. Each table's ctx is an unretained pointer to a box the ``Vault`` keeps alive for
// as long as the C handle; every callback catches what it calls (nothing throws across the C boundary) and answers a
// status. Replies go through the `vl_vaultfmt_reply` the call hands over, valid only during the callback.

func string(_ p: UnsafePointer<CChar>?, _ n: Int) -> String {
    guard let p, n > 0 else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: p, count: n), as: UTF8.self)
}

func optionalString(_ p: UnsafePointer<CChar>?, _ n: Int) -> String? { p == nil ? nil : string(p, n) }

private func replyObject(_ reply: OpaquePointer?, _ o: StoredObject) {
    if let etag = o.etag { etag.withText { p, n in _ = vl_vaultfmt_reply_etag(reply, p, n) } }
    if let v = o.versionID { v.withText { p, n in _ = vl_vaultfmt_reply_version_id(reply, p, n) } }
}

private func replyBody(_ reply: OpaquePointer?, _ data: Data) -> Int32 {
    data.withUnsafeBytes { b in
        vl_vaultfmt_reply_body(reply, b.baseAddress?.assumingMemoryBound(to: UInt8.self), b.count)
    }
}

final class StoreBox: @unchecked Sendable {
    let store: any VaultStore
    private let lock = NSLock()
    private var lastFailure: String?
    init(_ store: any VaultStore) { self.store = store }

    /// The detail of the store's last failure, once (the engine's own message is a summary).
    func takeLastFailure() -> String? {
        lock.withLock {
            defer { lastFailure = nil }
            return lastFailure
        }
    }

    func run(_ body: () throws(StoreError) -> Void) -> Int32 {
        do {
            try body()
            return VaultStatus.ok
        } catch {
            switch error {
            case .failed(let m), .outcomeUnknown(let m): lock.withLock { lastFailure = m }
            default: break
            }
            return error.status
        }
    }

    static func of(_ ctx: UnsafeMutableRawPointer?) -> StoreBox { Unmanaged<StoreBox>.fromOpaque(ctx!).takeUnretainedValue() }

    func table() -> vl_vaultfmt_store_table {
        var t = vl_vaultfmt_store_table()
        t.ctx = Unmanaged.passUnretained(self).toOpaque()
        t.mode = store.versionLog ? 2 : 1  // VL_VAULTFMT_MODE_VERSION_LOG : _CONDITIONAL
        t.get = { ctx, key, keyLength, vid, vidLength, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                let o = try box.store.get(string(key, keyLength), versionID: optionalString(vid, vidLength))
                guard replyBody(reply, o.bytes) == VaultStatus.ok else { throw .failed("the reply refused a body") }
                replyObject(reply, o.object)
            }
        }
        t.get_range = { ctx, key, keyLength, vid, vidLength, offset, length, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                let r = try box.store.getRange(string(key, keyLength), versionID: optionalString(vid, vidLength),
                                               offset: offset, length: length)
                if !r.bytes.isEmpty, replyBody(reply, r.bytes) != VaultStatus.ok { throw .failed("the reply refused a body") }
                _ = vl_vaultfmt_reply_total(reply, r.total)
            }
        }
        t.head = { ctx, key, keyLength, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in replyObject(reply, try box.store.head(string(key, keyLength))) }
        }
        t.put = { ctx, key, keyLength, bytes, length, condition, ifMatch, ifMatchLength, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                let c: PutCondition = switch condition {
                case 1: .ifAbsent
                case 2: .ifMatch(string(ifMatch, ifMatchLength))
                default: .none
                }
                replyObject(reply, try box.store.put(string(key, keyLength), UnsafeRawBufferPointer(start: bytes, count: length),
                                                     condition: c))
            }
        }
        t.list = { ctx, prefix, prefixLength, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                for o in try box.store.list(prefix: string(prefix, prefixLength)) {
                    o.key.withText { k, kn in
                        o.etag.withText { e, en in
                            _ = vl_vaultfmt_reply_listed(reply, k, kn, o.size, o.lastModified, e, en)
                        }
                    }
                }
            }
        }
        t.versions = { ctx, key, keyLength, stopAt, stopLength, underPrefix, reply in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                for v in try box.store.versions(string(key, keyLength), stopAt: optionalString(stopAt, stopLength),
                                                underPrefix: underPrefix != 0) {
                    v.key.withText { k, kn in
                        v.versionID.withText { i, iN in
                            v.etag.withText { e, en in
                                _ = vl_vaultfmt_reply_version(reply, k, kn, i, iN, v.size, v.lastModified, v.deleteMarker ? 1 : 0,
                                                              e, en, v.isLatest ? 1 : 0)
                            }
                        }
                    }
                }
            }
        }
        t.remove = { ctx, key, keyLength, vid, vidLength in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                try box.store.remove(string(key, keyLength), versionID: optionalString(vid, vidLength))
            }
        }
        t.content_begin = { ctx, key, keyLength, size, upload in
            let box = StoreBox.of(ctx)
            return box.run { () throws(StoreError) in
                let u = try box.store.beginContent(string(key, keyLength), size: size == .max ? nil : size)
                upload?.pointee = Unmanaged.passRetained(UploadBox(u)).toOpaque()
            }
        }
        t.content_write = { ctx, upload, bytes, length in
            let box = StoreBox.of(ctx)
            let u = Unmanaged<UploadBox>.fromOpaque(upload!).takeUnretainedValue()
            return box.run { () throws(StoreError) in try u.upload.write(UnsafeRawBufferPointer(start: bytes, count: length)) }
        }
        t.content_finish = { ctx, upload, reply in
            let box = StoreBox.of(ctx)
            let u = Unmanaged<UploadBox>.fromOpaque(upload!).takeRetainedValue()
            return box.run { () throws(StoreError) in replyObject(reply, try u.upload.finish()) }
        }
        t.content_abort = { _, upload in
            guard let upload else { return }
            Unmanaged<UploadBox>.fromOpaque(upload).takeRetainedValue().upload.abort()
        }
        return t
    }
}

final class UploadBox {
    let upload: any ContentUpload
    init(_ upload: any ContentUpload) { self.upload = upload }
}

final class KeysBox: @unchecked Sendable {
    let keys: any VaultKeySource
    init(_ keys: any VaultKeySource) { self.keys = keys }

    func table() -> vl_vaultfmt_keys_table {
        var t = vl_vaultfmt_keys_table()
        t.ctx = Unmanaged.passUnretained(self).toOpaque()
        t.lookup = { ctx, version, key in
            let box = Unmanaged<KeysBox>.fromOpaque(ctx!).takeUnretainedValue()
            guard let key else { return VaultStatus.invalidArgument }
            do {
                return try box.keys.copyKey(version: version, into: UnsafeMutableRawBufferPointer(start: key, count: 32))
                    ? VaultStatus.ok : VaultStatus.notFound
            } catch {
                return VaultStatus.notFound
            }
        }
        t.current = { ctx, version in
            let box = Unmanaged<KeysBox>.fromOpaque(ctx!).takeUnretainedValue()
            guard let version, let v = try? box.keys.currentVersion() else { return VaultStatus.notFound }
            version.pointee = v
            return VaultStatus.ok
        }
        return t
    }
}

final class ClockBox: @unchecked Sendable {
    let now: @Sendable () -> Int64
    init(_ now: @escaping @Sendable () -> Int64) { self.now = now }
}

final class SinkBox {
    let sink: (UnsafeRawBufferPointer) -> Bool
    init(_ sink: @escaping (UnsafeRawBufferPointer) -> Bool) { self.sink = sink }
}
