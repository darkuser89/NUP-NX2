import Foundation

struct ArchiveROMFSRepair: Identifiable, Equatable, Sendable {
    let id: Int // directory index
    let package: Int
    let first: Int
    let count: Int
    let names: [String]

    func offset(packages: Int) -> Int { 48 + packages * 64 + id * 24 + 12 }
    func put(into toc: inout Data, packages: Int) { toc.put(UInt64(count), at: offset(packages: packages), width: 4) }
}

enum ArchiveROMFSRecovery {
    /// Only a zero child count at a package's direct romfs is recoverable.
    /// Its declared first slot must anchor an entire unused contiguous range.
    /// The caller subsequently validates the complete resulting graph and all
    /// data regions. No inferred layout is ever exposed for normal editing.
    static func inspect(toc: Data, packages: [NUPPackage], directories: inout [NUPDirectory],
                        children: [Int], used: [Bool], context: JobContext) throws -> [ArchiveROMFSRepair] {
        var candidates: [Int: [(Int, Int)]] = [:]
        for package in packages {
            guard let romfs = package.romfs, directories[romfs].name == "romfs",
                  directories[romfs].children.isEmpty,
                  directories[package.root].children.contains(romfs) else { continue }
            let at = 48 + packages.count * 64 + romfs * 24
            let first = try integer(toc.uint(at + 8, 4))
            candidates[first, default: []].append((package.id, romfs))
        }
        var repairs: [ArchiveROMFSRepair] = [], slot = 0
        while slot < children.count {
            try context.check()
            if used[slot] { slot += 1; continue }
            let first = slot
            while slot < children.count && !used[slot] { slot += 1 }
            guard let matches = candidates[first], matches.count == 1 else {
                throw NUPError(L10n.text("Unbenutzte Kindknotenplätze lassen sich keinem leeren /romfs eindeutig zuordnen."))
            }
            try require(repairs.count < 4096, L10n.text("Mehr als 4096 RomFS-Korrekturen überschreiten das Reparaturlimit."))
            let (package, directory) = matches[0]
            let nodes = Array(children[first..<slot])
            let dirCount = directories.count, filesStart = 48 + packages.count * 64 + dirCount * 24
            let pool = try integer(toc.uint(24, 8))
            let names = try nodes.prefix(12).map { node -> String in
                if node < dirCount { return directories[node].name }
                let at = filesStart + (node - dirCount) * 80
                let offset = try integer(toc.uint(at, 4)), length = try integer(toc.uint(at + 4, 4))
                // File names are fully bounds/UTF-8/safety checked by the caller.
                let poolSize = try integer(toc.uint(32, 8))
                try require(offset <= poolSize && length <= poolSize - offset, L10n.text("Ungültiger Dateiname im RomFS-Bereich."))
                guard let name = String(data: try toc.bytes(pool + offset, length), encoding: .utf8) else {
                    throw NUPError(L10n.text("Dateiname ist kein gültiges UTF-8."))
                }
                return name
            }
            directories[directory].children = nodes
            repairs.append(ArchiveROMFSRepair(id: directory, package: package, first: first, count: nodes.count, names: names))
        }
        return repairs
    }
}
