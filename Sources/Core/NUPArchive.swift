import Foundation

struct NUPArchive: Sendable {
    let snapshotID = UUID()
    private let browserCache = BrowserTreeCache()
    let url: URL
    var packages: [NUPPackage]
    let directories: [NUPDirectory]
    let files: [NUPFile]
    let fileSize: UInt64
    let blobOffset: UInt64
    let uuid: Data
    let header: Data
    let toc: Data
    let revision: FileRevision

    init(url: URL, context: JobContext = JobContext(), recoverPendingMetadata: Bool = true) throws {
        self.url = url
        if recoverPendingMetadata {
            try ArchiveContentJournal.recoverIfNeeded(url: url)
            try MetadataTransaction.recoverIfNeeded(url: url)
        }
        let input = try regularFile(url)
        defer { try? input.close() }
        revision = try FileRevision(handle: input)
        fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        header = try readExactly(input, 128)
        try require(try header.bytes(0, 4) == Data([78, 85, 80, 1]), "Keine unterstützte NUP-v1-Datei.")
        let headerSize = try header.uint(4, 2)
        try require(headerSize >= 128 && header.uint(6, 2) >= 1, "Ungültiger NUP-Header.")
        try require(try header.uint(64, 8) == fileSize, "Containergröße stimmt nicht mit der Datei überein.")
        try require(try header.uint(76, 4) == 0 && header.isZero(96, 32), "Unbekannte Header-Flags oder reservierte Felder.")
        let tocOffset = try header.uint(8, 8)
        let tocSize = try header.uint(16, 8)
        try require(tocOffset == headerSize, "Ungültiger TOC-Offset.")
        try bounded(tocOffset, tocSize, by: fileSize)
        // Explicit resource limits avoid allocations controlled by malformed input.
        try require(tocSize <= 256 * 1024 * 1024, "Inhaltsverzeichnis überschreitet das Limit von 256 MB.")
        blobOffset = try header.uint(56, 8)
        try require(blobOffset % 16 == 0 && blobOffset >= tocOffset + tocSize && blobOffset <= fileSize,
                    "Ungültiger Blob-Bereich.")
        try context.check()
        toc = try readRange(input, offset: tocOffset, count: integer(tocSize))
        try require(try toc.sha256 == header.bytes(24, 32), "TOC-SHA-256 stimmt nicht überein.")
        try require(try toc.bytes(0, 4) == Data([84, 79, 67, 1]), "Ungültiges Inhaltsverzeichnis.")
        let packageCount = try integer(toc.uint(4, 4))
        try require(try packageCount >= 1 && UInt64(packageCount) == header.uint(72, 4), "Ungültige Paketanzahl.")
        let dirCount = try integer(toc.uint(8, 8))
        let fileCount = try integer(toc.uint(16, 8))
        // Bound counts before multiplying, preventing integer overflow.
        try require(packageCount <= toc.count / 64 && dirCount <= toc.count / 24 && fileCount <= toc.count / 80,
                    "Knotenanzahl außerhalb des Inhaltsverzeichnisses.")
        let nodesEnd = 48 + packageCount * 64 + dirCount * 24 + fileCount * 80
        let poolOffset = try integer(toc.uint(24, 8))
        let poolSize = try integer(toc.uint(32, 8))
        // Producers may pad the TOC after the declared string pool. The full
        // TOC, including that padding, is already covered by its SHA-256.
        try require(nodesEnd <= poolOffset && poolOffset <= toc.count && poolSize <= toc.count - poolOffset &&
                    (poolOffset - nodesEnd) % 4 == 0, "Ungültiger Stringpool oder Kindknotenbereich.")
        try require(try toc.uint(40, 8) == 0, "Reserviertes TOC-Feld ist nicht null.")
        let pool = try toc.bytes(poolOffset, poolSize)
        let table = toc
        func name(at position: Int) throws -> String {
            let offset = try integer(table.uint(position, 4))
            let length = try integer(table.uint(position + 4, 4))
            guard let name = String(data: try pool.bytes(offset, length), encoding: .utf8) else {
                throw NUPError("Dateiname ist kein gültiges UTF-8.")
            }
            return name
        }
        var children: [Int] = []
        for position in stride(from: nodesEnd, to: poolOffset, by: 4) {
            let child = try integer(toc.uint(position, 4))
            try require(child < dirCount + fileCount, "Kindknoten außerhalb der Tabelle.")
            children.append(child)
        }
        var parsedPackages: [NUPPackage] = []
        var position = 48
        var metadataBytes = 0
        for index in 0..<packageCount {
            try context.check()
            var package = NUPPackage(id: index)
            package.titleID = try toc.uint(position, 8)
            package.root = try integer(toc.uint(position + 8, 4))
            let exefs = try toc.uint(position + 12, 4)
            let romfs = try toc.uint(position + 16, 4)
            package.exefs = exefs == UInt32.max ? nil : try integer(exefs)
            package.romfs = romfs == UInt32.max ? nil : try integer(romfs)
            package.version = UInt32(try toc.uint(position + 20, 4))
            package.kind = UInt8(try toc.uint(position + 24, 1))
            package.flags = UInt8(try toc.uint(position + 25, 1))
            try require(package.kind < 5 && package.flags & ~1 == 0, "Unbekannte Paketart oder Paket-Flags.")
            try require(try toc.isZero(position + 26, 6) && toc.isZero(position + 44, 20),
                        "Reserviertes Paketfeld ist nicht null.")
            package.metaOffset = try toc.uint(position + 32, 8)
            package.metaSize = try integer(toc.uint(position + 40, 4))
            try require(package.metaSize <= 64 * 1024 * 1024 && metadataBytes <= 256 * 1024 * 1024 - package.metaSize,
                        "Metadaten überschreiten das Speicherlimit.")
            metadataBytes += package.metaSize
            if package.metaSize > 0 {
                try require(package.metaOffset >= blobOffset, "Metadaten überlappen den Header oder die TOC.")
                try bounded(package.metaOffset, UInt64(package.metaSize), by: fileSize)
                package.metadata = try MetadataCodec.parse(readRange(input, offset: package.metaOffset, count: package.metaSize))
            } else {
                try require(package.metaOffset == 0, "Leere Metadaten mit ungültigem Offset.")
            }
            try require(package.root < dirCount && (package.exefs == nil || package.exefs! < dirCount) &&
                        (package.romfs == nil || package.romfs! < dirCount), "Paketwurzel außerhalb der Verzeichnistabelle.")
            parsedPackages.append(package)
            position += 64
        }
        var parsedDirectories: [NUPDirectory] = []
        var usedSlots = Set<Int>()
        for _ in 0..<dirCount {
            try context.check()
            let first = try integer(toc.uint(position + 8, 4))
            let count = try integer(toc.uint(position + 12, 4))
            try require(first <= children.count && count <= children.count - first, "Ungültiger Kindknotenbereich.")
            for slot in first..<(first + count) {
                try require(usedSlots.insert(slot).inserted, "Überlappende Kindknotenbereiche.")
            }
            try require(try toc.uint(position + 16, 8) == 0, "Reserviertes Verzeichnisfeld ist nicht null.")
            parsedDirectories.append(NUPDirectory(name: try name(at: position), children: Array(children[first..<(first + count)])))
            position += 24
        }
        try require(usedSlots.count == children.count, "Unbenutzte Kindknotenplätze.")
        var parsedFiles: [NUPFile] = []
        for _ in 0..<fileCount {
            try context.check()
            let file = NUPFile(name: try name(at: position), size: try toc.uint(position + 8, 8),
                               offset: try toc.uint(position + 16, 8), storedSize: try toc.uint(position + 24, 8),
                               hash: try toc.bytes(position + 32, 32), codec: UInt8(try toc.uint(position + 64, 1)))
            try safeName(file.name)
            try require(file.codec <= 1, "Unbekannter Kompressionscodec.")
            try require(try toc.isZero(position + 65, 15), "Unbekannte Codec-Flags oder reservierte Felder.")
            if file.size == 0 {
                try require(file.offset == 0 && file.storedSize == 0 && file.codec == 0, "Ungültige leere Datei.")
            } else {
                try require(file.offset >= blobOffset && file.offset % 16 == 0 && file.storedSize > 0,
                            "Ungültiger Dateibereich.")
                try bounded(file.offset, file.storedSize, by: fileSize)
            }
            try require(file.codec != 0 || file.storedSize == file.size, "Falsche Größe einer unkomprimierten Datei.")
            parsedFiles.append(file)
            position += 80
        }
        packages = parsedPackages
        directories = parsedDirectories
        files = parsedFiles
        uuid = try header.bytes(80, 16)
        try validateGraph(context: context)
        try validateRegions()
        var identity = Data()
        for package in packages {
            identity.appendLE(package.titleID, width: 8)
            identity.appendLE(UInt64(package.version), width: 4)
            identity.append(package.kind)
        }
        try require(Data(identity.sha256.prefix(16)) == uuid, "Paket-UUID stimmt nicht überein.")
    }

    private func validateGraph(context: JobContext) throws {
        try require(packages.filter { $0.kind == 0 }.count <= 1, "Mehrere Basispakete sind nicht zulässig.")
        let hasBase = packages.contains { $0.kind == 0 }
        var visited = Set<Int>()
        var visitedFiles = Set<Int>()
        for package in packages {
            if package.kind == 1 {
                try require(hasBase || package.flags & 1 == 1, "Update ohne Basis benötigt das Standalone-Flag.")
            }
            var stack: [(Int, Int)] = [(package.root, 0)]
            var packageDirs = Set<Int>()
            while let (index, depth) = stack.popLast() {
                try context.check()
                try require(depth <= 256, "Verzeichnisstruktur ist tiefer als 256 Ebenen.")
                try require(visited.insert(index).inserted, "Zyklus oder mehrfach referenziertes Verzeichnis.")
                packageDirs.insert(index)
                let directory = directories[index]
                try safeName(directory.name, allowEmpty: index == package.root)
                var names = Set<Data>()
                var previous: Data?
                for child in directory.children {
                    let name = child < directories.count ? directories[child].name : files[child - directories.count].name
                    let bytes = Data(name.utf8)
                    try require(names.insert(bytes).inserted, "Doppelte Dateinamen im Verzeichnis.")
                    if let previous { try require(previous.lexicographicallyPrecedes(bytes), "Kindknoten sind nicht nach UTF-8 sortiert.") }
                    previous = bytes
                    if child < directories.count { stack.append((child, depth + 1)) }
                    else { try require(visitedFiles.insert(child - directories.count).inserted, "Mehrfach referenzierter Dateiknoten.") }
                }
            }
            for content in [package.exefs, package.romfs].compactMap({ $0 }) {
                try require(packageDirs.contains(content) && content != package.root, "Content-Verzeichnis liegt außerhalb des Pakets.")
            }
        }
        try require(visited.count == directories.count && visitedFiles.count == files.count, "Nicht erreichbare Knoten im Inhaltsverzeichnis.")
    }

    private func validateRegions() throws {
        struct Region { var offset: UInt64; var size: UInt64; var key: String }
        var regions: [Region] = files.filter { $0.storedSize > 0 }.map {
            Region(offset: $0.offset, size: $0.storedSize, key: "\($0.size):\($0.codec):\($0.hash.hex)")
        }
        regions += packages.filter { $0.metaSize > 0 }.map {
            Region(offset: $0.metaOffset, size: UInt64($0.metaSize), key: "meta:\($0.id)")
        }
        regions.sort { $0.offset == $1.offset ? $0.size < $1.size : $0.offset < $1.offset }
        var last: Region?
        for region in regions {
            if let previous = last, previous.offset + previous.size > region.offset {
                try require(previous.offset == region.offset && previous.size == region.size && previous.key == region.key,
                            "Überlappende Datenbereiche oder widersprüchliche Deduplizierung.")
            }
            last = region
        }
    }

    func browserNodes(package index: Int) -> [BrowserNode] {
        browserCache.nodes(package: packages[index].root) { buildBrowserNodes(package: index) }
    }

    private func buildBrowserNodes(package index: Int) -> [BrowserNode] {
        func node(_ id: Int) -> BrowserNode {
            if id < directories.count {
                let dir = directories[id]
                return BrowserNode(id: id, name: dir.name, children: dir.children.map(node))
            }
            let file = files[id - directories.count]
            return BrowserNode(id: id, name: file.name, size: file.size, storedSize: file.storedSize, codec: file.codec)
        }
        return directories[packages[index].root].children.map(node)
    }

    func verify(deep: Bool, context: JobContext) throws {
        let current = try NUPArchive(url: url, context: context)
        try require(current.header == header && current.toc == toc, "Container wurde seit dem Öffnen verändert. Bitte erneut öffnen.")
        guard deep else { return }
        let input = try regularFile(url)
        defer { try? input.close() }
        for (index, file) in files.enumerated() {
            try context.report(Double(index) / Double(max(1, files.count)), "Prüfe \(file.name)")
            try StreamCodec.consume(file, input: input, context: context)
        }
        try context.report(1, "Alle \(files.count) Dateien geprüft.")
    }
}
