import Foundation

struct LibraryItemMetadata: Sendable {
    let id = UUID()
    var title: String? {
        didSet { searchKey = title.map(LibrarySnapshot.searchKey) }
    }
    var hasCover = false
    var notice: String?
    private(set) var searchKey: String?

    init(title: String? = nil, hasCover: Bool = false, notice: String? = nil) {
        self.title = title
        self.hasCover = hasCover
        self.notice = notice
        searchKey = title.map(LibrarySnapshot.searchKey)
    }
}

struct LibraryMetadataResult: Sendable {
    var item: LibraryItemMetadata
    var thumbnail: Data?
}
