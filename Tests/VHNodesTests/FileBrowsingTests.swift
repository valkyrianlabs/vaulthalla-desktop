import Foundation
import Testing
import VHContract
@testable import VHNodes

/// The file browser's path arithmetic, name rules and ordering.
@Suite struct FileBrowsingTests {
    @Test func normalizesPaths() {
        #expect(VaultPath(normalizing: "").rawValue == "/")
        #expect(VaultPath(normalizing: "/").rawValue == "/")
        #expect(VaultPath(normalizing: "docs//a.txt/").rawValue == "/docs/a.txt")
        #expect(VaultPath(normalizing: "/docs/./../a").rawValue == "/docs/a")
        #expect(VaultPath.root.isRoot)
    }

    @Test func walksPaths() {
        let path = VaultPath(normalizing: "/Photos/2026/October")
        #expect(path.name == "October")
        #expect(path.components == ["Photos", "2026", "October"])
        #expect(path.parent == VaultPath(normalizing: "/Photos/2026"))
        #expect(VaultPath.root.parent == .root)
        #expect(VaultPath.root.name == "")
        #expect(path.ancestry.map(\.rawValue) == ["/", "/Photos", "/Photos/2026", "/Photos/2026/October"])
        #expect(VaultPath.root.appending("a b/c.txt").rawValue == "/a b/c.txt")
        #expect(VaultPath(normalizing: "/Photos").contains(path))
        #expect(!VaultPath(normalizing: "/Photo").contains(path))
        #expect(VaultPath.root.contains(path))
        #expect(path.contains(path))
    }

    @Test func checksNames() {
        #expect(VaultPath.problem(withName: "Report.pdf") == nil)
        #expect(VaultPath.problem(withName: "  ") != nil)
        #expect(VaultPath.problem(withName: "a/b") != nil)
        #expect(VaultPath.problem(withName: "..") != nil)
        #expect(VaultPath.problem(withName: String(repeating: "é", count: 200)) != nil)
    }

    @Test func picksAFreeName() {
        #expect(VaultPath.uniqueName("untitled folder", taken: ["a"]) == "untitled folder")
        #expect(VaultPath.uniqueName("untitled folder", taken: ["Untitled Folder", "untitled folder 2"]) == "untitled folder 3")
        #expect(VaultPath.uniqueName("photo.jpg", taken: ["photo.jpg"], isDirectory: false) == "photo 2.jpg")
        #expect(VaultPath.uniqueName(".env", taken: [".env"], isDirectory: false) == ".env 2")
    }

    // MARK: Items and sorting

    static func entry(_ name: String, dir: Bool = false, size: Int64 = 0, updated: String = "2026-10-01T12:00:00Z",
                      mime: String? = nil, thumbnail: Bool? = nil, hidden: Bool = false) -> WsModel.FsEntry {
        WsModel.FsEntry(
            id: 1, name: name, path: "/f/\(name)", absPath: "/mnt/f/\(name)", sizeBytes: size, isHidden: hidden,
            isSystem: false, createdAt: "2026-01-01T00:00:00Z", updatedAt: updated, metadataVersion: "m1-0",
            contentVersion: dir ? nil : "\"g1-0\"", type: dir ? WsModel.FsEntry.TypeValue.directory : WsModel.FsEntry.TypeValue.file,
            mimeType: mime.map { .value($0) } ?? (dir ? nil : .null),
            preview: thumbnail.map { .init(kind: "rendered_image", renderer: "image", requires: "preview", thumbnail: $0) },
            fileCount: dir ? 3 : nil)
    }

    static func items(_ entries: [WsModel.FsEntry]) -> [FileItem] {
        entries.map { FileItem(entry: $0, in: VaultPath(normalizing: "/f")) { entry, dir in
            dir ? "Folder" : (entry.name.split(separator: ".").last.map { "\($0.uppercased()) file" } ?? "Document")
        } }
    }

    @Test func readsEntries() throws {
        let items = Self.items([
            Self.entry("Photos", dir: true, size: 999),
            Self.entry("a.jpg", size: 10, mime: "image/jpeg"),
            Self.entry("b.jpg", size: 10, mime: "image/jpeg", thumbnail: false),
            Self.entry("c.bin", size: 10),
        ])
        #expect(items[0].isDirectory)
        #expect(items[0].size == nil)
        #expect(items[0].path.rawValue == "/f/Photos")
        #expect(items.map(\.hasThumbnail) == [false, true, false, false])
        #expect(items[1].mimeType == "image/jpeg")
        #expect(try #require(items[1].modified) == Date(timeIntervalSince1970: 1790856000))
    }

    @Test func sortsLikeFinder() {
        let items = Self.items([
            Self.entry("file 10.txt", size: 5, updated: "2026-10-03T00:00:00Z"),
            Self.entry("File 2.txt", size: 50, updated: "2026-10-01T00:00:00Z"),
            Self.entry("zeta", dir: true, updated: "2026-09-01T00:00:00Z"),
            Self.entry("Alpha", dir: true, updated: "2026-10-09T00:00:00Z"),
            Self.entry("b.png", size: 20, updated: "2026-10-02T00:00:00Z"),
        ])
        let byName = FileSort(key: .name).sorted(items).map(\.name)
        #expect(byName == ["Alpha", "zeta", "b.png", "File 2.txt", "file 10.txt"])
        #expect(FileSort(key: .name, ascending: false).sorted(items).map(\.name)
            == ["zeta", "Alpha", "file 10.txt", "File 2.txt", "b.png"])
        #expect(FileSort(key: .size, ascending: false).sorted(items).map(\.name)
            == ["Alpha", "zeta", "File 2.txt", "b.png", "file 10.txt"])
        #expect(FileSort(key: .modified).sorted(items).map(\.name)
            == ["zeta", "Alpha", "File 2.txt", "b.png", "file 10.txt"])
        #expect(FileSort(key: .kind).sorted(items).map(\.name)
            == ["Alpha", "zeta", "b.png", "File 2.txt", "file 10.txt"])
        #expect(FileSort(key: .name, foldersFirst: false).sorted(items).map(\.name)
            == ["Alpha", "b.png", "File 2.txt", "file 10.txt", "zeta"])
    }

    @Test func filtersHiddenAndByName() {
        let items = Self.items([
            Self.entry(".DS_Store"), Self.entry("Café.txt"), Self.entry("secret", hidden: true), Self.entry("notes.md"),
        ])
        #expect(FileFilter.apply(items, query: "", showHidden: false).map(\.name) == ["Café.txt", "notes.md"])
        #expect(FileFilter.apply(items, query: "cafe", showHidden: false).map(\.name) == ["Café.txt"])
        #expect(FileFilter.apply(items, query: "", showHidden: true).count == 4)
    }

    /// A 10k-entry folder sorts well within a frame budget's order of magnitude (it runs off the main actor anyway).
    @Test func sortsTenThousandEntries() {
        let entries = (0..<10_000).map { index in
            Self.entry("IMG_\(String(index * 7919 % 10_000)).jpg", dir: index % 50 == 0, size: Int64(index * 37 % 9973))
        }
        let items = Self.items(entries)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let sorted = FileSort(key: .name).sorted(items)
            #expect(sorted.count == 10_000)
            #expect(sorted.first?.isDirectory == true)
        }
        #expect(elapsed < .seconds(3))
    }
}
