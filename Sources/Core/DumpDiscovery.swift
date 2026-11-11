import Foundation

struct DumpPackage {
    var url: URL
    var record: NUPPackage
}

enum DumpDiscovery {
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).map {
            $0.isDirectory == true && $0.isSymbolicLink != true
        } ?? false
    }
    static func entries(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .sorted { Array($0.lastPathComponent.utf8).lexicographicallyPrecedes(Array($1.lastPathComponent.utf8)) }
    }
    static func hasFiles(_ url: URL, context: JobContext) throws -> Bool {
        guard isDirectory(url) else { return false }
        var stack = [url]
        while let directory = stack.popLast() {
            try context.check()
            for entry in try entries(directory) {
                if [".listing", ".DS_Store"].contains(entry.lastPathComponent) { continue }
                if isDirectory(entry) { stack.append(entry) } else { return true }
            }
        }
        return false
    }
    static func resolve(_ url: URL, kind: UInt8, version: UInt32 = 0, titleID: UInt64 = 0,
                        override: UInt64? = nil, profile: MetadataProfile) throws -> DumpPackage {
        var record = NUPPackage(id: 0, titleID: titleID, version: version, kind: kind)
        if kind != 2 {
            for path in ["exefs/main.npdm", "main.npdm"] {
                let source = url.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: source.path) {
                    let input = try regularFile(source)
                    defer { try? input.close() }
                    let size = try input.seekToEnd()
                    try require(size <= 32 * 1024 * 1024, "NPDM ist größer als 32 MB.")
                    try input.seek(toOffset: 0)
                    let data = try readExactly(input, integer(size))
                    record.metadata[profile.type(1)] = data
                    if let range = data.range(of: Data("ACI0".utf8)), range.lowerBound + 24 <= data.count {
                        let value = try data.uint(range.lowerBound + 16, 8)
                        if value != 0 { record.titleID = value }
                    }
                    break
                }
            }
        }
        for path in ["exefs/main", "main"] {
            let source = url.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: source.path) {
                let input = try regularFile(source)
                defer { try? input.close() }
                let data = try input.read(upToCount: 96) ?? Data()
                if data.count == 96 && (data.prefix(4) == Data("NSO0".utf8) || data.subdata(in: 16..<20) == Data("NRO0".utf8)) {
                    record.metadata[profile.type(7)] = data.subdata(in: 64..<96)
                }
                break
            }
        }
        if let override { record.titleID = override }
        return DumpPackage(url: url, record: record)
    }

    static func discover(_ source: URL, options: PackOptions, context: JobContext) throws -> [DumpPackage] {
        try require(isDirectory(source), "Bitte einen regulären Dump-Ordner auswählen.")
        let title = options.titleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let override: UInt64?
        if title.isEmpty { override = nil }
        else {
            try require(title.utf8.count == 16 && UInt64(title, radix: 16) != nil, "Titel-ID muss genau 16 Hex-Zeichen enthalten.")
            override = UInt64(title, radix: 16)
        }
        let base = source.appendingPathComponent("base")
        let updates = source.appendingPathComponent("updates")
        var packages: [DumpPackage] = []
        if isDirectory(base) {
            if try hasFiles(base, context: context) {
                packages.append(try resolve(base, kind: 0, override: override, profile: options.profile))
            }
        } else if !isDirectory(updates) && (isDirectory(source.appendingPathComponent("exefs")) || isDirectory(source.appendingPathComponent("romfs"))) {
            packages.append(try resolve(source, kind: 0, override: override, profile: options.profile))
        }
        let baseID = packages.first?.record.titleID ?? override ?? 0
        if isDirectory(updates) {
            for entry in try entries(updates) {
                let name = entry.lastPathComponent
                guard !name.isEmpty && name.utf8.allSatisfy({ (48...57).contains($0) }) && isDirectory(entry) else { continue }
                try require(UInt32(name) != nil, "Update-Version liegt außerhalb des 32-Bit-Bereichs.")
                if try hasFiles(entry, context: context) {
                    var package = try resolve(entry, kind: 1, version: UInt32(name)!, titleID: baseID, profile: options.profile)
                    if !packages.contains(where: { $0.record.kind == 0 }) { package.record.flags = 1 }
                    packages.append(package)
                }
            }
        }
        let dlc = source.appendingPathComponent("dlc")
        if isDirectory(dlc) {
            for titleDir in try entries(dlc) {
                guard titleDir.lastPathComponent.utf8.count == 16,
                      let id = UInt64(titleDir.lastPathComponent, radix: 16), isDirectory(titleDir) else { continue }
                for entry in try entries(titleDir) where isDirectory(entry) {
                    if try hasFiles(entry, context: context) {
                        packages.append(try resolve(entry, kind: 2, titleID: id, profile: options.profile))
                    }
                }
            }
        }
        try require(!packages.isEmpty, "Keine Pakete gefunden. Erwartet: base/, updates/<Version>/, dlc/<Titel-ID>/<Index>/ oder exefs/ und romfs/.")
        for index in packages.indices {
            packages[index].record.id = index
            packages[index].record.metadata[options.profile.type(8)] = Data(source.lastPathComponent.utf8)
        }
        let appIndex = packages.firstIndex { $0.record.kind == 0 } ?? 0
        for (type, value) in [(UInt16(5), options.name), (6, options.publisher), (4, options.displayVersion)] where !value.isEmpty {
            packages[appIndex].record.metadata[options.profile.type(type)] = Data(value.utf8)
        }
        if let icon = options.icon { packages[appIndex].record.metadata[options.profile.type(3)] = icon }
        if !options.localizedTitles.isEmpty {
            packages[appIndex].record.metadata[options.profile.type(9)] = try MetadataCodec.localizedData(options.localizedTitles.mapValues { Data($0.utf8) })
        }
        if !options.localizedIcons.isEmpty {
            packages[appIndex].record.metadata[options.profile.type(10)] = try MetadataCodec.localizedData(options.localizedIcons)
        }
        return packages
    }
}
