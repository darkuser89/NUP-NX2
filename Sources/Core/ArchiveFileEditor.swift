import Foundation
import CryptoKit
import Darwin

/// Temporary data contains only new files. Unlinking immediately means a process
/// exit also releases it; no orphaned staging file is left beside the NUP.
final class ArchiveFileStage {
    let handle: FileHandle
    private(set) var files: [NUPFile] = []
    let size: UInt64

    init(archive: NUPArchive, urls: [URL], context: JobContext) throws {
        let path = archive.url.deletingLastPathComponent().appendingPathComponent(".nup-stage-\(UUID().uuidString)")
        let fd = Darwin.open(path.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, "Temporärer Platz für neue Dateien ist nicht verfügbar.")
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard Darwin.unlink(path.path) == 0 else {
            try? handle.close(); try? FileManager.default.removeItem(at: path)
            throw NUPError("Temporäre Datei kann nicht sicher vorbereitet werden.")
        }
        for (index, url) in urls.enumerated() {
            try context.report(0.25 * Double(index) / Double(max(1, urls.count)), "Bereite neue Datei vor: \(url.lastPathComponent)")
            let input = try regularFile(url)
            let revision: FileRevision
            do { revision = try FileRevision(handle: input); try input.close() }
            catch { try? input.close(); throw error }
            try require(revision.device != archive.revision.device || revision.inode != archive.revision.inode,
                        "Die NUP kann nicht als Datei in sich selbst eingefügt werden.")
            try revision.requireCurrent(at: url)
            let cursor = try handle.offset(), start = try aligned(cursor)
            try handle.write(contentsOf: Data(count: Int(start - cursor)))
            var file = try StreamCodec.encode(url, output: handle, level: 3, context: context)
            try revision.requireCurrent(at: url)
            file.name = url.lastPathComponent.precomposedStringWithCanonicalMapping
            files.append(file)
        }
        size = try handle.offset()
        try handle.synchronize()
        for file in files { try StreamCodec.consume(file, input: handle, context: context) }
    }
    deinit { try? handle.close() }
}

struct ArchiveCopiedExtent {
    let offset: UInt64
    let count: UInt64
    let digest: Data
}

extension ArchiveFilePlan {
    func appendPayloads(input: FileHandle, output: FileHandle, stage: FileHandle, context: JobContext) throws -> [ArchiveCopiedExtent] {
        var copied: [ArchiveCopiedExtent] = []
        func copy(_ source: FileHandle, offset: UInt64, count: UInt64, destination: UInt64) throws -> Data {
            var hash = SHA256(), position: UInt64 = 0
            try output.seek(toOffset: destination)
            while position < count {
                try context.check()
                let data = try readRange(source, offset: offset + position,
                                         count: Int(min(UInt64(StreamCodec.chunkSize), count - position)))
                hash.update(data: data); try output.write(contentsOf: data); position += UInt64(data.count)
            }
            return Data(hash.finalize())
        }
        for (index, move) in moves.enumerated() {
            try context.report(0.3 + 0.3 * Double(index) / Double(max(1, moves.count)), "Bewahre vorhandene Datenblöcke …")
            let hash = try copy(input, offset: move.source.offset, count: move.source.count, destination: move.destination)
            copied.append(ArchiveCopiedExtent(offset: move.destination, count: move.source.count, digest: hash))
        }
        if stageSize > 0 {
            try context.report(0.65, "Füge neue Dateien hinzu …")
            _ = try copy(stage, offset: 0, count: stageSize, destination: stageOffset)
        }
        try output.truncate(atOffset: header.uint(64, 8)); try output.synchronize()
        return copied
    }
    func writeTOC(to output: FileHandle) throws {
        try output.seek(toOffset: header.uint(8, 8)); try output.write(contentsOf: toc)
    }
    func writeHeader(to output: FileHandle) throws {
        try output.seek(toOffset: 0); try output.write(contentsOf: header); try output.synchronize()
    }
}

extension NUPArchive {
    func editFiles(package: Int, directory: Int, adding urls: [URL] = [], removing: Set<Int> = [],
                   context: JobContext = JobContext()) throws -> NUPArchive {
        try context.report(0, "Bereite Dateiänderung vor …")
        let output = try regularFile(url, writable: true)
        defer { try? output.close() }
        try MetadataTransaction.lock(output)
        try ArchiveContentJournal.requireNoPendingChanges(at: url)
        try revision.requireCurrent(at: url)
        // Validate names, ownership and removals before compressing input files.
        let placeholders = try urls.map { source -> NUPFile in
            try require(source.isFileURL, "Nur lokale Dateien können hinzugefügt werden.")
            return NUPFile(name: source.lastPathComponent.precomposedStringWithCanonicalMapping)
        }
        _ = try ArchiveFilePlan(archive: self, package: package, directory: directory,
                               additions: placeholders, stageSize: 0, removing: removing)
        if urls.isEmpty && removing.isEmpty { return self }
        let stage = try ArchiveFileStage(archive: self, urls: urls, context: context)
        let plan = try ArchiveFilePlan(archive: self, package: package, directory: directory,
                                      additions: stage.files, stageSize: stage.size, removing: removing)
        let journal = ArchiveContentJournal(archive: self, plan: plan)
        let input = try regularFile(url)
        defer { try? input.close() }
        try revision.requireCurrent(at: url)
        try journal.prepare(url: url, file: input, context: context)
        var mutated = false, committed = false
        let paths = ArchiveContentJournal.journals(for: url)
        do {
            try context.check(); try revision.requireCurrent(at: url)
            mutated = true
            let copied = try plan.appendPayloads(input: input, output: output, stage: stage.handle, context: context)
            try context.report(0.8, "Aktualisiere Dateiverzeichnis …", force: true)
            try context.check(); try plan.writeTOC(to: output)
            try context.check(); try plan.writeHeader(to: output)
            try context.report(0.9, "Prüfe geänderten Container …", force: true)
            let updated = try NUPArchive(url: url, context: context, recoverPendingMetadata: false)
            try require(updated.header == plan.header && updated.toc == plan.toc, "Gespeichertes Inhaltsverzeichnis stimmt nicht überein.")
            for extent in copied {
                var hash = SHA256(), position: UInt64 = 0
                while position < extent.count {
                    try context.check()
                    let data = try readRange(input, offset: extent.offset + position,
                        count: Int(min(UInt64(StreamCodec.chunkSize), extent.count - position)))
                    hash.update(data: data); position += UInt64(data.count)
                }
                try require(Data(hash.finalize()) == extent.digest, "Ein verschobener Datenblock stimmt nicht überein.")
            }
            for index in plan.addedIndices { try StreamCodec.consume(updated.files[index], input: input, context: context) }
            try FileRevision(handle: output).requireCurrent(at: url)
            try context.check(); try ArchiveContentJournal.markCommitted(url: url)
            committed = true
            try? FileManager.default.removeItem(at: paths.committed)
            MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
            try? context.report(1, "Dateien direkt aktualisiert.")
            return updated
        } catch {
            if !committed {
                do {
                    if mutated { try ArchiveContentJournal.rollback(url: url, file: output) }
                    else { try FileManager.default.removeItem(at: paths.pending) }
                } catch {
                    throw NUPError("Dateiänderung unterbrochen. Das Wiederherstellungsprotokoll bleibt neben der NUP. Bitte erneut öffnen: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }
}
