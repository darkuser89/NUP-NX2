import Foundation

/// Parsed archives are immutable snapshots. Share their trees across SwiftUI updates.
final class BrowserTreeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var trees: [Int: [BrowserNode]] = [:]

    func nodes(package: Int, build: () -> [BrowserNode]) -> [BrowserNode] {
        lock.lock()
        defer { lock.unlock() }
        if let tree = trees[package] { return tree }
        let tree = build()
        trees[package] = tree
        return tree
    }
}

enum BrowserTreeSearch {
    static func matching(_ nodes: [BrowserNode], query: String) -> [BrowserNode] {
        guard !query.isEmpty else { return nodes }
        func filter(_ node: BrowserNode) -> BrowserNode? {
            if node.name.localizedCaseInsensitiveContains(query) { return node }
            if let children = node.children {
                let filtered = children.compactMap(filter)
                if !filtered.isEmpty { var copy = node; copy.children = filtered; return copy }
            }
            return nil
        }
        return nodes.compactMap(filter)
    }
}
