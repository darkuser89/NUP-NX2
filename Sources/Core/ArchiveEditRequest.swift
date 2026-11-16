import Foundation
import Darwin

struct ArchiveFileMutation: Sendable {
    let package: Int
    let directory: Int
    var additions: [URL] = []
    var removing: Set<Int> = []
}

struct ArchiveFilePlanGroup {
    let package: Int
    let directory: Int
    let additions: [NUPFile]
    let removing: Set<Int>
}

struct ArchiveEditFailure: LocalizedError {
    let underlying: Error
    let recovered: NUPArchive
    var errorDescription: String? { underlying.localizedDescription }
}

struct ArchiveEditRequest: Sendable {
    var files: [ArchiveFileMutation] = []
    var metadata: [Int: [UInt16: Data]] = [:]
    var sourceRevisions: [URL: FileRevision] = [:]

    func validateImages(in archive: NUPArchive) throws {
        for (index, records) in metadata where archive.packages.indices.contains(index) {
            let old = archive.packages[index].metadata
            if records[3] != old[3], let cover = records[3] {
                try require(LibraryMetadataReader.makeThumbnail(cover) != nil, L10n.text("Das neue Cover ist kein unterstütztes PNG-/JPEG-Bild."))
            }
            if records[10] != old[10], let block = records[10] {
                for cover in try MetadataCodec.localized(block).values {
                    try require(LibraryMetadataReader.makeThumbnail(cover) != nil, L10n.text("Ein neues Sprach-Cover ist kein unterstütztes PNG-/JPEG-Bild."))
                }
            }
        }
    }
}

extension NUPArchive {
    func saveEditsAs(_ request: ArchiveEditRequest, destination: URL, context: JobContext) throws -> NUPArchive {
        try require(permitsEditing, L10n.text("Diagnose-Snapshots können nicht als Bearbeitung gespeichert werden."))
        try require(destination.standardizedFileURL != url.standardizedFileURL, L10n.text("Für die Originaldatei bitte Übernehmen verwenden."))
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".nup-draft-\(UUID().uuidString).partial")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try require(fd >= 0, L10n.text("Temporäre Datei kann nicht angelegt werden."))
        defer {
            for paths in [MetadataTransaction.journals(for: temporary), ArchiveContentJournal.journals(for: temporary)] {
                try? FileManager.default.removeItem(at: paths.pending); try? FileManager.default.removeItem(at: paths.committed)
            }
            try? FileManager.default.removeItem(at: temporary)
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true), input = try regularFile(url)
        defer { try? input.close(); try? output.close() }
        try revision.requireCurrent(at: url)
        try StreamCodec.copy(input, output: output, context: context); try output.synchronize()
        try revision.requireCurrent(at: url)
        let copy = try NUPArchive(url: temporary, context: context, recoverPendingMetadata: false)
        _ = try copy.applyEdits(request, context: context)
        try revision.requireCurrent(at: url); try context.check()
        try publishFile(temporary, to: destination)
        return try NUPArchive(url: destination, context: context, recoverPendingMetadata: false)
    }
}
