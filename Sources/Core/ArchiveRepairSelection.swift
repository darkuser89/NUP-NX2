import Foundation

enum ArchiveRepairTarget: Hashable, Sendable {
    case package(Int), romfs(Int), uuid
}

extension ArchiveRepairReport {
    var repairTargets: Set<ArchiveRepairTarget> {
        var targets = Set(packages.filter(\.changed).map { ArchiveRepairTarget.package($0.id) })
        targets.formUnion(romfs.map { .romfs($0.id) })
        // A UUID update caused by selected package edits is automatic, not an
        // independent switch that could leave inconsistent container metadata.
        if let source, let expected = try? ArchiveDiagnosis.uuid(toc: source.toc), expected != source.uuid {
            targets.insert(.uuid)
        }
        return targets
    }

    func selectedLayout(_ selection: Set<ArchiveRepairTarget>, context: JobContext = JobContext()) throws -> ArchiveRepairLayout {
        try require(canRepair && !selection.isEmpty && selection.isSubset(of: repairTargets), L10n.text("Bitte sicher reparierbare Befunde auswählen."))
        guard let source else { throw NUPError(L10n.text("Reparaturvorschau fehlt.")) }
        var toc = source.toc
        for finding in packages where selection.contains(.package(finding.id)) {
            finding.proposed.put(into: &toc, package: finding.id)
        }
        for finding in romfs where selection.contains(.romfs(finding.id)) {
            finding.put(into: &toc, packages: source.packages.count)
        }
        var header = source.header
        header.put(toc.sha256, at: 24); header.put(try ArchiveDiagnosis.uuid(toc: toc), at: 80)
        let layout = ArchiveRepairLayout(header: header, toc: toc)
        do {
            _ = try NUPArchive(url: url, context: context, recoverPendingMetadata: false, repairLayout: layout)
        } catch is CancellationError { throw CancellationError() }
        catch { throw NUPError(L10n.text("Diese Befunde müssen zusammen repariert werden. Auswahl ergänzen: \(String(describing: error.localizedDescription))")) }
        try source.revision.requireCurrent(at: url)
        return layout
    }
}
