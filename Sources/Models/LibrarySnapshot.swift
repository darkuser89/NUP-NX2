import Foundation

struct LibraryEntry: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    let size: Int64?
    let modified: Date?
    let searchKey: String
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct LibrarySnapshot: Identifiable, Sendable {
    let id = UUID()
    let folder: URL
    let entries: [LibraryEntry]
    let warnings: [String]

    func updatingFile(_ archive: NUPArchive) -> LibrarySnapshot {
        let updated = entries.map { entry in
            guard entry.url == archive.url else { return entry }
            return LibraryEntry(url: entry.url, relativePath: entry.relativePath,
                size: Int64(clamping: archive.fileSize),
                modified: Date(timeIntervalSince1970: Double(archive.revision.modifiedSeconds) + Double(archive.revision.modifiedNanoseconds) / 1_000_000_000),
                searchKey: entry.searchKey)
        }
        return LibrarySnapshot(folder: folder, entries: updated, warnings: warnings)
    }

    func matching(_ query: String, metadata: [URL: LibraryItemMetadata] = [:]) -> [LibraryEntry] {
        let key = Self.searchKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return key.isEmpty ? entries : entries.filter {
            $0.searchKey.contains(key) || metadata[$0.url]?.searchKey?.contains(key) == true
        }
    }

    static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }
}
