import Foundation

struct LibraryItemMetadata: Sendable {
    var title: String?
    var hasCover = false
    var notice: String?
}

struct LibraryMetadataResult: Sendable {
    var item: LibraryItemMetadata
    var thumbnail: Data?
}
