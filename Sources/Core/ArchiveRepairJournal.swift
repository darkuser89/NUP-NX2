import Foundation
import Darwin

/// Bounded undo journal: headers, 64-byte package records and 4-byte RomFS counts.
/// V1 package-only journals remain readable. Payloads, file tables and metadata
/// are never rewritten; V2 adds explicit bounded record lengths.
struct ArchiveRepairJournal {
    struct Entry: Sendable { let offset: Int; let old: Data; let new: Data }
    static let limit = 344 + 4096 * 144
    private let legacy: Bool
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let oldHeader: Data
    let newHeader: Data
    let entries: [Entry]

    init(source: NUPArchive, layout: ArchiveRepairLayout) throws {
        legacy = false
        device = UInt64(UInt32(bitPattern: source.revision.device)); inode = UInt64(source.revision.inode)
        size = source.fileSize; oldHeader = source.header; newHeader = layout.header
        try require(layout.toc.count == source.toc.count, L10n.text("Eine Reparatur darf die TOC nicht vergrößern."))
        var changes: [Entry] = try source.packages.indices.compactMap { index in
            let at = 48 + index * 64
            let old = try source.toc.bytes(at, 64), new = try layout.toc.bytes(at, 64)
            return old == new ? nil : Entry(offset: at, old: old, new: new)
        }
        for repair in source.romfsRepairs {
            let at = repair.offset(packages: source.packages.count)
            let old = try source.toc.bytes(at, 4), new = try layout.toc.bytes(at, 4)
            if old != new { changes.append(Entry(offset: at, old: old, new: new)) }
        }
        entries = changes
        var expected = source.toc
        for entry in entries { expected.put(entry.new, at: entry.offset) }
        try require(expected == layout.toc, L10n.text("Reparatur enthält nicht unterstützte TOC-Änderungen."))
        try validateShape()
    }

    static func journals(for url: URL) -> (pending: URL, committed: URL) {
        let name = ".nup-repair-" + String(Data(url.lastPathComponent.utf8).sha256.hex.prefix(24))
        return (url.deletingLastPathComponent().appendingPathComponent(name + ".pending"),
                url.deletingLastPathComponent().appendingPathComponent(name + ".committed"))
    }
    static func requireAbsent(at url: URL) throws {
        let p = journals(for: url)
        try require(!FileManager.default.fileExists(atPath: p.pending.path) && !FileManager.default.fileExists(atPath: p.committed.path),
                    L10n.text("Eine unterbrochene Reparatur muss zuerst durch erneutes Öffnen wiederhergestellt werden."))
    }
    static func requireNoOtherChanges(at url: URL) throws {
        for p in [MetadataTransaction.journals(for: url), ArchiveContentJournal.journals(for: url)] {
            try require(!FileManager.default.fileExists(atPath: p.pending.path) && !FileManager.default.fileExists(atPath: p.committed.path),
                        L10n.text("Eine frühere Änderung muss zuerst durch erneutes Öffnen wiederhergestellt werden."))
        }
    }
    static func requireNoPendingChanges(at url: URL) throws { try requireAbsent(at: url); try requireNoOtherChanges(at: url) }

    var data: Data {
        var b = Data((legacy ? "NUPFIX01" : "NUPFIX02").utf8)
        let fields: [UInt64] = [device, inode, size, (try? oldHeader.uint(8, 8)) ?? 0, (try? oldHeader.uint(16, 8)) ?? 0]
        for value in fields { b.appendLE(value, width: 8) }
        b.appendLE(UInt64(entries.count), width: 4); b.appendLE(0, width: 4)
        b.append(oldHeader); b.append(newHeader)
        for e in entries {
            b.appendLE(UInt64(e.offset), width: 8)
            if !legacy { b.appendLE(UInt64(e.old.count), width: 4); b.appendLE(0, width: 4) }
            b.append(e.old); b.append(e.new)
        }
        b.append(b.sha256)
        return b
    }

    init(data: Data) throws {
        try require(data.count >= 344 && data.count <= Self.limit, L10n.text("Ungültige Reparaturprotokoll-Größe."))
        let magic = try data.bytes(0, 8)
        legacy = magic == Data("NUPFIX01".utf8)
        try require(try (legacy || magic == Data("NUPFIX02".utf8)) &&
                    data.bytes(0, data.count - 32).sha256 == data.bytes(data.count - 32, 32), L10n.text("Das Reparaturprotokoll ist beschädigt."))
        device = try data.uint(8, 8); inode = try data.uint(16, 8); size = try data.uint(24, 8)
        let count = try integer(data.uint(48, 4))
        try require(try count <= 4096 && data.uint(52, 4) == 0, L10n.text("Ungültige Reparaturdatensätze."))
        oldHeader = try data.bytes(56, 128); newHeader = try data.bytes(184, 128)
        try require(try data.uint(32, 8) == oldHeader.uint(8, 8) && data.uint(40, 8) == oldHeader.uint(16, 8), L10n.text("Widersprüchlicher TOC-Bereich."))
        var parsed: [Entry] = [], position = 312
        for _ in 0..<count {
            let offset = try integer(data.uint(position, 8))
            let width = legacy ? 64 : try integer(data.uint(position + 8, 4))
            try require(width == 64 || (!legacy && width == 4), L10n.text("Ungültige Reparaturdatensatzgröße."))
            if !legacy { try require(try data.uint(position + 12, 4) == 0, L10n.text("Unbekannte Reparatur-Flags.")) }
            position += legacy ? 8 : 16
            parsed.append(Entry(offset: offset, old: try data.bytes(position, width), new: try data.bytes(position + width, width)))
            position += width * 2
        }
        try require(position == data.count - 32, L10n.text("Ungültige Reparaturprotokoll-Länge."))
        entries = parsed
        try validateShape()
    }

    private func validateShape() throws {
        try require(entries.count <= 4096 && oldHeader.count == 128 && newHeader.count == 128, L10n.text("Reparaturlimit überschritten."))
        let start = try oldHeader.uint(8, 8), count = try oldHeader.uint(16, 8), packages = try oldHeader.uint(72, 4)
        try require(try oldHeader.bytes(0, 4) == Data([78,85,80,1]) && oldHeader.uint(64, 8) == size &&
                    start >= 128 && start == oldHeader.uint(4, 2) && count <= 256 * 1024 * 1024 && packages > 0,
                    L10n.text("Ungültiger Reparaturheader."))
        try bounded(start, count, by: size)
        var header = oldHeader
        header.put(try newHeader.bytes(24, 32), at: 24); header.put(try newHeader.bytes(80, 16), at: 80)
        try require(header == newHeader, L10n.text("Das Reparaturprotokoll verändert den Containeraufbau."))
        var used = Set<Int>()
        for e in entries {
            try require((e.old.count == 64 || (!legacy && e.old.count == 4)) && e.new.count == e.old.count && e.old != e.new,
                        L10n.text("Ungültige Reparaturdatensatzgröße."))
            try require(e.offset >= 0 && UInt64(e.offset) <= count && UInt64(e.old.count) <= count - UInt64(e.offset),
                        L10n.text("Reparaturdatensatz außerhalb der TOC."))
            for at in e.offset..<(e.offset + e.old.count) {
                try require(used.insert(at).inserted, L10n.text("Überlappende Reparaturdatensätze."))
            }
            if e.old.count == 64 {
                try require(e.offset >= 48 && (e.offset - 48) % 64 == 0 && UInt64((e.offset - 48) / 64) < packages,
                            L10n.text("Ungültiger Reparatur-Paketoffset."))
                var expected = e.old
                expected.put(try e.new.bytes(0, 8), at: 0); expected.put(try e.new.bytes(20, 6), at: 20)
                try require(try expected == e.new && e.new.uint(24, 1) < 5 && e.new.uint(25, 1) & ~1 == 0,
                            L10n.text("Reparatur verändert Wurzel, Metadaten oder reservierte Paketfelder."))
            } else {
                let first = 48 + Int(packages) * 64 + 12
                try require(try e.offset >= first && (e.offset - first) % 24 == 0 &&
                            e.old.uint(0, 4) == 0 && e.new.uint(0, 4) > 0,
                            L10n.text("Reparatur verändert ein unbekanntes Verzeichnisfeld."))
                // Exact directory bounds, package ownership and proposed count
                // are checked against the reconstructed original TOC in layouts.
            }
        }
    }

    func prepare(url: URL) throws {
        try Self.requireNoPendingChanges(at: url)
        let pending = Self.journals(for: url).pending, temporary = pending.appendingPathExtension(UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, L10n.text("Reparaturprotokoll kann nicht angelegt werden."))
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close(); try? FileManager.default.removeItem(at: temporary) }
        try file.write(contentsOf: data); try file.synchronize()
        try require(renamex_np(temporary.path, pending.path, UInt32(RENAME_EXCL)) == 0, L10n.text("Reparaturprotokoll kann nicht veröffentlicht werden."))
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }

    /// Reject unrelated changes before any recovery write. Construct both
    /// layouts and validate them through the same archive parser, off disk.
    func layouts(url: URL, file: FileHandle) throws -> (old: ArchiveRepairLayout, new: ArchiveRepairLayout) {
        let revision = try FileRevision(handle: file)
        try require(UInt64(UInt32(bitPattern: revision.device)) == device && UInt64(revision.inode) == inode && UInt64(revision.size) == size,
                    L10n.text("Das Reparaturprotokoll gehört zu einer anderen oder veränderten NUP."))
        let header = try readRange(file, offset: 0, count: 128)
        try require(Self.partial(header, old: oldHeader, new: newHeader), L10n.text("Der Header wurde anderweitig verändert."))
        var old = try readRange(file, offset: oldHeader.uint(8, 8), count: integer(oldHeader.uint(16, 8)))
        for e in entries {
            try require(try Self.partial(old.bytes(e.offset, e.old.count), old: e.old, new: e.new), L10n.text("Ein Reparaturdatensatz wurde anderweitig verändert."))
            old.put(e.old, at: e.offset)
        }
        try require(try old.sha256 == oldHeader.bytes(24, 32), L10n.text("Die unveränderten TOC-Bereiche stimmen nicht mehr."))
        var new = old
        for e in entries { new.put(e.new, at: e.offset) }
        try require(try new.sha256 == newHeader.bytes(24, 32) && ArchiveDiagnosis.uuid(toc: new) == newHeader.bytes(80, 16),
                    L10n.text("Reparatur-Prüfsumme oder UUID ist ungültig."))
        let original = ArchiveRepairLayout(header: oldHeader, toc: old), repaired = ArchiveRepairLayout(header: newHeader, toc: new)
        let source = try NUPArchive(url: url, recoverPendingMetadata: false, validation: .packageDiagnosis, repairLayout: original)
        var counts = Dictionary(uniqueKeysWithValues: source.romfsRepairs.map { ($0.offset(packages: source.packages.count), $0.count) })
        for entry in entries where entry.old.count == 4 {
            guard let expected = counts.removeValue(forKey: entry.offset) else {
                throw NUPError(L10n.text("Das Reparaturprotokoll ändert keine eindeutig belegte RomFS-Eintragszahl."))
            }
            try require(try entry.new.uint(0, 4) == UInt64(expected), L10n.text("RomFS-Eintragszahl widerspricht dem vorhandenen Dateibaum."))
        }
        try require(counts.isEmpty, L10n.text("Das Reparaturprotokoll lässt beschädigte RomFS-Einträge aus."))
        _ = try NUPArchive(url: url, recoverPendingMetadata: false, repairLayout: repaired)
        return (original, repaired)
    }
    private static func partial(_ actual: Data, old: Data, new: Data) -> Bool {
        actual.count == old.count && actual.count == new.count && actual.enumerated().allSatisfy { old[$0.offset] == $0.element || new[$0.offset] == $0.element }
    }
    func writeRecords(to file: FileHandle, original: Bool = false) throws {
        let start = try oldHeader.uint(8, 8)
        for e in entries { try file.seek(toOffset: start + UInt64(e.offset)); try file.write(contentsOf: original ? e.old : e.new) }
    }
    func writeHeader(to file: FileHandle, original: Bool = false) throws {
        try file.seek(toOffset: 0); try file.write(contentsOf: original ? oldHeader : newHeader); try file.synchronize()
    }
    static func rollback(url: URL, file: FileHandle) throws {
        let p = journals(for: url), journal = try read(p.pending)
        _ = try journal.layouts(url: url, file: file)
        try journal.writeRecords(to: file, original: true); try journal.writeHeader(to: file, original: true)
        _ = try NUPArchive(url: url, recoverPendingMetadata: false, validation: .packageDiagnosis)
        try FileManager.default.removeItem(at: p.pending); MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }
    static func markCommitted(url: URL) throws {
        let p = journals(for: url)
        try require(renamex_np(p.pending.path, p.committed.path, UInt32(RENAME_EXCL)) == 0, L10n.text("Reparatur kann nicht abgeschlossen werden."))
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }
    private static func read(_ url: URL) throws -> Self {
        let file = try regularFile(url); defer { try? file.close() }
        let count = try file.seekToEnd(); try require(count <= UInt64(limit), L10n.text("Reparaturprotokoll ist zu groß."))
        return try Self(data: readRange(file, offset: 0, count: integer(count)))
    }
    static func recoverIfNeeded(url: URL) throws {
        let p = journals(for: url), fm = FileManager.default
        let pending = fm.fileExists(atPath: p.pending.path), committed = fm.fileExists(atPath: p.committed.path)
        guard pending || committed else { return }
        try require(!(pending && committed), L10n.text("Mehrere Reparaturprotokolle gefunden."))
        try requireNoOtherChanges(at: url)
        let file = try regularFile(url, writable: true); defer { try? file.close() }
        try MetadataTransaction.lock(file)
        if pending { try rollback(url: url, file: file) }
        else {
            let journal = try read(p.committed), layouts = try journal.layouts(url: url, file: file)
            let current = try NUPArchive(url: url, recoverPendingMetadata: false)
            try require(current.header == layouts.new.header && current.toc == layouts.new.toc, L10n.text("Die abgeschlossene Reparatur wurde danach verändert."))
            try fm.removeItem(at: p.committed); MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
        }
    }
}
