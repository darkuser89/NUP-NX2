import Foundation
import Darwin

extension NUPArchive {
    func extract(package index: Int, subtree: String?, destination: URL, context: JobContext) throws {
        try verify(deep: false, context: context)
        try require(packages.indices.contains(index), "Paket existiert nicht.")
        var root = packages[index].root
        if let subtree {
            let content = subtree == "exefs" ? packages[index].exefs : (subtree == "romfs" ? packages[index].romfs : nil)
            guard let selected = content else { throw NUPError("Teilbaum \(subtree) fehlt im ausgewählten Paket.") }
            root = selected
        }
        var planned: [(Int, [String])] = []
        var stack: [(Int, [String])] = [(root, [])]
        var collisionKeys = Set<String>()
        while let (node, path) = stack.popLast() {
            try context.check()
            if !path.isEmpty {
                // Conservative on all volumes: refuse case/Unicode collisions before writing.
                let key = path.map { $0.precomposedStringWithCanonicalMapping.lowercased() }.joined(separator: "/")
                try require(collisionKeys.insert(key).inserted, "Dateinamen kollidieren auf macOS: \(path.joined(separator: "/"))")
                planned.append((node, path))
            }
            if node < directories.count {
                for child in directories[node].children.reversed() {
                    let name = child < directories.count ? directories[child].name : files[child - directories.count].name
                    try safeName(name)
                    stack.append((child, path + [name]))
                }
            }
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nup-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try regularFile(url)
        defer { try? input.close() }
        for (number, item) in planned.enumerated() {
            let (node, parts) = item
            let target = parts.reduce(temporary) { $0.appendingPathComponent($1) }
            try context.report(Double(number) / Double(max(1, planned.count)), "Entpacke \(parts.last ?? "")")
            if node < directories.count {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                try require(FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                            "Zieldatei kann nicht angelegt werden.")
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                try StreamCodec.consume(files[node - directories.count], input: input, context: context) {
                    try output.write(contentsOf: $0)
                }
                try output.synchronize()
            }
        }
        try context.check()
        try publishDirectory(temporary, to: destination)
        try? context.report(1, "Paket entpackt; alle geschriebenen Dateien per SHA-256 geprüft.")
    }

    func saveMetadata(package index: Int, changes: MetadataEdit, profile: MetadataProfile,
                      destination: URL, replacingOriginal: Bool = false, context: JobContext) throws {
        let input = try regularFile(url)
        defer { try? input.close() }
        let sourceRevision = try FileRevision(handle: input)
        if replacingOriginal {
            try require(destination.standardizedFileURL == url.standardizedFileURL,
                        "Nur die geöffnete Originaldatei darf mit dieser Aktion ersetzt werden.")
            try require(sourceRevision == revision,
                        "Die Originaldatei wurde seit dem Öffnen verändert. Bitte erneut öffnen.")
        }
        try verify(deep: false, context: context)
        try require(packages.indices.contains(index), "Paket existiert nicht.")
        var records = packages
        var meta = records[index].metadata
        for (type, text) in [(UInt16(5), changes.name), (6, changes.publisher), (4, changes.displayVersion)] {
            meta[profile.type(type)] = text.isEmpty ? nil : Data(text.utf8)
        }
        if changes.removeIcon { meta.removeValue(forKey: profile.type(3)) }
        else if let icon = changes.icon { meta[profile.type(3)] = icon }
        meta[profile.type(9)] = changes.localizedTitles.isEmpty ? nil : try MetadataCodec.localizedData(changes.localizedTitles.mapValues { Data($0.utf8) })
        meta[profile.type(10)] = changes.localizedIcons.isEmpty ? nil : try MetadataCodec.localizedData(changes.localizedIcons)
        records[index].metadata = meta
        if replacingOriginal {
            try MetadataTransaction.update(archive: self, package: index, metadata: meta, context: context)
            return
        }
        // Keep content offsets intact but discard previous metadata blocks.
        let dataEnd = files.reduce(blobOffset) { max($0, $1.offset + $1.storedSize) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nup-edit-\(UUID().uuidString).partial")
        try require(FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                    "Temporäre Datei kann nicht angelegt werden.")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var copied: UInt64 = 0
        while copied < dataEnd {
            try context.report(Double(copied) / Double(max(1, dataEnd)), "Kopiere Containerinhalt …")
            try autoreleasepool {
                let data = try readExactly(input, Int(min(UInt64(StreamCodec.chunkSize), dataEnd - copied)))
                try output.write(contentsOf: data); copied += UInt64(data.count)
            }
        }
        var newTOC = toc
        for number in records.indices {
            let block = try MetadataCodec.serialize(records[number].metadata)
            try require(block.count <= 64 * 1024 * 1024, "Metadaten überschreiten das Paketlimit.")
            records[number].metaOffset = block.isEmpty ? 0 : try output.offset()
            records[number].metaSize = block.count
            try output.write(contentsOf: block)
            NUPWriter.putPackage(records[number], into: &newTOC, at: 48 + number * 64)
        }
        var newHeader = header
        newHeader.put(try output.offset(), at: 64, width: 8)
        newHeader.put(newTOC.sha256, at: 24)
        try output.seek(toOffset: 0)
        try output.write(contentsOf: newHeader)
        try output.seek(toOffset: newHeader.uint(8, 8))
        try output.write(contentsOf: newTOC)
        try output.synchronize()
        _ = try NUPArchive(url: temporary, context: context)
        try sourceRevision.requireCurrent(at: url)
        try context.check()
        try publishFile(temporary, to: destination)
        try? context.report(1, "Metadaten als neue NUP-Datei gespeichert.")
    }
}
