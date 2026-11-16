import Foundation

struct ArchiveFileFailure: Identifiable, Sendable {
    let id: Int // file-table index, not a display row number
    let package: Int
    let path: String
    let message: String
}

struct ArchiveFileCheck: Sendable {
    var checked = 0
    var failed = 0
    var failures: [ArchiveFileFailure] = []
    static let detailLimit = 10_000
}

enum ArchiveInspection {
    /// Read-only, bounded streaming verification. A bad frame/hash belongs to
    /// one file; cancellation and a changed source invalidate the entire result.
    static func inspect(_ url: URL, deep: Bool, context: JobContext = JobContext()) throws -> ArchiveRepairReport {
        var report = try ArchiveDiagnosis.inspect(url, context: context)
        report.deepInspection = deep
        guard deep, let source = report.source else { return report }
        let input = try regularFile(url)
        defer { try? input.close() }
        try require(FileRevision(handle: input) == source.revision, L10n.text("Die NUP wurde während der Prüfung verändert. Bitte erneut prüfen."))
        var check = ArchiveFileCheck()
        for (index, file) in source.files.enumerated() {
            try context.report(Double(index) / Double(max(1, source.files.count)), .localized("Datei \(String(describing: index + 1))/\(String(describing: source.files.count)): \(String(describing: file.name))"), force: index == 0)
            do { try StreamCodec.consume(file, input: input, context: context) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try source.revision.requireCurrent(at: url)
                check.failed += 1
                if check.failures.count < ArchiveFileCheck.detailLimit {
                    let node = source.directories.count + index
                    let package = source.packageForNode(node)!
                    let parent = source.fileLocation(node: node, package: package)!.path
                    check.failures.append(ArchiveFileFailure(id: index, package: package,
                        path: (parent == "/" ? "" : parent) + "/" + file.name, message: error.localizedDescription))
                }
            }
            check.checked += 1
        }
        try source.revision.requireCurrent(at: url)
        try require(FileRevision(handle: input) == source.revision, L10n.text("Die NUP wurde während der Prüfung verändert. Bitte erneut prüfen."))
        report.fileCheck = check
        try context.report(1, .localized("\(String(describing: check.checked)) Dateien geprüft · \(String(describing: check.failed)) Dateifehler."))
        return report
    }
}
