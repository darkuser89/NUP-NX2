import Foundation

enum ArchiveValidation: Sendable { case strict, packageDiagnosis }

/// Only repair diagnostics/journal replay use an in-memory layout. The parser
/// still validates its hash, all bounds, trees, metadata and data regions.
struct ArchiveRepairLayout: Sendable {
    let header: Data
    let toc: Data
}

struct ArchivePackageIdentity: Equatable, Sendable {
    var titleID: UInt64
    var version: UInt32
    var kind: UInt8
    var flags: UInt8
    init(_ package: NUPPackage) {
        titleID = package.titleID; version = package.version; kind = package.kind; flags = package.flags
    }
    var title: String { String(format: "%016llX", titleID) }
    var kindName: String { NUPPackage.kindName(kind) }
    var versionText: String { "\(version) (\(version >> 16).\((version >> 8) & 255).\(version & 255))" }
    func put(into toc: inout Data, package: Int) {
        let at = 48 + package * 64
        toc.put(titleID, at: at, width: 8); toc.put(UInt64(version), at: at + 20, width: 4)
        toc.put(UInt64(kind), at: at + 24, width: 1); toc.put(UInt64(flags), at: at + 25, width: 1)
    }
}

enum ArchivePackageEvidence {
    struct CNMT: Equatable {
        let id: UInt64
        let version: UInt32
        let kind: UInt8
        let application: UInt64?
    }

    static func programID(_ data: Data) throws -> UInt64 {
        try require(data.count >= 128 && data.prefix(4) == Data("META".utf8), L10n.text("NPDM hat keinen gültigen META-Header."))
        let offset = try integer(data.uint(0x70, 4)), size = try integer(data.uint(0x74, 4))
        try require(offset >= 128 && size >= 0x40 && offset <= data.count && size <= data.count - offset,
                    L10n.text("ACI0-Bereich der NPDM ist ungültig."))
        try require(try data.bytes(offset, 4) == Data("ACI0".utf8), L10n.text("ACI0-Kennung fehlt am deklarierten NPDM-Offset."))
        let id = try data.uint(offset + 16, 8)
        try require(id != 0, L10n.text("Die NPDM enthält keine Programm-ID."))
        return id
    }

    static func cnmt(_ data: Data) throws -> CNMT {
        try require(data.count >= 32, L10n.text("CNMT-Header ist abgeschnitten."))
        let id = try data.uint(0, 8), version = UInt32(try data.uint(8, 4)), type = try data.uint(12, 1)
        let extended = try integer(data.uint(14, 2)), contents = try integer(data.uint(16, 2)), metas = try integer(data.uint(18, 2))
        try require(id != 0 && extended <= data.count - 32, L10n.text("Ungültiger CNMT-Erweiterungsheader."))
        let minimum = 32 + extended + contents * 56 + metas * 16
        try require(minimum <= data.count, L10n.text("CNMT-Inhaltstabelle ist abgeschnitten."))
        let kind: UInt8, application: UInt64?
        switch type {
        case 0x80:
            try require(extended >= 16, L10n.text("Application-CNMT-Erweiterung fehlt."))
            kind = 0; application = id
        case 0x81:
            try require(extended >= 24, L10n.text("Patch-CNMT-Erweiterung fehlt."))
            kind = 1; application = try data.uint(32, 8)
            let extra = try integer(data.uint(44, 4))
            try require(extra <= data.count - minimum, L10n.text("CNMT-Patchdaten sind abgeschnitten."))
            let (patch, overflow) = application!.addingReportingOverflow(0x800)
            try require(application != 0 && !overflow && id == patch, L10n.text("Patch-ID und Anwendungs-ID widersprechen sich."))
        case 0x82:
            try require(extended >= 16, L10n.text("DLC-CNMT-Erweiterung fehlt."))
            kind = 2; application = try data.uint(32, 8)
            try require(application != 0, L10n.text("DLC-Anwendungs-ID fehlt."))
        default: throw NUPError(L10n.text("CNMT-Typ \(String(describing: type)) wird nicht automatisch umgedeutet."))
        }
        return CNMT(id: id, version: version, kind: kind, application: application)
    }
}
