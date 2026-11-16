import Foundation

struct ArchivePendingFile: Identifiable, Sendable {
    let id = UUID()
    let nodeID: Int
    let package: Int
    let directory: Int
    let url: URL
    let revision: FileRevision
    var name: String { url.lastPathComponent.precomposedStringWithCanonicalMapping }
}

struct ArchiveEditDraft: Sendable {
    private(set) var archive: NUPArchive
    var packages: [ArchivePackageDraft]
    private(set) var additions: [ArchivePendingFile] = []
    private(set) var removals: Set<Int> = []
    private(set) var fileRevision = UUID()
    private var nextNodeID = -1

    init(archive: NUPArchive) { self.archive = archive; packages = archive.packages.map(ArchivePackageDraft.init) }
    mutating func rebase(on recovered: NUPArchive) throws {
        try require(recovered.url.standardizedFileURL == archive.url.standardizedFileURL &&
                    recovered.revision.device == archive.revision.device && recovered.revision.inode == archive.revision.inode &&
                    recovered.fileSize == archive.fileSize && recovered.header == archive.header && recovered.toc == archive.toc,
                    L10n.text("Der zurückgenommene Stand entspricht nicht dem Entwurf."))
        archive = recovered; fileRevision = UUID()
    }
    var hasChanges: Bool { packages.contains(where: \.hasChanges) || !additions.isEmpty || !removals.isEmpty }
    var validationError: String? {
        for (index, package) in packages.enumerated() {
            if let error = package.validationError { return L10n.text("Paket \(String(describing: index + 1)): \(String(describing: error))") }
        }
        return nil
    }
    var summary: String {
        let edited = packages.filter(\.hasChanges).count
        return L10n.text("\(String(describing: edited)) Paket(e) bearbeitet · \(String(describing: additions.count)) Datei(en) hinzugefügt · \(String(describing: removals.count)) entfernt — noch nicht gespeichert")
    }
    mutating func stageFiles(package: Int, directory: Int, urls: [URL], removing: Set<Int> = []) throws {
        try require(archive.packages.indices.contains(package) && archive.directories.indices.contains(directory) && archive.owns(node: directory, package: package), L10n.text("Zielordner gehört nicht zum Paket."))
        try require(removing.allSatisfy { archive.files.indices.contains($0) && archive.owns(node: archive.directories.count + $0, package: package) }, L10n.text("Datei gehört nicht zum ausgewählten Paket."))
        var candidate = self
        candidate.removals.formUnion(removing)
        for url in urls {
            try require(url.isFileURL, L10n.text("Nur lokale Dateien können hinzugefügt werden."))
            let input = try regularFile(url); defer { try? input.close() }
            let revision = try FileRevision(handle: input)
            try require(revision.device != archive.revision.device || revision.inode != archive.revision.inode, L10n.text("Die NUP kann nicht in sich selbst eingefügt werden."))
            candidate.additions.append(ArchivePendingFile(nodeID: candidate.nextNodeID, package: package, directory: directory, url: url, revision: revision))
            candidate.nextNodeID -= 1
        }
        // Validate the whole staged file list, including earlier target folders.
        let request = try candidate.request(includeMetadata: false)
        try ArchiveFilePlan.validateTargets(archive: archive, groups: request.files.map {
            ArchiveFilePlanGroup(package: $0.package, directory: $0.directory,
                additions: $0.additions.map { NUPFile(name: $0.lastPathComponent.precomposedStringWithCanonicalMapping) }, removing: $0.removing)
        }, stageSize: 0)
        candidate.fileRevision = UUID(); self = candidate
    }
    mutating func removePending(nodes: Set<Int>) {
        additions.removeAll { nodes.contains($0.nodeID) }; fileRevision = UUID()
    }
    mutating func restoreFiles(_ indices: Set<Int>) { removals.subtract(indices); fileRevision = UUID() }

    func request(includeMetadata: Bool = true) throws -> ArchiveEditRequest {
        var request = ArchiveEditRequest(), groups: [Int: ArchiveFileMutation] = [:]
        for file in additions {
            if groups[file.directory] == nil { groups[file.directory] = ArchiveFileMutation(package: file.package, directory: file.directory) }
            if let earlier = request.sourceRevisions[file.url] {
                try require(earlier == file.revision, L10n.text("Eine Quelldatei wurde zwischen zwei Auswahlen verändert. Bitte neu auswählen."))
            }
            groups[file.directory]!.additions.append(file.url); request.sourceRevisions[file.url] = file.revision
        }
        for index in removals {
            guard archive.files.indices.contains(index), let package = archive.packages.first(where: {
                archive.owns(node: archive.directories.count + index, package: $0.id)
            }) else { throw NUPError(L10n.text("Datei gehört nicht zu diesem Archiv.")) }
            if groups[package.root] == nil { groups[package.root] = ArchiveFileMutation(package: package.id, directory: package.root) }
            groups[package.root]!.removing.insert(index)
        }
        request.files = groups.keys.sorted().map { groups[$0]! }
        if includeMetadata {
            for (index, draft) in packages.enumerated() where draft.hasChanges {
                let records = try draft.metadata()
                if records != archive.packages[index].metadata { request.metadata[index] = records }
            }
        }
        return request
    }

    func nodes(package: Int, query: String) -> [BrowserNode] {
        let grouped = Dictionary(grouping: additions.filter { $0.package == package }, by: \.directory)
        func append(_ node: BrowserNode) -> BrowserNode {
            guard let children = node.children else { return node }
            var result = node
            let added = (grouped[node.id] ?? []).map {
                BrowserNode(id: $0.nodeID, name: $0.name, size: UInt64(clamping: $0.revision.size))
            }
            let existing = children.map(append)
            result.children = added.isEmpty ? existing : (existing + added).sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
            return result
        }
        var nodes = archive.browserNodes(package: package)
        if !grouped.isEmpty {
            nodes = nodes.map(append)
            // The package root itself is not displayed as a row.
            nodes += (grouped[archive.packages[package].root] ?? []).map {
                BrowserNode(id: $0.nodeID, name: $0.name, size: UInt64(clamping: $0.revision.size))
            }
            nodes.sort { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        }
        return BrowserTreeSearch.matching(nodes, query: query)
    }
}
