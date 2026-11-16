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
        try require(fd >= 0, L10n.text("Temporärer Platz für neue Dateien ist nicht verfügbar."))
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard Darwin.unlink(path.path) == 0 else {
            try? handle.close(); try? FileManager.default.removeItem(at: path)
            throw NUPError(L10n.text("Temporäre Datei kann nicht sicher vorbereitet werden."))
        }
        for (index, url) in urls.enumerated() {
            try context.report(0.25 * Double(index) / Double(max(1, urls.count)), L10n.text("Bereite neue Datei vor: \(String(describing: url.lastPathComponent))"))
            let input = try regularFile(url)
            let revision: FileRevision
            do { revision = try FileRevision(handle: input); try input.close() }
            catch { try? input.close(); throw error }
            try require(revision.device != archive.revision.device || revision.inode != archive.revision.inode,
                        L10n.text("Die NUP kann nicht als Datei in sich selbst eingefügt werden."))
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
            try context.report(0.3 + 0.3 * Double(index) / Double(max(1, moves.count)), L10n.text("Bewahre vorhandene Datenblöcke …"))
            let hash = try copy(input, offset: move.source.offset, count: move.source.count, destination: move.destination)
            copied.append(ArchiveCopiedExtent(offset: move.destination, count: move.source.count, digest: hash))
        }
        if stageSize > 0 {
            try context.report(0.65, L10n.text("Füge neue Dateien hinzu …"))
            _ = try copy(stage, offset: 0, count: stageSize, destination: stageOffset)
        }
        for block in metadataWrites {
            try context.check(); try output.seek(toOffset: block.offset); try output.write(contentsOf: block.data)
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
        do {
            return try applyEdits(ArchiveEditRequest(files: [ArchiveFileMutation(package: package, directory: directory,
                additions: urls, removing: removing)]), context: context)
        } catch let failure as ArchiveEditFailure { throw failure.underlying }
    }

    func applyEdits(_ request: ArchiveEditRequest, context: JobContext = JobContext()) throws -> NUPArchive {
        try require(permitsEditing, L10n.text("Ein Diagnose-Snapshot darf nicht zur normalen Bearbeitung verwendet werden."))
        try context.report(0, L10n.text("Bereite Änderungen vor …"))
        let output = try regularFile(url, writable: true)
        defer { try? output.close() }
        try MetadataTransaction.lock(output)
        try ArchiveContentJournal.requireNoPendingChanges(at: url)
        try revision.requireCurrent(at: url)
        for (url, revision) in request.sourceRevisions { try revision.requireCurrent(at: url) }
        try request.validateImages(in: self)
        let metadata = request.metadata.filter { packages.indices.contains($0.key) && $0.value != packages[$0.key].metadata }
        try require(request.metadata.keys.allSatisfy { packages.indices.contains($0) }, L10n.text("Metadaten-Paket existiert nicht."))
        try require(request.files.flatMap(\.additions).allSatisfy(\.isFileURL), L10n.text("Nur lokale Dateien können hinzugefügt werden."))
        let mutations = request.files.filter { !$0.additions.isEmpty || !$0.removing.isEmpty }
        if mutations.isEmpty && metadata.isEmpty { return self }
        // Keep the existing small bounded metadata transaction for a single package.
        if mutations.isEmpty && metadata.count == 1, let entry = metadata.first {
            try output.close() // the metadata transaction takes its own exclusive lock
            var recovered: NUPArchive?
            do { try MetadataTransaction.update(archive: self, package: entry.key, metadata: entry.value, context: context, didRollback: { recovered = $0 }) }
            catch {
                if let recovered { throw ArchiveEditFailure(underlying: error, recovered: recovered) }
                throw error
            }
            return try NUPArchive(url: url, context: context, recoverPendingMetadata: false)
        }
        let placeholders = mutations.map { mutation in
            ArchiveFilePlanGroup(package: mutation.package, directory: mutation.directory,
                additions: mutation.additions.map { NUPFile(name: $0.lastPathComponent.precomposedStringWithCanonicalMapping) }, removing: mutation.removing)
        }
        _ = try ArchiveFilePlan(archive: self, groups: placeholders, stageSize: 0, metadata: metadata)
        let stage = try ArchiveFileStage(archive: self, urls: mutations.flatMap(\.additions), context: context)
        for (url, revision) in request.sourceRevisions { try revision.requireCurrent(at: url) }
        var cursor = 0
        let groups = mutations.map { mutation -> ArchiveFilePlanGroup in
            let end = cursor + mutation.additions.count
            defer { cursor = end }
            return ArchiveFilePlanGroup(package: mutation.package, directory: mutation.directory,
                additions: Array(stage.files[cursor..<end]), removing: mutation.removing)
        }
        let plan = try ArchiveFilePlan(archive: self, groups: groups, stageSize: stage.size, metadata: metadata)
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
            try context.report(0.8, L10n.text("Aktualisiere Dateiverzeichnis …"), force: true)
            try context.check(); try plan.writeTOC(to: output)
            try context.check(); try plan.writeHeader(to: output)
            try context.report(0.9, L10n.text("Prüfe geänderten Container …"), force: true)
            let updated = try NUPArchive(url: url, context: context, recoverPendingMetadata: false)
            try require(updated.header == plan.header && updated.toc == plan.toc, L10n.text("Gespeichertes Inhaltsverzeichnis stimmt nicht überein."))
            for extent in copied {
                var hash = SHA256(), position: UInt64 = 0
                while position < extent.count {
                    try context.check()
                    let data = try readRange(input, offset: extent.offset + position,
                        count: Int(min(UInt64(StreamCodec.chunkSize), extent.count - position)))
                    hash.update(data: data); position += UInt64(data.count)
                }
                try require(Data(hash.finalize()) == extent.digest, L10n.text("Ein verschobener Datenblock stimmt nicht überein."))
            }
            for index in plan.addedIndices { try StreamCodec.consume(updated.files[index], input: input, context: context) }
            for block in plan.metadataWrites {
                try require(try readRange(input, offset: block.offset, count: block.data.count) == block.data, L10n.text("Gespeicherte Metadaten stimmen nicht überein."))
            }
            for (index, values) in metadata { try require(updated.packages[index].metadata == values, L10n.text("Paket-Metadaten stimmen nicht überein.")) }
            try FileRevision(handle: output).requireCurrent(at: url)
            try context.check(); try ArchiveContentJournal.markCommitted(url: url)
            committed = true
            try? FileManager.default.removeItem(at: paths.committed)
            MetadataTransaction.syncDirectory(url.deletingLastPathComponent())
            try? context.report(1, L10n.text("Dateien direkt aktualisiert."))
            return updated
        } catch {
            var recovered: NUPArchive?
            if !committed {
                do {
                    if mutated {
                        try ArchiveContentJournal.rollback(url: url, file: output)
                        recovered = try NUPArchive(url: url, recoverPendingMetadata: false)
                    }
                    else { try FileManager.default.removeItem(at: paths.pending) }
                } catch {
                    throw NUPError(L10n.text("Dateiänderung unterbrochen. Das Wiederherstellungsprotokoll bleibt neben der NUP. Bitte erneut öffnen: \(String(describing: error.localizedDescription))"))
                }
            }
            if let recovered { throw ArchiveEditFailure(underlying: error, recovered: recovered) }
            throw error
        }
    }
}
