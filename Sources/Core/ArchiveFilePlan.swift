import Foundation

struct ArchiveFileLocation {
    let directory: Int
    let path: String
}

/// Rebuild only the TOC. Existing compressed extents keep their bytes and, where
/// possible, their offsets. Only extents overtaken by the growing TOC move to EOF.
struct ArchiveFilePlan {
    struct Extent: Hashable { let offset: UInt64; let count: UInt64 }
    struct Move { let source: Extent; let destination: UInt64 }
    let header: Data
    let toc: Data
    let moves: [Move]
    let stageOffset: UInt64
    let stageSize: UInt64
    let addedIndices: [Int]
    let prefixSize: UInt64
    let metadataWrites: [(offset: UInt64, data: Data)]

    init(archive: NUPArchive, package: Int, directory: Int, additions: [NUPFile], stageSize: UInt64,
         removing: Set<Int>) throws {
        try self.init(archive: archive, groups: [ArchiveFilePlanGroup(package: package, directory: directory,
            additions: additions, removing: removing)], stageSize: stageSize)
    }

    init(archive: NUPArchive, groups: [ArchiveFilePlanGroup], stageSize: UInt64,
         metadata: [Int: [UInt16: Data]] = [:]) throws {
        try require(metadata.keys.allSatisfy { archive.packages.indices.contains($0) }, "Metadaten-Paket existiert nicht.")
        try Self.validateTargets(archive: archive, groups: groups, stageSize: stageSize)
        let removing = groups.reduce(into: Set<Int>()) { $0.formUnion($1.removing) }
        var files: [NUPFile] = [], remap: [Int: Int] = [:]
        for index in archive.files.indices where !removing.contains(index) {
            remap[index] = files.count; files.append(archive.files[index])
        }
        let retainedCount = files.count, dc = archive.directories.count
        var dirs = archive.directories
        for id in dirs.indices {
            dirs[id].children = dirs[id].children.compactMap { child in
                child < dc ? child : remap[child - dc].map { dc + $0 }
            }
        }
        for group in groups {
            let added = Array(files.count..<(files.count + group.additions.count))
            files.append(contentsOf: group.additions)
            dirs[group.directory].children += added.map { dc + $0 }
            if !added.isEmpty {
                let sorted = dirs[group.directory].children.sorted { a, b in
                    let x = a < dc ? dirs[a].name : files[a - dc].name
                    let y = b < dc ? dirs[b].name : files[b - dc].name
                    return x.utf8.lexicographicallyPrecedes(y.utf8)
                }
                dirs[group.directory].children = sorted
            }
        }
        addedIndices = Array(retainedCount..<files.count)
        try require(dc + files.count <= Int(UInt32.max), "Zu viele Dateiknoten.")
        var packages = archive.packages, blocks: [Int: Data] = [:], totalMetadata = 0
        for index in packages.indices {
            if let replacement = metadata[index] {
                let block = try MetadataCodec.serialize(replacement)
                try require(block.count <= MetadataTransaction.metadataLimit, "Metadaten überschreiten das Paketlimit.")
                blocks[index] = block; packages[index].metaSize = block.count
            }
            totalMetadata += packages[index].metaSize
            try require(totalMetadata <= 256 * 1024 * 1024, "Metadaten überschreiten das Speicherlimit.")
        }
        let tocStart = try archive.header.uint(8, 8)
        let changesFiles = groups.contains { !$0.additions.isEmpty || !$0.removing.isEmpty }
        var rebuiltTOC = changesFiles ? try Self.serialize(packages: packages, directories: dirs, files: files) : archive.toc
        let tocSize = rebuiltTOC.count
        let blob = max(archive.blobOffset, try aligned(tocStart + UInt64(tocSize)))
        var cursor = max(archive.fileSize, blob), relocations: [Extent: UInt64] = [:], moves: [Move] = []
        func relocate(_ extent: Extent) throws -> UInt64 {
            if let existing = relocations[extent] { return existing }
            cursor = try aligned(cursor)
            let destination = cursor
            cursor = try Self.end(cursor, extent.count)
            relocations[extent] = destination; moves.append(Move(source: extent, destination: destination))
            return destination
        }
        for index in 0..<retainedCount where files[index].storedSize > 0 && files[index].offset < blob {
            files[index].offset = try relocate(Extent(offset: files[index].offset, count: files[index].storedSize))
        }
        for index in packages.indices where blocks[index] == nil && packages[index].metaSize > 0 && packages[index].metaOffset < blob {
            // Metadata outside the growing TOC need not move for metadata-only edits.
            if changesFiles { packages[index].metaOffset = try relocate(Extent(offset: packages[index].metaOffset, count: UInt64(packages[index].metaSize))) }
        }
        self.stageSize = stageSize
        stageOffset = stageSize > 0 ? try aligned(cursor) : cursor
        cursor = try Self.end(stageOffset, stageSize)
        for index in addedIndices where files[index].storedSize > 0 { files[index].offset = try Self.end(stageOffset, files[index].offset) }
        var writes: [(offset: UInt64, data: Data)] = []
        for index in blocks.keys.sorted() {
            let block = blocks[index]!
            packages[index].metaOffset = block.isEmpty ? 0 : cursor
            if !block.isEmpty { writes.append((cursor, block)); cursor = try Self.end(cursor, UInt64(block.count)) }
        }
        metadataWrites = writes; self.moves = moves
        for index in packages.indices { NUPWriter.putPackage(packages[index], into: &rebuiltTOC, at: 48 + index * 64) }
        let fileStart = 48 + packages.count * 64 + dirs.count * 24
        for index in files.indices { rebuiltTOC.put(files[index].offset, at: fileStart + index * 80 + 16, width: 8) }
        toc = rebuiltTOC
        var header = archive.header
        header.put(UInt64(toc.count), at: 16, width: 8); header.put(toc.sha256, at: 24)
        header.put(blob, at: 56, width: 8); header.put(cursor, at: 64, width: 8)
        self.header = header
        prefixSize = min(archive.fileSize, tocStart + UInt64(max(archive.toc.count, toc.count)))
    }

    /// Staging needs ownership/name checks, not a full TOC rebuild on the UI thread.
    static func validateTargets(archive: NUPArchive, groups: [ArchiveFilePlanGroup], stageSize: UInt64) throws {
        try require(Set(groups.map(\.directory)).count == groups.count, "Zielordner wurde mehrfach angegeben.")
        let removing = groups.reduce(into: Set<Int>()) { $0.formUnion($1.removing) }
        for group in groups {
            try require(archive.packages.indices.contains(group.package), "Paket existiert nicht.")
            try require(archive.directories.indices.contains(group.directory) && archive.owns(node: group.directory, package: group.package),
                        "Zielordner gehört nicht zum ausgewählten Paket.")
            try require(group.removing.allSatisfy { archive.files.indices.contains($0) &&
                        archive.owns(node: archive.directories.count + $0, package: group.package) },
                        "Die ausgewählte Datei gehört nicht zum Paket.")
            var names = Set(archive.directories[group.directory].children.compactMap { child -> String? in
                if child >= archive.directories.count && removing.contains(child - archive.directories.count) { return nil }
                return (child < archive.directories.count ? archive.directories[child].name : archive.files[child - archive.directories.count].name)
                    .precomposedStringWithCanonicalMapping.lowercased()
            })
            for file in group.additions {
                try safeName(file.name)
                try require(names.insert(file.name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                            "Der Name existiert im Zielordner bereits: \(file.name). Bitte zuerst entfernen oder die Quelldatei umbenennen.")
                if file.storedSize > 0 { try bounded(file.offset, file.storedSize, by: stageSize) }
            }
        }
    }

    private static func end(_ offset: UInt64, _ count: UInt64) throws -> UInt64 {
        try require(count <= UInt64(Int64.max) && offset <= UInt64(Int64.max) - count, "Container wird zu groß.")
        return offset + count
    }

    private static func serialize(packages: [NUPPackage], directories: [NUPDirectory], files: [NUPFile]) throws -> Data {
        var pool = Data(), names: [String: Int] = [:]
        for name in directories.map(\.name) + files.map(\.name) where names[name] == nil {
            names[name] = pool.count; pool.append(Data(name.utf8))
        }
        let size = 48 + packages.count * 64 + directories.count * 24 + files.count * 80 +
            directories.reduce(0) { $0 + $1.children.count } * 4 + pool.count
        try require(size <= 256 * 1024 * 1024, "Inhaltsverzeichnis überschreitet 256 MiB.")
        var toc = Data(count: size)
        toc.put(Data([84,79,67,1]), at: 0)
        toc.put(UInt64(packages.count), at: 4, width: 4)
        toc.put(UInt64(directories.count), at: 8, width: 8)
        toc.put(UInt64(files.count), at: 16, width: 8)
        var position = 48, slot = 0
        for package in packages { NUPWriter.putPackage(package, into: &toc, at: position); position += 64 }
        for dir in directories {
            toc.put(UInt64(names[dir.name]!), at: position, width: 4)
            toc.put(UInt64(dir.name.utf8.count), at: position + 4, width: 4)
            toc.put(UInt64(slot), at: position + 8, width: 4)
            toc.put(UInt64(dir.children.count), at: position + 12, width: 4)
            slot += dir.children.count; position += 24
        }
        for file in files {
            toc.put(UInt64(names[file.name]!), at: position, width: 4)
            toc.put(UInt64(file.name.utf8.count), at: position + 4, width: 4)
            toc.put(file.size, at: position + 8, width: 8)
            toc.put(file.offset, at: position + 16, width: 8)
            toc.put(file.storedSize, at: position + 24, width: 8)
            toc.put(file.hash, at: position + 32)
            toc.put(UInt64(file.codec), at: position + 64, width: 1)
            position += 80
        }
        for dir in directories {
            for child in dir.children { toc.put(UInt64(child), at: position, width: 4); position += 4 }
        }
        toc.put(UInt64(position), at: 24, width: 8)
        toc.put(UInt64(pool.count), at: 32, width: 8)
        toc.put(pool, at: position)
        return toc
    }
}
