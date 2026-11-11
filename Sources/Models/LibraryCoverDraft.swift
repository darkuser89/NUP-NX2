import Foundation

struct LibraryCoverDraft: Identifiable, Sendable {
    let id = UUID()
    let archive: NUPArchive
    let packageIndex: Int
}

struct LibraryCoverImage: Sendable {
    let data: Data
    let thumbnail: Data
}
