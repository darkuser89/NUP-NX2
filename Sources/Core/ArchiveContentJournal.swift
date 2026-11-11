import Foundation
import CryptoKit
import Darwin

/// Undo only the prefix that a TOC rewrite can overwrite, not the whole archive.
/// Appended extents are discarded on rollback. Journal I/O is streamed.
struct ArchiveContentJournal {
    static let prefixLimit = 256 * 1024 * 1024 + Int(UInt16.max)
    static let journalLimit = 208 + prefixLimit + 256 * 1024 * 1024
    let device: UInt64
    let inode: UInt64
    let originalSize: UInt64
    let prefixSize: UInt64
    let newHeader: Data
    let newTOC: Data

    init(archive: NUPArchive, plan: ArchiveFilePlan) {
        device = UInt64(UInt32(bitPattern: archive.revision.device))
        inode = UInt64(archive.revision.inode)
        originalSize = archive.fileSize; prefixSize = plan.prefixSize
        newHeader = plan.header; newTOC = plan.toc
    }

    static func journals(for url: URL) -> (pending: URL, committed: URL) {
        let name = ".nup-files-" + String(Data(url.lastPathComponent.utf8).sha256.hex.prefix(24))
        return (url.deletingLastPathComponent().appendingPathComponent(name + ".pending"),
                url.deletingLastPathComponent().appendingPathComponent(name + ".committed"))
    }
    static func requireAbsent(at url: URL) throws {
        let paths = journals(for: url)
        try require(!FileManager.default.fileExists(atPath: paths.pending.path) &&
                    !FileManager.default.fileExists(atPath: paths.committed.path),
                    "Eine frühere Dateiänderung muss zuerst durch erneutes Öffnen wiederhergestellt werden.")
    }
    private static func requireNoMetadataJournal(at url: URL) throws {
        let paths = MetadataTransaction.journals(for: url)
        try require(!FileManager.default.fileExists(atPath: paths.pending.path) &&
                    !FileManager.default.fileExists(atPath: paths.committed.path),
                    "Eine frühere Metadatenänderung muss zuerst wiederhergestellt werden.")
    }
    static func requireNoPendingChanges(at url: URL) throws {
        try requireAbsent(at: url); try requireNoMetadataJournal(at: url)
    }

    private var manifest: Data {
        var data = Data("NUPCONT1".utf8)
        for value in [device, inode, originalSize, prefixSize, (try? newHeader.uint(64, 8)) ?? 0] {
            data.appendLE(value, width: 8)
        }
        data.append(newHeader)
        return data
    }

    func prepare(url: URL, file: FileHandle, context: JobContext = JobContext()) throws {
        try Self.requireNoPendingChanges(at: url)
        try require(prefixSize <= UInt64(Self.prefixLimit) && prefixSize <= originalSize,
                    "Wiederherstellungsbereich ist zu groß.")
        let pending = Self.journals(for: url).pending
        let temporary = pending.appendingPathExtension(UUID().uuidString)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Wiederherstellungsprotokoll kann nicht angelegt werden.")
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        var hash = SHA256()
        func write(_ data: Data) throws { hash.update(data: data); try output.write(contentsOf: data) }
        try write(manifest)
        var offset: UInt64 = 0
        while offset < prefixSize {
            try context.check()
            let data = try readRange(file, offset: offset, count: Int(min(UInt64(StreamCodec.chunkSize), prefixSize - offset)))
            try write(data); offset += UInt64(data.count)
        }
        try write(newTOC)
        try output.write(contentsOf: Data(hash.finalize()))
        try output.synchronize()
        try context.check()
        try require(renamex_np(temporary.path, pending.path, UInt32(RENAME_EXCL)) == 0,
                    "Wiederherstellungsprotokoll kann nicht veröffentlicht werden.")
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }

    private init(input: FileHandle) throws {
        let size = try input.seekToEnd()
        try require(size >= 336 && size <= UInt64(Self.journalLimit), "Ungültige Größe des Datei-Protokolls.")
        let data = try readRange(input, offset: 0, count: 176)
        try require(try data.bytes(0, 8) == Data("NUPCONT1".utf8), "Unbekanntes Datei-Protokoll.")
        device = try data.uint(8, 8); inode = try data.uint(16, 8)
        originalSize = try data.uint(24, 8); prefixSize = try data.uint(32, 8)
        newHeader = try data.bytes(48, 128)
        let tocSize = try newHeader.uint(16, 8)
        try require(prefixSize >= 128 && prefixSize <= UInt64(Self.prefixLimit) && prefixSize <= originalSize &&
                    tocSize <= 256 * 1024 * 1024 && size == 208 + prefixSize + tocSize,
                    "Ungültige Längen im Datei-Protokoll.")
        try require(try data.uint(40, 8) == newHeader.uint(64, 8), "Widersprüchliche Dateigröße im Protokoll.")
        var hash = SHA256(), offset: UInt64 = 0
        while offset < size - 32 {
            let bytes = try readRange(input, offset: offset, count: Int(min(UInt64(StreamCodec.chunkSize), size - 32 - offset)))
            hash.update(data: bytes); offset += UInt64(bytes.count)
        }
        try require(try Data(hash.finalize()) == readRange(input, offset: size - 32, count: 32), "Datei-Protokoll ist beschädigt.")
        newTOC = try readRange(input, offset: 176 + prefixSize, count: integer(tocSize))
        let oldHeader = try readRange(input, offset: 176, count: 128)
        let start = try oldHeader.uint(8, 8), oldCount = try oldHeader.uint(16, 8)
        try require(try oldHeader.bytes(0, 4) == Data([78,85,80,1]) && oldHeader.uint(64, 8) == originalSize &&
                    start == oldHeader.uint(4, 2) && start >= 128 && oldCount <= 256 * 1024 * 1024,
                    "Ungültiger Originalheader im Datei-Protokoll.")
        try bounded(start, oldCount, by: prefixSize)
        try require(prefixSize == min(originalSize, start + max(oldCount, tocSize)), "Ungültiger Wiederherstellungsbereich.")
        var oldHash = SHA256(), pos: UInt64 = 0
        while pos < oldCount {
            let bytes = try readRange(input, offset: 176 + start + pos, count: Int(min(UInt64(StreamCodec.chunkSize), oldCount - pos)))
            oldHash.update(data: bytes); pos += UInt64(bytes.count)
        }
        try require(try Data(oldHash.finalize()) == oldHeader.bytes(24, 32), "Original-TOC im Protokoll ist beschädigt.")
        var expected = oldHeader
        expected.put(tocSize, at: 16, width: 8); expected.put(newTOC.sha256, at: 24)
        expected.put(try newHeader.uint(56, 8), at: 56, width: 8)
        expected.put(try newHeader.uint(64, 8), at: 64, width: 8)
        try require(expected == newHeader, "Datei-Protokoll verändert die Paketidentität.")
        let blob = try newHeader.uint(56, 8), newSize = try newHeader.uint(64, 8)
        try require(try blob >= oldHeader.uint(56, 8) && blob % 16 == 0 && blob >= start + tocSize &&
                    newSize >= originalSize && blob <= newSize && newTOC.bytes(0, 4) == Data([84,79,67,1]) &&
                    newTOC.uint(4, 4) == newHeader.uint(72, 4), "Ungültiger neuer Containeraufbau im Protokoll.")
    }

    private func requireIdentity(_ file: FileHandle) throws {
        let revision = try FileRevision(handle: file)
        try require(UInt64(UInt32(bitPattern: revision.device)) == device && UInt64(revision.inode) == inode,
                    "Das Datei-Protokoll gehört zu einer anderen NUP.")
    }

    private func restore(url: URL, file: FileHandle, input: FileHandle) throws {
        try requireIdentity(file)
        let size = try file.seekToEnd(), expectedSize = try newHeader.uint(64, 8), tocStart = try newHeader.uint(8, 8)
        try require(size >= originalSize && size <= expectedSize, "Die NUP wurde außerhalb der Dateiänderung verändert.")
        // Refuse unrelated changes, including an externally changed prefix. A
        // torn write may contain old/new bytes, but never arbitrary third bytes.
        var offset: UInt64 = 0
        while offset < prefixSize {
            let count = Int(min(UInt64(StreamCodec.chunkSize), prefixSize - offset))
            let old = try readRange(input, offset: 176 + offset, count: count)
            let current = try readRange(file, offset: offset, count: count)
            for i in 0..<count where current[i] != old[i] {
                let position = offset + UInt64(i)
                if position < 128 {
                    try require(current[i] == newHeader[Int(position)], "Der Header wurde inzwischen anderweitig verändert.")
                } else if position >= tocStart && position - tocStart < UInt64(newTOC.count) {
                    try require(current[i] == newTOC[Int(position - tocStart)], "Die TOC wurde inzwischen anderweitig verändert.")
                } else { throw NUPError("Die NUP wurde inzwischen anderweitig verändert.") }
            }
            offset += UInt64(count)
        }
        offset = 0
        while offset < prefixSize {
            let data = try readRange(input, offset: 176 + offset, count: Int(min(UInt64(StreamCodec.chunkSize), prefixSize - offset)))
            try file.seek(toOffset: offset); try file.write(contentsOf: data); offset += UInt64(data.count)
        }
        try file.truncate(atOffset: originalSize); try file.synchronize()
        _ = try NUPArchive(url: url, recoverPendingMetadata: false)
    }

    static func rollback(url: URL, file: FileHandle) throws {
        let paths = journals(for: url)
        let input = try regularFile(paths.pending)
        defer { try? input.close() }
        let journal = try Self(input: input)
        try journal.restore(url: url, file: file, input: input)
        try FileManager.default.removeItem(at: paths.pending)
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }
    static func markCommitted(url: URL) throws {
        let paths = journals(for: url)
        try require(renamex_np(paths.pending.path, paths.committed.path, UInt32(RENAME_EXCL)) == 0,
                    "Dateiänderung konnte nicht abgeschlossen werden.")
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }
    static func recoverIfNeeded(url: URL) throws {
        let paths = journals(for: url), fm = FileManager.default
        let pending = fm.fileExists(atPath: paths.pending.path), committed = fm.fileExists(atPath: paths.committed.path)
        guard pending || committed else { return }
        try require(!(pending && committed), "Mehrere Datei-Protokolle gefunden.")
        try requireNoMetadataJournal(at: url)
        let file = try regularFile(url, writable: true)
        defer { try? file.close() }
        try MetadataTransaction.lock(file)
        let input = try regularFile(pending ? paths.pending : paths.committed)
        defer { try? input.close() }
        let journal = try Self(input: input)
        try journal.requireIdentity(file)
        if pending { try journal.restore(url: url, file: file, input: input) }
        else {
            let current = try NUPArchive(url: url, recoverPendingMetadata: false)
            try require(current.header == journal.newHeader && current.toc == journal.newTOC,
                        "Die abgeschlossene Dateiänderung wurde danach verändert.")
        }
        try fm.removeItem(at: pending ? paths.pending : paths.committed)
        MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
    }
}
