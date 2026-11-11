import Foundation

enum NUPWriter {
    static func pack(source: URL, destination: URL, options: PackOptions, context: JobContext) throws {
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let canonicalDestination = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent).path
        try require(!canonicalDestination.hasPrefix(canonicalSource), "Die NUP-Zieldatei muss außerhalb des Quellordners liegen.")
        let packages = try DumpDiscovery.discover(source, options: options, context: context)
        var records = packages.map(\.record)
        var dirs: [NUPDirectory] = []
        var paths: [URL] = []
        func walk(_ url: URL, name: String, depth: Int) throws -> Int {
            try context.check()
            try require(depth <= 256, "Quellordner ist tiefer als 256 Ebenen.")
            let index = dirs.count
            dirs.append(NUPDirectory(name: name, children: []))
            var children: [Int] = []
            var names = Set<String>()
            let entries = try DumpDiscovery.entries(url).sorted {
                Array($0.lastPathComponent.precomposedStringWithCanonicalMapping.utf8).lexicographicallyPrecedes(Array($1.lastPathComponent.precomposedStringWithCanonicalMapping.utf8))
            }
            for entry in entries {
                let name = entry.lastPathComponent.precomposedStringWithCanonicalMapping
                if name == ".DS_Store" || (!options.keepListings && name == ".listing") { continue }
                try safeName(name)
                try require(names.insert(name).inserted, "Dateinamen kollidieren nach Unicode-Normalisierung: \(name)")
                let info = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                try require(info.isSymbolicLink != true, "Symbolische Links werden nicht gepackt: \(entry.path)")
                if info.isDirectory == true { children.append(try walk(entry, name: name, depth: depth + 1)) }
                else {
                    try require(info.isRegularFile == true, "Spezialdatei wird nicht gepackt: \(entry.path)")
                    paths.append(entry); children.append(-paths.count)
                }
            }
            dirs[index].children = children
            return index
        }
        for index in packages.indices {
            records[index].root = try walk(packages[index].url, name: "", depth: 0)
        }
        var counts = [Int](repeating: 0, count: dirs.count)
        for index in dirs.indices.reversed() {
            counts[index] = dirs[index].children.reduce(0) { $0 + ($1 < 0 ? 1 : counts[$1]) }
        }
        for index in records.indices {
            for child in dirs[records[index].root].children where child >= 0 && counts[child] > 0 {
                if dirs[child].name == "exefs" { records[index].exefs = child }
                if dirs[child].name == "romfs" { records[index].romfs = child }
            }
        }
        let dirCount = dirs.count
        for index in dirs.indices { dirs[index].children = dirs[index].children.map { $0 < 0 ? dirCount + (-$0 - 1) : $0 } }
        var pool = Data()
        var strings: [String: Int] = [:]
        func intern(_ name: String) {
            if strings[name] == nil { strings[name] = pool.count; pool.append(Data(name.utf8)) }
        }
        dirs.forEach { intern($0.name) }
        paths.forEach { intern($0.lastPathComponent.precomposedStringWithCanonicalMapping) }
        let childCount = dirs.reduce(0) { $0 + $1.children.count }
        let tocSize = 48 + records.count * 64 + dirs.count * 24 + paths.count * 80 + childCount * 4 + pool.count
        try require(tocSize <= 256 * 1024 * 1024, "Inhaltsverzeichnis ist größer als 256 MB.")
        let blobOffset = try aligned(128 + UInt64(tocSize))
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nup-\(UUID().uuidString).partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NUPError("Temporäre Zieldatei kann nicht angelegt werden.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        try output.write(contentsOf: Data(count: Int(blobOffset)))
        var files: [NUPFile] = []
        var seen: [String: NUPFile] = [:]
        for (index, path) in paths.enumerated() {
            try context.report(Double(index) / Double(max(1, paths.count)), "Packe \(path.lastPathComponent)")
            let cursor = try output.offset()
            let start = try aligned(cursor)
            try output.write(contentsOf: Data(count: Int(start - cursor)))
            var file = try StreamCodec.encode(path, output: output, level: options.level, context: context)
            file.name = path.lastPathComponent.precomposedStringWithCanonicalMapping
            let key = "\(file.size):\(file.hash.hex)"
            if let shared = seen[key], file.size > 0 {
                try output.truncate(atOffset: cursor); try output.seek(toOffset: cursor)
                file.offset = shared.offset; file.storedSize = shared.storedSize; file.codec = shared.codec
            } else { seen[key] = file }
            files.append(file)
        }
        for index in records.indices {
            let data = try MetadataCodec.serialize(records[index].metadata)
            try require(data.count <= 64 * 1024 * 1024, "Paketmetadaten sind größer als 64 MB.")
            records[index].metaOffset = data.isEmpty ? 0 : try output.offset()
            records[index].metaSize = data.count
            try output.write(contentsOf: data)
        }
        let fileSize = try output.offset()
        var toc = Data(count: tocSize)
        toc.put(Data([84, 79, 67, 1]), at: 0)
        toc.put(UInt64(records.count), at: 4, width: 4)
        toc.put(UInt64(dirs.count), at: 8, width: 8)
        toc.put(UInt64(files.count), at: 16, width: 8)
        var position = 48
        for record in records {
            putPackage(record, into: &toc, at: position); position += 64
        }
        var first = 0
        for dir in dirs {
            toc.put(UInt64(strings[dir.name]!), at: position, width: 4)
            toc.put(UInt64(dir.name.utf8.count), at: position + 4, width: 4)
            toc.put(UInt64(first), at: position + 8, width: 4)
            toc.put(UInt64(dir.children.count), at: position + 12, width: 4)
            first += dir.children.count; position += 24
        }
        for file in files {
            toc.put(UInt64(strings[file.name]!), at: position, width: 4)
            toc.put(UInt64(file.name.utf8.count), at: position + 4, width: 4)
            toc.put(file.size, at: position + 8, width: 8)
            toc.put(file.offset, at: position + 16, width: 8)
            toc.put(file.storedSize, at: position + 24, width: 8)
            toc.put(file.hash, at: position + 32)
            toc.put(UInt64(file.codec), at: position + 64, width: 1)
            position += 80
        }
        for dir in dirs {
            for child in dir.children { toc.put(UInt64(child), at: position, width: 4); position += 4 }
        }
        toc.put(UInt64(position), at: 24, width: 8)
        toc.put(UInt64(pool.count), at: 32, width: 8)
        toc.put(pool, at: position)
        var identity = Data()
        for record in records {
            identity.appendLE(record.titleID, width: 8)
            identity.appendLE(UInt64(record.version), width: 4)
            identity.append(record.kind)
        }
        var header = Data(count: 128)
        header.put(Data([78, 85, 80, 1]), at: 0)
        header.put(128, at: 4, width: 2); header.put(1, at: 6, width: 2)
        header.put(128, at: 8, width: 8); header.put(UInt64(tocSize), at: 16, width: 8)
        header.put(toc.sha256, at: 24)
        header.put(blobOffset, at: 56, width: 8); header.put(fileSize, at: 64, width: 8)
        header.put(UInt64(records.count), at: 72, width: 4)
        header.put(Data(identity.sha256.prefix(16)), at: 80)
        try output.seek(toOffset: 0)
        try output.write(contentsOf: header); try output.write(contentsOf: toc)
        try output.synchronize()
        _ = try NUPArchive(url: temporary, context: context)
        try context.check()
        try publishFile(temporary, to: destination)
        try? context.report(1, "Container erstellt.")
    }

    static func putPackage(_ record: NUPPackage, into toc: inout Data, at position: Int) {
        toc.put(record.titleID, at: position, width: 8)
        toc.put(UInt64(record.root), at: position + 8, width: 4)
        toc.put(record.exefs.map(UInt64.init) ?? UInt64(UInt32.max), at: position + 12, width: 4)
        toc.put(record.romfs.map(UInt64.init) ?? UInt64(UInt32.max), at: position + 16, width: 4)
        toc.put(UInt64(record.version), at: position + 20, width: 4)
        toc.put(UInt64(record.kind), at: position + 24, width: 1)
        toc.put(UInt64(record.flags), at: position + 25, width: 1)
        toc.put(record.metaOffset, at: position + 32, width: 8)
        toc.put(UInt64(record.metaSize), at: position + 40, width: 4)
    }
}
