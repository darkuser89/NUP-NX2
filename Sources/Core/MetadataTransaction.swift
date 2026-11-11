import Foundation
import Darwin

/// A bounded undo record. It never contains file extents or a copy of the NUP.
struct MetadataTransaction {
    static let metadataLimit = 64 * 1024 * 1024
    static let journalLimit = 2 * metadataLimit + 480
    let device: UInt64
    let inode: UInt64
    let originalSize: UInt64
    let recordOffset: UInt64
    let writeOffset: UInt64
    let oldHeader: Data
    let oldRecord: Data
    let newHeader: Data
    let newRecord: Data
    let oldTail: Data
    let newBlock: Data

    static func journals(for url: URL) -> (pending: URL, committed: URL) {
        let name = ".nup-metadata-" + String(Data(url.lastPathComponent.utf8).sha256.hex.prefix(24))
        let folder = url.deletingLastPathComponent()
        return (folder.appendingPathComponent(name + ".pending"), folder.appendingPathComponent(name + ".committed"))
    }

    init(archive: NUPArchive, package index: Int, metadata: [UInt16: Data], input: FileHandle) throws {
        let package = archive.packages[index]
        device = UInt64(UInt32(bitPattern: archive.revision.device))
        inode = UInt64(archive.revision.inode)
        originalSize = archive.fileSize
        oldHeader = archive.header
        let relative = 48 + index * 64
        recordOffset = try oldHeader.uint(8, 8) + UInt64(relative)
        oldRecord = try archive.toc.bytes(relative, 64)
        newBlock = try MetadataCodec.serialize(metadata)
        try require(newBlock.count <= Self.metadataLimit, "Metadaten überschreiten das Paketlimit.")
        // Reuse an active metadata block at EOF. Other blocks remain at their
        // existing offsets; the first edit of an interior block appends it.
        if package.metaSize > 0 && package.metaOffset + UInt64(package.metaSize) == originalSize {
            writeOffset = package.metaOffset
            oldTail = try readRange(input, offset: writeOffset, count: package.metaSize)
        } else {
            writeOffset = originalSize
            oldTail = Data()
        }
        var record = oldRecord
        record.put(newBlock.isEmpty ? 0 : writeOffset, at: 32, width: 8)
        record.put(UInt64(newBlock.count), at: 40, width: 4)
        newRecord = record
        var toc = archive.toc
        toc.put(record, at: relative)
        var header = oldHeader
        header.put(writeOffset + UInt64(newBlock.count), at: 64, width: 8)
        header.put(toc.sha256, at: 24)
        newHeader = header
    }

    var journalData: Data {
        var data = Data("NUPMETA1".utf8)
        for value in [device, inode, originalSize, recordOffset, writeOffset, UInt64(oldTail.count), UInt64(newBlock.count)] {
            data.appendLE(value, width: 8)
        }
        for part in [oldHeader, oldRecord, newHeader, newRecord, oldTail, newBlock] { data.append(part) }
        data.append(data.sha256)
        return data
    }

    init(journal: Data) throws {
        try require(journal.count >= 480 && journal.count <= Self.journalLimit, "Ungültige Größe des Metadaten-Protokolls.")
        try require(try journal.bytes(0, 8) == Data("NUPMETA1".utf8), "Unbekanntes Metadaten-Protokoll.")
        let body = try journal.bytes(0, journal.count - 32)
        try require(try body.sha256 == journal.bytes(journal.count - 32, 32), "Metadaten-Protokoll ist beschädigt.")
        device = try journal.uint(8, 8); inode = try journal.uint(16, 8)
        originalSize = try journal.uint(24, 8)
        recordOffset = try journal.uint(32, 8); writeOffset = try journal.uint(40, 8)
        let oldCount = try integer(journal.uint(48, 8))
        let newCount = try integer(journal.uint(56, 8))
        try require(oldCount <= Self.metadataLimit && newCount <= Self.metadataLimit &&
                    journal.count == 480 + oldCount + newCount, "Ungültige Metadaten-Protokolllängen.")
        oldHeader = try journal.bytes(64, 128); oldRecord = try journal.bytes(192, 64)
        newHeader = try journal.bytes(256, 128); newRecord = try journal.bytes(384, 64)
        oldTail = try journal.bytes(448, oldCount)
        newBlock = try journal.bytes(448 + oldCount, newCount)
        try require(try oldHeader.bytes(0, 4) == Data([78, 85, 80, 1]) && oldHeader.uint(64, 8) == originalSize,
                    "Ungültiger Originalheader im Metadaten-Protokoll.")
        let tocStart = try oldHeader.uint(8, 8)
        let tocSize = try oldHeader.uint(16, 8)
        try require(tocSize <= 256 * 1024 * 1024, "Ungültige TOC-Größe im Metadaten-Protokoll.")
        try bounded(tocStart, tocSize, by: originalSize)
        try require(recordOffset >= tocStart && recordOffset - tocStart >= 48 &&
                    (recordOffset - tocStart - 48) % 64 == 0,
                    "Ungültiger Paketoffset im Metadaten-Protokoll.")
        let packageIndex = (recordOffset - tocStart - 48) / 64
        try require(try packageIndex < oldHeader.uint(72, 4), "Paketoffset außerhalb der Pakettabelle.")
        try bounded(recordOffset - tocStart, 64, by: tocSize)
        try require(writeOffset <= originalSize && UInt64(oldCount) == originalSize - writeOffset,
                    "Ungültiger Metadatenbereich im Protokoll.")
        if oldCount > 0 {
            try require(try oldRecord.uint(32, 8) == writeOffset && oldRecord.uint(40, 4) == UInt64(oldCount),
                        "Wiederherstellungsbereich ist kein ursprünglicher Metadatenblock.")
        }
        var expectedRecord = oldRecord
        expectedRecord.put(newCount == 0 ? 0 : writeOffset, at: 32, width: 8)
        expectedRecord.put(UInt64(newCount), at: 40, width: 4)
        try require(newRecord == expectedRecord, "Metadaten-Protokoll verändert die Paketidentität.")
        try require(writeOffset <= UInt64.max - UInt64(newCount), "Metadatenoffset ist zu groß.")
        var expectedHeader = oldHeader
        expectedHeader.put(writeOffset + UInt64(newCount), at: 64, width: 8)
        expectedHeader.put(try newHeader.bytes(24, 32), at: 24)
        try require(newHeader == expectedHeader, "Metadaten-Protokoll verändert den Containeraufbau.")
    }

    func prepare(url: URL) throws {
        let paths = Self.journals(for: url)
        try require(!FileManager.default.fileExists(atPath: paths.pending.path) &&
                    !FileManager.default.fileExists(atPath: paths.committed.path),
                    "Eine frühere Metadaten-Aktualisierung muss zuerst wiederhergestellt werden.")
        let temporary = paths.pending.appendingPathExtension(UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(descriptor >= 0, "Metadaten-Protokoll kann nicht angelegt werden.")
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
        try output.write(contentsOf: journalData)
        try output.synchronize()
        try require(renamex_np(temporary.path, paths.pending.path, UInt32(RENAME_EXCL)) == 0,
                    "Metadaten-Protokoll kann nicht veröffentlicht werden.")
        Self.syncDirectory(url.deletingLastPathComponent())
    }

    func writePayload(to file: FileHandle) throws {
        try file.seek(toOffset: writeOffset)
        try file.write(contentsOf: newBlock)
        try file.truncate(atOffset: writeOffset + UInt64(newBlock.count))
        try file.synchronize()
    }
    func writeRecord(to file: FileHandle) throws {
        try file.seek(toOffset: recordOffset)
        try file.write(contentsOf: newRecord)
    }
    func writeHeader(to file: FileHandle) throws {
        try file.seek(toOffset: 0)
        try file.write(contentsOf: newHeader)
        try file.synchronize()
    }
    func markCommitted(url: URL) throws {
        let paths = Self.journals(for: url)
        try require(renamex_np(paths.pending.path, paths.committed.path, UInt32(RENAME_EXCL)) == 0,
                    "Metadaten-Aktualisierung konnte nicht abgeschlossen werden.")
        Self.syncDirectory(url.deletingLastPathComponent())
    }

    private func requireIdentity(_ file: FileHandle) throws {
        let revision = try FileRevision(handle: file)
        try require(UInt64(UInt32(bitPattern: revision.device)) == device && UInt64(revision.inode) == inode,
                    "Das Metadaten-Protokoll gehört zu einer anderen Datei.")
    }

    /// Checks only the header, TOC and metadata ranges touched by this operation.
    func restore(url: URL, file: FileHandle) throws {
        try requireIdentity(file)
        let size = try file.seekToEnd()
        let newSize = writeOffset + UInt64(newBlock.count)
        try require(size >= writeOffset && size <= max(originalSize, newSize),
                    "Die Datei wurde außerhalb der Metadaten-Aktualisierung verändert.")
        let currentHeader = try readRange(file, offset: 0, count: 128)
        try require(Self.isPartial(currentHeader, old: oldHeader, new: newHeader),
                    "Der Header wurde außerhalb der Metadaten-Aktualisierung verändert.")
        let tocStart = try oldHeader.uint(8, 8)
        var originalTOC = try readRange(file, offset: tocStart, count: integer(oldHeader.uint(16, 8)))
        let relative = try integer(recordOffset - tocStart)
        let record = try originalTOC.bytes(relative, 64)
        try require(Self.isPartial(record, old: oldRecord, new: newRecord), "Der Paketdatensatz wurde inzwischen verändert.")
        originalTOC.put(oldRecord, at: relative)
        try require(try originalTOC.sha256 == oldHeader.bytes(24, 32), "Das Inhaltsverzeichnis wurde inzwischen verändert.")
        try validateRecoveryBounds(toc: originalTOC)
        let currentTail = try readRange(file, offset: writeOffset, count: integer(size - writeOffset))
        try require(Self.isPartial(currentTail, old: oldTail, new: newBlock), "Die Metadaten wurden inzwischen anderweitig verändert.")
        // Validate all journal boundaries before the first recovery write.
        try file.seek(toOffset: writeOffset)
        try file.write(contentsOf: oldTail)
        try file.truncate(atOffset: originalSize)
        try file.seek(toOffset: recordOffset)
        try file.write(contentsOf: oldRecord)
        try file.seek(toOffset: 0)
        try file.write(contentsOf: oldHeader)
        try file.synchronize()
        _ = try NUPArchive(url: url, recoverPendingMetadata: false)
    }

    private func validateRecoveryBounds(toc: Data) throws {
        try require(try toc.bytes(0, 4) == Data([84, 79, 67, 1]), "Ungültige Wiederherstellungs-TOC.")
        let packages = try integer(toc.uint(4, 4))
        let dirs = try integer(toc.uint(8, 8))
        let files = try integer(toc.uint(16, 8))
        try require(packages <= toc.count / 64 && dirs <= toc.count / 24 && files <= toc.count / 80,
                    "Ungültige Knotenzahlen im Metadaten-Protokoll.")
        let filesStart = 48 + packages * 64 + dirs * 24
        try require(filesStart <= toc.count && files * 80 <= toc.count - filesStart,
                    "Abgeschnittene Wiederherstellungs-TOC.")
        let blob = try oldHeader.uint(56, 8)
        let tocStart = try oldHeader.uint(8, 8)
        try require(try UInt64(packages) == oldHeader.uint(72, 4) && tocStart == oldHeader.uint(4, 2) &&
                    tocStart >= 128 && blob >= tocStart + UInt64(toc.count) && writeOffset >= blob,
                    "Wiederherstellungsbereich überlappt die Verwaltungsdaten.")
        for index in 0..<files {
            let position = filesStart + index * 80
            let offset = try toc.uint(position + 16, 8)
            let size = try toc.uint(position + 24, 8)
            if size > 0 {
                try bounded(offset, size, by: writeOffset)
            }
        }
        for index in 0..<packages {
            let position = 48 + index * 64
            let offset = try toc.uint(position + 32, 8)
            let size = try toc.uint(position + 40, 4)
            if tocStart + UInt64(position) == recordOffset && !oldTail.isEmpty {
                try require(offset == writeOffset && size == UInt64(oldTail.count), "Ungültiger ursprünglicher Metadatenblock.")
                _ = try MetadataCodec.parse(oldTail)
            } else if size > 0 {
                try bounded(offset, size, by: writeOffset)
            }
        }
    }

    private static func isPartial(_ data: Data, old: Data, new: Data) -> Bool {
        data.enumerated().allSatisfy { index, byte in
            (index < old.count && old[index] == byte) || (index < new.count && new[index] == byte)
        }
    }
    static func syncDirectory(_ url: URL) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        if descriptor >= 0 { _ = fsync(descriptor); Darwin.close(descriptor) }
    }
    static func lock(_ file: FileHandle) throws {
        try require(flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0,
                    "Diese NUP wird bereits von einem anderen Vorgang bearbeitet.")
    }

    static func update(archive: NUPArchive, package index: Int, metadata: [UInt16: Data], context: JobContext) throws {
        try context.report(0, "Bereite Metadaten-Aktualisierung vor …")
        let file = try regularFile(archive.url, writable: true)
        defer { try? file.close() }
        try lock(file)
        try ArchiveContentJournal.requireAbsent(at: archive.url)
        try archive.revision.requireCurrent(at: archive.url)
        if metadata == archive.packages[index].metadata { return }
        let transaction = try MetadataTransaction(archive: archive, package: index, metadata: metadata, input: file)
        try context.check()
        try transaction.prepare(url: archive.url)
        var mutated = false
        var committed = false
        let paths = journals(for: archive.url)
        do {
            try context.check()
            try archive.revision.requireCurrent(at: archive.url)
            mutated = true
            try transaction.writePayload(to: file)
            try context.check()
            try transaction.writeRecord(to: file)
            try transaction.writeHeader(to: file)
            _ = try NUPArchive(url: archive.url, context: context, recoverPendingMetadata: false)
            let storedBlock = try readRange(file, offset: transaction.writeOffset, count: transaction.newBlock.count)
            try require(storedBlock == transaction.newBlock, "Die gespeicherten Metadaten stimmen nicht mit der Änderung überein.")
            try FileRevision(handle: file).requireCurrent(at: archive.url)
            try context.check()
            try transaction.markCommitted(url: archive.url)
            committed = true
            try? FileManager.default.removeItem(at: paths.committed)
            syncDirectory(archive.url.deletingLastPathComponent())
        } catch {
            if !committed {
                do {
                    if mutated { try transaction.restore(url: archive.url, file: file) }
                    try FileManager.default.removeItem(at: paths.pending)
                    syncDirectory(archive.url.deletingLastPathComponent())
                } catch {
                    throw NUPError("Metadaten-Aktualisierung unterbrochen. Das Wiederherstellungsprotokoll bleibt neben der NUP erhalten. Bitte die Datei erneut öffnen: \(error.localizedDescription)")
                }
            }
            throw error
        }
        try? context.report(1, "Metadaten direkt aktualisiert.")
    }

    static func recoverIfNeeded(url: URL) throws {
        let paths = journals(for: url)
        let pending = FileManager.default.fileExists(atPath: paths.pending.path)
        let committed = FileManager.default.fileExists(atPath: paths.committed.path)
        guard pending || committed else { return }
        try require(!(pending && committed), "Mehrere Metadaten-Protokolle gefunden. Wiederherstellung abgebrochen.")
        let file = try regularFile(url, writable: true)
        defer { try? file.close() }
        try lock(file)
        let journalURL = pending ? paths.pending : paths.committed
        let journalFile = try regularFile(journalURL)
        defer { try? journalFile.close() }
        let size = try journalFile.seekToEnd()
        try require(size <= UInt64(journalLimit), "Metadaten-Protokoll ist zu groß.")
        try journalFile.seek(toOffset: 0)
        let transaction = try MetadataTransaction(journal: readExactly(journalFile, integer(size)))
        try transaction.requireIdentity(file)
        if pending {
            try transaction.restore(url: url, file: file)
        } else {
            let current = try NUPArchive(url: url, recoverPendingMetadata: false)
            try require(current.header == transaction.newHeader, "Abgeschlossene Metadaten-Aktualisierung wurde danach verändert.")
            let record = try readRange(file, offset: transaction.recordOffset, count: 64)
            try require(record == transaction.newRecord, "Abgeschlossener Paketdatensatz stimmt nicht überein.")
            let block = try readRange(file, offset: transaction.writeOffset, count: transaction.newBlock.count)
            try require(block == transaction.newBlock, "Abgeschlossene Metadaten stimmen nicht überein.")
        }
        try FileManager.default.removeItem(at: journalURL)
        syncDirectory(url.deletingLastPathComponent())
    }
}
