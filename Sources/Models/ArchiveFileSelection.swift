import Foundation

struct ArchiveFileSelection: Identifiable {
    let id = UUID()
    let snapshot: UUID
    let package: Int
    let nodes: Set<Int>
}
