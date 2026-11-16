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
    let permitsEditing: Bool
    let romfsRepairs: [ArchiveROMFSRepair]
    private var nodeParents: [Int] = []
    private var nodePackages: [Int] = []

    init(url: URL, context: JobContext = JobContext(), recoverPendingMetadata: Bool = true,
         validation: ArchiveValidation = .strict, repairLayout: ArchiveRepairLayout? = nil) throws {
        self.url = url
        permitsEditing = validation == .strict && repairLayout == nil
        try require(repairLayout == nil || !recoverPendingMetadata, L10n.text("Eine Reparaturvorschau darf keine Wiederherstellung auslösen."))
        if recoverPendingMetadata {
            try ArchiveRepairJournal.recoverIfNeeded(url: url)
            try ArchiveContentJournal.recoverIfNeeded(url: url)
            try MetadataTransaction.recoverIfNeeded(url: url)
        }
        let input = try regularFile(url)
        defer { try? input.close() }
        revision = try FileRevision(handle: input)
        fileSize = try input.seekToEnd()
        try input.seek(toOffset: 0)
        header = try repairLayout?.header ?? readExactly(input, 128)
        try require(header.count == 128, L10n.text("Ungültige Headergröße."))
        try require(try header.bytes(0, 4) == Data([78, 85, 80, 1]), L10n.text("Keine unterstützte NUP-v1-Datei."))
        let headerSize = try header.uint(4, 2)
        try require(headerSize >= 128 && header.uint(6, 2) >= 1, L10n.text("Ungültiger NUP-Header."))
        try require(try header.uint(64, 8) == fileSize, L10n.text("Containergröße stimmt nicht mit der Datei überein."))
        try require(try header.uint(76, 4) == 0 && header.isZero(96, 32), L10n.text("Unbekannte Header-Flags oder reservierte Felder."))
        let tocOffset = try header.uint(8, 8)
        let tocSize = try header.uint(16, 8)
        try require(tocOffset == headerSize, L10n.text("Ungültiger TOC-Offset."))
        try bounded(tocOffset, tocSize, by: fileSize)
        // Explicit resource limits avoid allocations controlled by malformed input.
        try require(tocSize <= 256 * 1024 * 1024, L10n.text("Inhaltsverzeichnis überschreitet das Limit von 256 MB."))
        blobOffset = try header.uint(56, 8)
        try require(blobOffset % 16 == 0 && blobOffset >= tocOffset + tocSize && blobOffset <= fileSize,
                    L10n.text("Ungültiger Blob-Bereich."))
        try context.check()
        toc = try repairLayout?.toc ?? readRange(input, offset: tocOffset, count: integer(tocSize))
        try require(UInt64(toc.count) == tocSize, L10n.text("TOC-Größe stimmt nicht überein."))
        try require(try toc.sha256 == header.bytes(24, 32), L10n.text("TOC-SHA-256 stimmt nicht überein."))
        try require(try toc.bytes(0, 4) == Data([84, 79, 67, 1]), L10n.text("Ungültiges Inhaltsverzeichnis."))
        let packageCount = try integer(toc.uint(4, 4))
        try require(try packageCount >= 1 && UInt64(packageCount) == header.uint(72, 4), L10n.text("Ungültige Paketanzahl."))
        let dirCount = try integer(toc.uint(8, 8))
        let fileCount = try integer(toc.uint(16, 8))
        // Bound counts before multiplying, preventing integer overflow.
        try require(packageCount <= toc.count / 64 && dirCount <= toc.count / 24 && fileCount <= toc.count / 80,
                    L10n.text("Knotenanzahl außerhalb des Inhaltsverzeichnisses."))
        let nodesEnd = 48 + packageCount * 64 + dirCount * 24 + fileCount * 80
        let poolOffset = try integer(toc.uint(24, 8))
        let poolSize = try integer(toc.uint(32, 8))
        // Producers may pad the TOC after the declared string pool. The full
        // TOC, including that padding, is already covered by its SHA-256.
        try require(nodesEnd <= poolOffset && poolOffset <= toc.count && poolSize <= toc.count - poolOffset &&
                    (poolOffset - nodesEnd) % 4 == 0, L10n.text("Ungültiger Stringpool oder Kindknotenbereich."))
        try require(try toc.uint(40, 8) == 0, L10n.text("Reserviertes TOC-Feld ist nicht null."))
        let pool = try toc.bytes(poolOffset, poolSize)
        let table = toc
        func name(at position: Int) throws -> String {
            let offset = try integer(table.uint(position, 4))
            let length = try integer(table.uint(position + 4, 4))
            guard let name = String(data: try pool.bytes(offset, length), encoding: .utf8) else {
                throw NUPError(L10n.text("Dateiname ist kein gültiges UTF-8."))
            }
            return name
        }
        var children: [Int] = []
        children.reserveCapacity((poolOffset - nodesEnd) / 4)
        for position in stride(from: nodesEnd, to: poolOffset, by: 4) {
            let child = try integer(toc.uint(position, 4))
            try require(child < dirCount + fileCount, L10n.text("Kindknoten außerhalb der Tabelle."))
            children.append(child)
        }
        var parsedPackages: [NUPPackage] = []
        parsedPackages.reserveCapacity(packageCount)
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
            try require(package.kind < 5 && package.flags & ~1 == 0, L10n.text("Unbekannte Paketart oder Paket-Flags."))
            try require(try toc.isZero(position + 26, 6) && toc.isZero(position + 44, 20),
                        L10n.text("Reserviertes Paketfeld ist nicht null."))
            package.metaOffset = try toc.uint(position + 32, 8)
            package.metaSize = try integer(toc.uint(position + 40, 4))
            try require(package.metaSize <= 64 * 1024 * 1024 && metadataBytes <= 256 * 1024 * 1024 - package.metaSize,
                        L10n.text("Metadaten überschreiten das Speicherlimit."))
            metadataBytes += package.metaSize
            if package.metaSize > 0 {
                // SPEC §3.1/§5 gives metadata an absolute offset, independently
                // of the file-extents blob. It may occupy the post-TOC gap.
                try require(package.metaOffset >= tocOffset + tocSize, L10n.text("Metadaten überlappen den Header oder die TOC."))
                try bounded(package.metaOffset, UInt64(package.metaSize), by: fileSize)
                package.metadata = try MetadataCodec.parse(readRange(input, offset: package.metaOffset, count: package.metaSize))
            } else {
                try require(package.metaOffset == 0, L10n.text("Leere Metadaten mit ungültigem Offset."))
            }
            try require(package.root < dirCount && (package.exefs == nil || package.exefs! < dirCount) &&
                        (package.romfs == nil || package.romfs! < dirCount), L10n.text("Paketwurzel außerhalb der Verzeichnistabelle."))
            parsedPackages.append(package)
            position += 64
        }
        var parsedDirectories: [NUPDirectory] = []
        parsedDirectories.reserveCapacity(dirCount)
        var usedSlots = Array(repeating: false, count: children.count)
        var usedSlotCount = 0
        for _ in 0..<dirCount {
            try context.check()
            let first = try integer(toc.uint(position + 8, 4))
            let count = try integer(toc.uint(position + 12, 4))
            try require(first <= children.count && count <= children.count - first, L10n.text("Ungültiger Kindknotenbereich."))
            for slot in first..<(first + count) {
                try require(!usedSlots[slot], L10n.text("Überlappende Kindknotenbereiche."))
                usedSlots[slot] = true
            }
            usedSlotCount += count
            try require(try toc.uint(position + 16, 8) == 0, L10n.text("Reserviertes Verzeichnisfeld ist nicht null."))
            parsedDirectories.append(NUPDirectory(name: try name(at: position), children: Array(children[first..<(first + count)])))
            position += 24
        }
        if usedSlotCount != children.count && validation == .packageDiagnosis {
            romfsRepairs = try ArchiveROMFSRecovery.inspect(toc: toc, packages: parsedPackages,
                directories: &parsedDirectories, children: children, used: usedSlots, context: context)
        } else {
            try require(usedSlotCount == children.count, L10n.text("Unbenutzte Kindknotenplätze."))
            romfsRepairs = []
        }
        var parsedFiles: [NUPFile] = []
        parsedFiles.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            try context.check()
            let file = NUPFile(name: try name(at: position), size: try toc.uint(position + 8, 8),
                               offset: try toc.uint(position + 16, 8), storedSize: try toc.uint(position + 24, 8),
                               hash: try toc.bytes(position + 32, 32), codec: UInt8(try toc.uint(position + 64, 1)))
            try safeName(file.name)
            try require(file.codec <= 1, L10n.text("Unbekannter Kompressionscodec."))
            try require(try toc.isZero(position + 65, 15), L10n.text("Unbekannte Codec-Flags oder reservierte Felder."))
            if file.size == 0 {
                try require(file.offset == 0 && file.storedSize == 0 && file.codec == 0, L10n.text("Ungültige leere Datei."))
            } else {
                try require(file.offset >= blobOffset && file.offset % 16 == 0 && file.storedSize > 0,
                            L10n.text("Ungültiger Dateibereich."))
                try bounded(file.offset, file.storedSize, by: fileSize)
            }
            try require(file.codec != 0 || file.storedSize == file.size, L10n.text("Falsche Größe einer unkomprimierten Datei."))
            parsedFiles.append(file)
            position += 80
        }
        packages = parsedPackages
        directories = parsedDirectories
        files = parsedFiles
        uuid = try header.bytes(80, 16)
        try validateGraph(context: context, validation: validation)
        try validateRegions(context: context)
        var identity = Data()
        for package in packages {
            identity.appendLE(package.titleID, width: 8)
            identity.appendLE(UInt64(package.version), width: 4)
            identity.append(package.kind)
        }
        if validation == .strict {
            try require(Data(identity.sha256.prefix(16)) == uuid, L10n.text("Paket-UUID stimmt nicht überein."))
        }
    }

    private mutating func validateGraph(context: JobContext, validation: ArchiveValidation) throws {
        if validation == .strict {
            try require(packages.filter { $0.kind == 0 }.count <= 1, L10n.text("Mehrere Basispakete sind nicht zulässig."))
        }
        let hasBase = packages.contains { $0.kind == 0 }
        nodeParents = Array(repeating: -1, count: directories.count + files.count)
        nodePackages = Array(repeating: -1, count: nodeParents.count)
        var visitedCount = 0
        for package in packages {
            if package.kind == 1 && validation == .strict {
                try require(hasBase || package.flags & 1 == 1, L10n.text("Update ohne Basis benötigt das Standalone-Flag."))
            }
            var stack: [(Int, Int)] = [(package.root, 0)]
            while let (index, depth) = stack.popLast() {
                try context.check()
                try require(depth <= 256, L10n.text("Verzeichnisstruktur ist tiefer als 256 Ebenen."))
                try require(nodePackages[index] == -1, L10n.text("Zyklus oder mehrfach referenziertes Verzeichnis."))
                nodePackages[index] = package.id
                visitedCount += 1
                let directory = directories[index]
                try safeName(directory.name, allowEmpty: index == package.root)
                var previous: String.UTF8View?
                for child in directory.children {
                    let name = child < directories.count ? directories[child].name : files[child - directories.count].name
                    let bytes = name.utf8
                    if let previous, !previous.lexicographicallyPrecedes(bytes) {
                        if previous.elementsEqual(bytes) { throw NUPError(L10n.text("Doppelte Dateinamen im Verzeichnis.")) }
                        throw NUPError(L10n.text("Kindknoten sind nicht nach UTF-8 sortiert."))
                    }
                    previous = bytes
                    nodeParents[child] = index
                    if child < directories.count { stack.append((child, depth + 1)) }
                    else {
                        try require(nodePackages[child] == -1, L10n.text("Mehrfach referenzierter Dateiknoten."))
                        nodePackages[child] = package.id
                        visitedCount += 1
                    }
                }
            }
            for content in [package.exefs, package.romfs].compactMap({ $0 }) {
                try require(nodePackages[content] == package.id && content != package.root, L10n.text("Content-Verzeichnis liegt außerhalb des Pakets."))
            }
        }
        try require(visitedCount == nodePackages.count, L10n.text("Nicht erreichbare Knoten im Inhaltsverzeichnis."))
    }

    private func validateRegions(context: JobContext) throws {
        struct Region { let offset: UInt64; let size: UInt64; let file: Int? }
        var regions: [Region] = []
        regions.reserveCapacity(files.count + packages.count)
        for index in files.indices where files[index].storedSize > 0 {
            try context.check()
            regions.append(Region(offset: files[index].offset, size: files[index].storedSize, file: index))
        }
        regions += packages.filter { $0.metaSize > 0 }.map {
            Region(offset: $0.metaOffset, size: UInt64($0.metaSize), file: nil)
        }
        regions.sort { $0.offset == $1.offset ? $0.size < $1.size : $0.offset < $1.offset }
        var last: Region?
        for region in regions {
            try context.check()
            if let previous = last, previous.offset + previous.size > region.offset {
                guard previous.offset == region.offset, previous.size == region.size,
                      let a = previous.file, let b = region.file,
                      files[a].size == files[b].size, files[a].codec == files[b].codec,
                      files[a].hash == files[b].hash else {
                    throw NUPError(L10n.text("Überlappende Datenbereiche oder widersprüchliche Deduplizierung."))
                }
            }
            last = region
        }
    }

    func owns(node: Int, package: Int) -> Bool {
        packages.indices.contains(package) && nodePackages.indices.contains(node) && nodePackages[node] == package
    }

    func packageForNode(_ node: Int) -> Int? {
        guard nodePackages.indices.contains(node), nodePackages[node] >= 0 else { return nil }
        return nodePackages[node]
    }

    /// Validation builds parent/owner tables once, off the UI thread. Lookups
    /// then follow at most 256 parents instead of walking every file again.
    func fileLocation(node: Int, package: Int) -> ArchiveFileLocation? {
        guard owns(node: node, package: package) else { return nil }
        let directory = node < directories.count ? node : nodeParents[node]
        var current = directory, components: [String] = []
        while current != packages[package].root {
            components.append(directories[current].name)
            current = nodeParents[current]
        }
        return ArchiveFileLocation(directory: directory, path: "/" + components.reversed().joined(separator: "/"))
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
        try require(current.header == header && current.toc == toc, L10n.text("Container wurde seit dem Öffnen verändert. Bitte erneut öffnen."))
        guard deep else { return }
        let input = try regularFile(url)
        defer { try? input.close() }
        for (index, file) in files.enumerated() {
            try context.report(Double(index) / Double(max(1, files.count)), .localized("Prüfe \(String(describing: file.name))"))
            try StreamCodec.consume(file, input: input, context: context)
        }
        try context.report(1, .localized("Alle \(String(describing: files.count)) Dateien geprüft."))
    }
}
