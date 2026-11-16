import Foundation

enum ArchiveRepair {
    static func apply(_ report: ArchiveRepairReport, selection: Set<ArchiveRepairTarget>? = nil,
                      context: JobContext = JobContext()) throws -> NUPArchive {
        try require(report.canRepair, "Dieser Befund ist nicht sicher automatisch reparierbar.")
        guard let source = report.source, let complete = report.proposed else { throw NUPError("Reparaturvorschau fehlt.") }
        let selected = selection ?? report.repairTargets
        let file = try regularFile(report.url, writable: true); defer { try? file.close() }
        try MetadataTransaction.lock(file)
        try ArchiveRepairJournal.requireNoPendingChanges(at: report.url)
        try source.revision.requireCurrent(at: report.url)
        // Re-read and hash evidence under the write lock; never act on a stale preview.
        let fresh = try ArchiveDiagnosis.inspect(report.url, context: context)
        try require(fresh.canRepair && fresh.source?.header == source.header && fresh.source?.toc == source.toc &&
                    fresh.proposed?.header == complete.header && fresh.proposed?.toc == complete.toc,
                    "Die Belege haben sich seit der Vorschau geändert. Bitte erneut diagnostizieren.")
        let proposed = try fresh.selectedLayout(selected, context: context)
        try context.check(); try source.revision.requireCurrent(at: report.url)
        let journal = try ArchiveRepairJournal(source: source, layout: proposed)
        _ = try journal.layouts(url: report.url, file: file)
        try journal.prepare(url: report.url)
        var mutated = false, committed = false
        do {
            try context.check(); try source.revision.requireCurrent(at: report.url)
            if !journal.entries.isEmpty { mutated = true; try journal.writeRecords(to: file) }
            try context.report(0.8, "Reparaturdatensätze korrigiert …", force: true)
            try context.check(); mutated = true; try journal.writeHeader(to: file)
            try context.report(0.9, "Prüfe reparierte NUP …", force: true)
            let current = try NUPArchive(url: report.url, context: context, recoverPendingMetadata: false)
            try require(current.header == proposed.header && current.toc == proposed.toc, "Reparatur wurde nicht korrekt zurückgelesen.")
            try FileRevision(handle: file).requireCurrent(at: report.url)
            try context.check(); try ArchiveRepairJournal.markCommitted(url: report.url)
            committed = true
            try? FileManager.default.removeItem(at: ArchiveRepairJournal.journals(for: report.url).committed)
            MetadataTransaction.syncDirectory(report.url.deletingLastPathComponent())
            return current
        } catch {
            if !committed {
                do {
                    if mutated { try ArchiveRepairJournal.rollback(url: report.url, file: file) }
                    else { try FileManager.default.removeItem(at: ArchiveRepairJournal.journals(for: report.url).pending) }
                }
                catch { throw NUPError("Reparatur unterbrochen. Protokoll neben der NUP belassen und erneut öffnen: \(error.localizedDescription)") }
            }
            throw error
        }
    }
}
