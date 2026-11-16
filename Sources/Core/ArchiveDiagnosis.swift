import Foundation

struct ArchivePackageFinding: Identifiable, Sendable {
    let id: Int
    let before: ArchivePackageIdentity
    var proposed: ArchivePackageIdentity
    var evidence: [String] = []
    var changed: Bool { before != proposed }
}

struct ArchiveRepairReport: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let originalError: String?
    var packages: [ArchivePackageFinding] = []
    var romfs: [ArchiveROMFSRepair] = []
    var blockers: [String] = []
    var warnings: [String] = []
    var uuidChanged = false
    var deepInspection = false
    var fileCheck: ArchiveFileCheck?
    var source: NUPArchive?
    var proposed: ArchiveRepairLayout?
    var canRepair: Bool { blockers.isEmpty && proposed != nil && (uuidChanged || !romfs.isEmpty || packages.contains(where: \.changed)) }
}

enum ArchiveDiagnosis {
    static func uuid(toc: Data) throws -> Data {
        let count = try integer(toc.uint(4, 4))
        try require(count > 0 && count <= (toc.count - 48) / 64, "Ungültige Pakettabelle.")
        var identity = Data()
        for index in 0..<count {
            let at = 48 + index * 64
            identity.append(try toc.bytes(at, 8)); identity.append(try toc.bytes(at + 20, 5))
        }
        return Data(identity.sha256.prefix(16))
    }

    static func inspect(_ url: URL, originalError: String? = nil, context: JobContext = JobContext()) throws -> ArchiveRepairReport {
        var report = ArchiveRepairReport(url: url, originalError: originalError)
        do {
            try ArchiveRepairJournal.requireNoPendingChanges(at: url)
            let archive = try NUPArchive(url: url, context: context, recoverPendingMetadata: false, validation: .packageDiagnosis)
            report.source = archive
            report.romfs = archive.romfsRepairs
            let input = try regularFile(url)
            defer { try? input.close() }
            var budget = 64 * 1024 * 1024, count = 0
            func evidence(_ file: NUPFile) throws -> Data {
                try require(file.size <= 4 * 1024 * 1024 && file.storedSize <= 8 * 1024 * 1024 &&
                            file.size + file.storedSize <= UInt64(budget) && count < 256,
                            "Belegdateien überschreiten das Diagnose-Limit.")
                count += 1; budget -= Int(file.size + file.storedSize)
                var data = Data()
                try StreamCodec.consume(file, input: input, context: context) { data.append($0) }
                return data
            }
            for package in archive.packages {
                try context.report(Double(package.id) / Double(archive.packages.count), "Prüfe Paketbelege \(package.id + 1) …")
                let identity = ArchivePackageIdentity(package)
                var finding = ArchivePackageFinding(id: package.id, before: identity, proposed: identity)
                do {
                    var program: UInt64?
                    if let exefs = package.exefs {
                        let npdms = archive.directories[exefs].children.filter {
                            $0 >= archive.directories.count && archive.files[$0 - archive.directories.count].name == "main.npdm"
                        }
                        if let node = npdms.first {
                            let data = try evidence(archive.files[node - archive.directories.count])
                            program = try ArchivePackageEvidence.programID(data)
                            if let metadata = package.metadata[1] {
                                try require(metadata == data, "NPDM im Dateibaum und Metadaten-TLV widersprechen sich.")
                            }
                            finding.evidence.append("exefs/main.npdm · SHA-256 geprüft · \(String(format: "%016llX", program!))")
                        }
                    }
                    // Only direct meta/*.cnmt members are interpreted. Filenames
                    // never determine a package kind or an ID.
                    let metaDirs = archive.directories[package.root].children.filter {
                        $0 < archive.directories.count && archive.directories[$0].name == "meta"
                    }
                    var cnmts: [ArchivePackageEvidence.CNMT] = []
                    for directory in metaDirs {
                        for node in archive.directories[directory].children where node >= archive.directories.count {
                            let file = archive.files[node - archive.directories.count]
                            guard file.name.lowercased().hasSuffix(".cnmt") else { continue }
                            let cnmt = try ArchivePackageEvidence.cnmt(evidence(file))
                            cnmts.append(cnmt)
                            finding.evidence.append("meta/\(file.name) · SHA-256 geprüft · NCM-Version \(cnmt.version)")
                        }
                    }
                    if let cnmt = cnmts.first {
                        try require(cnmts.allSatisfy { $0 == cnmt }, "Mehrere CNMTs liefern widersprüchliche Paketangaben.")
                        if cnmt.kind == 2 {
                            try require(program == nil, "DLC-CNMT und ausführbares NPDM-Programm widersprechen sich.")
                            finding.proposed.titleID = cnmt.id
                        } else {
                            guard let program else { throw NUPError("Für diese CNMT fehlt eine verifizierbare exefs/main.npdm.") }
                            try require((program & ~UInt64(0xf)) == cnmt.application!, "NPDM und CNMT gehören zu unterschiedlichen Anwendungen.")
                            finding.proposed.titleID = program
                        }
                        finding.proposed.kind = cnmt.kind; finding.proposed.version = cnmt.version
                    } else if let program {
                        try require(package.kind == 0 || package.kind == 1, "Ohne CNMT ist die Paketart nicht eindeutig belegbar.")
                        finding.proposed.titleID = program
                        report.warnings.append("Paket \(package.id + 1): keine CNMT; Paketart und interne Version bleiben unverändert.")
                    } else {
                        report.warnings.append("Paket \(package.id + 1): keine auswertbaren Belegdateien; Paketangaben bleiben unverändert.")
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { report.blockers.append("Paket \(package.id + 1): \(error.localizedDescription)") }
                report.packages.append(finding)
            }
            let bases = report.packages.filter { $0.proposed.kind == 0 }.count
            if bases > 1 { report.blockers.append("Auch nach Auswertung der Belege bleiben mehrere Basispakete. Die App rät keine Paketart und entfernt keine Programme.") }
            for index in report.packages.indices where report.packages[index].proposed.kind == 1 {
                report.packages[index].proposed.flags = bases == 0 ? 1 : 0
            }
            if report.packages.filter(\.changed).count + report.romfs.count > 4096 {
                report.blockers.append("Mehr als 4096 Paket-/RomFS-Korrekturen überschreiten das Reparaturlimit.")
            }
            var toc = archive.toc
            for finding in report.packages { finding.proposed.put(into: &toc, package: finding.id) }
            for finding in report.romfs { finding.put(into: &toc, packages: archive.packages.count) }
            var header = archive.header
            header.put(toc.sha256, at: 24); header.put(try uuid(toc: toc), at: 80)
            report.uuidChanged = try archive.header.bytes(80, 16) != header.bytes(80, 16)
            let layout = ArchiveRepairLayout(header: header, toc: toc)
            if report.blockers.isEmpty {
                _ = try NUPArchive(url: url, context: context, recoverPendingMetadata: false, repairLayout: layout)
                report.proposed = layout
            }
            try archive.revision.requireCurrent(at: url)
            try context.report(1, "Diagnose abgeschlossen; noch nichts geschrieben.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            report.proposed = nil
            report.blockers.append(error.localizedDescription)
        }
        return report
    }
}
