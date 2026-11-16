import XCTest
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    func testSelectedRepairChangesOnlyChosenPackageAndKeepsOtherFinding() throws {
        let url = try repairFixture(broken: false)
        try changeRepairTOC(url) { toc in
            toc.put(0x0400FF500E34A000, at: 48, width: 8)
            toc.put(0x0400FF500E34A001, at: 112, width: 8)
        }
        let before = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
        XCTAssertEqual(report.repairTargets, [.package(0), .package(1)])
        let source = try XCTUnwrap(report.source), chosen = try report.selectedLayout([.package(0)])
        XCTAssertEqual(try chosen.toc.bytes(112, 64), try source.toc.bytes(112, 64))
        let repaired = try ArchiveRepair.apply(report, selection: [.package(0)])
        XCTAssertEqual(repaired.packages[0].titleID, 0x0400FF500E34A001)
        XCTAssertEqual(repaired.packages[1].titleID, source.packages[1].titleID)
        XCTAssertEqual(repaired.revision.inode, source.revision.inode)
        var expected = before; expected.put(chosen.header, at: 0); expected.put(chosen.toc, at: try integer(source.header.uint(8, 8)))
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(try ArchiveDiagnosis.inspect(url).repairTargets, [.package(1)])
        XCTAssertThrowsError(try ArchiveRepair.apply(report, selection: [.package(1)])) // stale preview
        noRepairJournal(url)
    }

    func testRepairRejectsEmptyOrUnknownSelectionBeforeWriting() throws {
        let url = try repairFixture(), report = try ArchiveDiagnosis.inspect(url), before = try Data(contentsOf: url)
        for selection: Set<ArchiveRepairTarget> in [[], [.package(99)], [.romfs(999)]] {
            XCTAssertThrowsError(try ArchiveRepair.apply(report, selection: selection))
            XCTAssertEqual(try Data(contentsOf: url), before); noRepairJournal(url)
        }
    }

    private func repairNPDM(_ id: UInt64) -> Data {
        var b = Data(count: 192)
        b.put(Data("META".utf8), at: 0); b.put(128, at: 0x70, width: 4); b.put(64, at: 0x74, width: 4)
        b.put(Data("ACI0".utf8), at: 128); b.put(id, at: 144, width: 8)
        return b
    }
    private func repairCNMT(_ kind: UInt8, id: UInt64, version: UInt32 = 0, application: UInt64 = 0x0100FF500E34A000) -> Data {
        let extended = kind == 0x81 ? 24 : 16
        var b = Data(count: 32 + extended)
        b.put(id, at: 0, width: 8); b.put(UInt64(version), at: 8, width: 4)
        b.put(UInt64(kind), at: 12, width: 1); b.put(UInt64(extended), at: 14, width: 2)
        if kind != 0x80 { b.put(application, at: 32, width: 8) }
        return b
    }
    private func repairFixture(broken: Bool = true, cnmt: Bool = true, conflict: Bool = false) throws -> URL {
        let prefix = "repair-\(UUID().uuidString)"
        try write(prefix + "/dump/base/exefs/main.npdm", repairNPDM(0x0400FF500E34A001))
        try write(prefix + "/dump/base/romfs/base.txt", Data("Switch 2 test base".utf8))
        try write(prefix + "/dump/updates/262144/exefs/main.npdm", repairNPDM(0x0100FF500E34A000))
        try write(prefix + "/dump/updates/262144/romfs/update.txt", Data(repeating: 77, count: 8192))
        if cnmt {
            try write(prefix + "/dump/updates/262144/meta/Patch.cnmt", repairCNMT(0x81, id: 0x0100FF500E34A800, version: 262144))
        }
        try write(prefix + "/dump/dlc/0100ff500e34b001/0/romfs/addon.txt")
        try write(prefix + "/dump/dlc/0100ff500e34b001/0/meta/Addon.cnmt", repairCNMT(0x82, id: 0x0100FF500E34B001))
        let source = root.appendingPathComponent(prefix + "/dump"), url = root.appendingPathComponent(prefix + ".nup")
        var options = PackOptions(); options.name = "Reparatur-Test"; options.displayVersion = "2.0.0"
        try NUPWriter.pack(source: source, destination: url, options: options, context: JobContext())
        let archive = try NUPArchive(url: url)
        var metadata = archive.packages[1].metadata; metadata[4] = Data("2.0.0".utf8)
        if conflict { metadata[1] = repairNPDM(0x0100FF500E34C000) }
        try MetadataTransaction.update(archive: archive, package: 1, metadata: metadata, context: JobContext())
        if broken {
            try changeRepairTOC(url) { toc in
                toc.put(0x0400FF500E34A000, at: 112, width: 8)
                toc.put(0, at: 132, width: 4); toc.put(0, at: 136, width: 1)
            }
        }
        return url
    }
    private func changeRepairTOC(_ url: URL, _ change: (inout Data) throws -> Void) throws {
        var b = try Data(contentsOf: url)
        let start = try integer(b.uint(8, 8)), count = try integer(b.uint(16, 8))
        var toc = try b.bytes(start, count); try change(&toc)
        b.put(toc, at: start); b.put(toc.sha256, at: 24); b.put(try ArchiveDiagnosis.uuid(toc: toc), at: 80)
        try b.write(to: url)
    }
    private func noRepairJournal(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let p = ArchiveRepairJournal.journals(for: url)
        XCTAssertFalse(fm.fileExists(atPath: p.pending.path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: p.committed.path), file: file, line: line)
    }

    func testRepairPreviewIsReadOnlyAndKeepsSwitch2BaseIdentity() throws {
        let url = try repairFixture(), before = try Data(contentsOf: url)
        XCTAssertThrowsError(try NUPArchive(url: url))
        let report = try ArchiveDiagnosis.inspect(url)
        XCTAssertTrue(report.canRepair, "\(report.blockers)")
        XCTAssertEqual(report.packages[0].before, report.packages[0].proposed)
        XCTAssertEqual(report.packages[0].proposed.titleID, 0x0400FF500E34A001)
        XCTAssertEqual(report.packages[1].proposed.titleID, 0x0100FF500E34A000)
        XCTAssertEqual(report.packages[1].proposed.kind, 1)
        XCTAssertEqual(report.packages[1].proposed.version, 262144)
        XCTAssertFalse(report.packages[2].changed)
        XCTAssertEqual(try Data(contentsOf: url), before); noRepairJournal(url)
    }

    func testDirectRepairOnlyChangesIdentityFieldsAndHeaderAndRemainsEditable() throws {
        let url = try repairFixture(), report = try ArchiveDiagnosis.inspect(url), before = try Data(contentsOf: url)
        let source = try XCTUnwrap(report.source), layout = try XCTUnwrap(report.proposed)
        let repaired = try ArchiveRepair.apply(report)
        var expected = before; expected.put(layout.header, at: 0); expected.put(layout.toc, at: try integer(source.header.uint(8, 8)))
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(repaired.revision.inode, source.revision.inode)
        XCTAssertEqual(repaired.revision.permissions, source.revision.permissions)
        XCTAssertEqual(repaired.fileSize, source.fileSize)
        XCTAssertEqual(repaired.packages.map(\.metadata), source.packages.map(\.metadata))
        XCTAssertEqual(repaired.files.map(\.offset), source.files.map(\.offset))
        XCTAssertEqual(repaired.packages[1].text(4, profile: .specification), "2.0.0")
        try repaired.verify(deep: true, context: JobContext()); noRepairJournal(url)
        XCTAssertFalse(try ArchiveDiagnosis.inspect(url).canRepair)
        let changes = MetadataEdit(name: "After repair", publisher: "", displayVersion: "2.0.0", icon: nil)
        try repaired.saveMetadata(package: 0, changes: changes, profile: .specification, destination: url, replacingOriginal: true, context: JobContext())
        try NUPArchive(url: url).verify(deep: true, context: JobContext())
    }

    func testAmbiguousBasesAndConflictingNPDMCannotBeRepaired() throws {
        for url in [try repairFixture(cnmt: false), try repairFixture(conflict: true)] {
            let before = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
            XCTAssertFalse(report.canRepair); XCTAssertFalse(report.blockers.isEmpty)
            XCTAssertThrowsError(try ArchiveRepair.apply(report))
            XCTAssertEqual(try Data(contentsOf: url), before); noRepairJournal(url)
        }
    }

    func testDamagedTOCAndCorruptEvidenceAreNeverResealed() throws {
        let badTOC = try repairFixture(), output = try regularFile(badTOC, writable: true)
        let hashByte = try readRange(output, offset: 24, count: 1)
        try output.seek(toOffset: 24); try output.write(contentsOf: Data([hashByte[0] ^ 1])); try output.close()
        let bytes = try Data(contentsOf: badTOC), bad = try ArchiveDiagnosis.inspect(badTOC)
        XCTAssertFalse(bad.canRepair); XCTAssertNil(bad.source)
        XCTAssertEqual(try Data(contentsOf: badTOC), bytes)
        let url = try repairFixture(), source = try NUPArchive(url: url, recoverPendingMetadata: false, validation: .packageDiagnosis)
        let file = try XCTUnwrap(source.files.first { $0.name == "Patch.cnmt" })
        let handle = try regularFile(url, writable: true)
        try handle.seek(toOffset: file.offset); let byte = try readExactly(handle, 1)
        try handle.seek(toOffset: file.offset); try handle.write(contentsOf: Data([byte[0] ^ 1])); try handle.close()
        let corrupted = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
        XCTAssertFalse(report.canRepair); XCTAssertFalse(report.blockers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), corrupted); noRepairJournal(url)
    }

    func testUUIDOnlyAndStandaloneFlagRepairs() throws {
        let url = try repairFixture(broken: false)
        var b = try Data(contentsOf: url); b[80] ^= 1; try b.write(to: url)
        let report = try ArchiveDiagnosis.inspect(url)
        XCTAssertTrue(report.canRepair); XCTAssertTrue(report.uuidChanged)
        XCTAssertFalse(report.packages.contains(where: \.changed))
        try ArchiveRepair.apply(report).verify(deep: true, context: JobContext())
        let standalone = try repairFixture(broken: false)
        // Convert the first real program into an update with no CNMT: no kind
        // guessing is needed; only the mandatory standalone flags are missing.
        try changeRepairTOC(standalone) { $0.put(1, at: 48 + 24, width: 1) }
        let flags = try ArchiveDiagnosis.inspect(standalone)
        XCTAssertTrue(flags.canRepair, "\(flags.blockers)")
        let fixed = try ArchiveRepair.apply(flags)
        XCTAssertTrue(fixed.packages.filter { $0.kind == 1 }.allSatisfy { $0.flags == 1 })
        try fixed.verify(deep: true, context: JobContext())
    }

    func testRepairEvidenceParsersRejectFalseMagicTruncationAndUnknownTypes() throws {
        var npdm = repairNPDM(0x0100FF500E34A000)
        npdm.put(0, at: 0x70, width: 4)
        XCTAssertThrowsError(try ArchivePackageEvidence.programID(npdm))
        var cnmt = repairCNMT(0x81, id: 0x0100FF500E34A800)
        cnmt.put(65535, at: 16, width: 2)
        XCTAssertThrowsError(try ArchivePackageEvidence.cnmt(cnmt))
        XCTAssertThrowsError(try ArchivePackageEvidence.cnmt(repairCNMT(0x83, id: 1)))
        XCTAssertThrowsError(try ArchivePackageEvidence.cnmt(repairCNMT(0x81, id: 0x0100FF500E34C800)))
    }

    func testCancellationAfterRecordOrHeaderRollsBackOriginalBrokenLayout() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let url = try repairFixture(), original = try Data(contentsOf: url)
        for phase in [L10n.text("Reparaturdatensätze korrigiert …"), L10n.text("Prüfe reparierte NUP …")] {
            let report = try ArchiveDiagnosis.inspect(url), box = Box()
            box.context = JobContext { _, message in if message == phase { box.context?.cancel() } }
            XCTAssertThrowsError(try ArchiveRepair.apply(report, context: box.context!)) { XCTAssertTrue($0 is CancellationError, "\($0)") }
            XCTAssertEqual(try Data(contentsOf: url), original); noRepairJournal(url)
        }
    }

    func testInterruptedRepairsRecoverEveryStageAndCommittedRepairStays() throws {
        for phase in 0...5 {
            let url = try repairFixture(), original = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
            let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
            try journal.prepare(url: url)
            let output = try regularFile(url, writable: true)
            if phase == 1 {
                let entry = try XCTUnwrap(journal.entries.first)
                try output.seek(toOffset: journal.oldHeader.uint(8, 8) + UInt64(entry.offset))
                try output.write(contentsOf: entry.new.prefix(23))
            } else if phase >= 2 { try journal.writeRecords(to: output) }
            if phase == 3 { try output.seek(toOffset: 0); try output.write(contentsOf: journal.newHeader.prefix(41)) }
            else if phase >= 4 { try journal.writeHeader(to: output) }
            if phase == 5 { try ArchiveRepairJournal.markCommitted(url: url) }
            try output.close()
            if phase < 5 {
                XCTAssertThrowsError(try NUPArchive(url: url)) // recovery restores the originally invalid package kind
                XCTAssertEqual(try Data(contentsOf: url), original, "phase \(phase)")
            } else { try NUPArchive(url: url).verify(deep: true, context: JobContext()) }
            noRepairJournal(url)
        }
    }

    func testStaleRepairPreviewAndLockedFileRefuseWithoutWrites() throws {
        let url = try repairFixture(), report = try ArchiveDiagnosis.inspect(url), output = try regularFile(url, writable: true)
        try MetadataTransaction.lock(output)
        XCTAssertThrowsError(try ArchiveRepair.apply(report))
        try output.seekToEnd(); try output.write(contentsOf: Data([7])); try output.close()
        let external = try Data(contentsOf: url)
        XCTAssertThrowsError(try ArchiveRepair.apply(report))
        XCTAssertEqual(try Data(contentsOf: url), external); noRepairJournal(url)
    }

    func testRepairJournalRejectsTamperingForeignFileAndConcurrentMetadataJournal() throws {
        let url = try repairFixture(), original = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
        let source = try XCTUnwrap(report.source), journal = try ArchiveRepairJournal(source: source, layout: XCTUnwrap(report.proposed))
        try journal.prepare(url: url)
        let path = ArchiveRepairJournal.journals(for: url).pending
        var corrupted = journal.data; corrupted[corrupted.count - 1] ^= 1; try corrupted.write(to: path)
        XCTAssertThrowsError(try NUPArchive(url: url)); XCTAssertEqual(try Data(contentsOf: url), original)
        try journal.data.write(to: path)
        let foreign = root.appendingPathComponent("foreign-repair.nup"); try original.write(to: foreign)
        try journal.data.write(to: ArchiveRepairJournal.journals(for: foreign).pending)
        XCTAssertThrowsError(try NUPArchive(url: foreign)); XCTAssertEqual(try Data(contentsOf: foreign), original)
        XCTAssertFalse(try ArchiveDiagnosis.inspect(url).canRepair) // previews do not recover
        var metadata = source.packages[0].metadata; metadata[5] = Data("blocked".utf8)
        XCTAssertThrowsError(try MetadataTransaction.update(archive: source, package: 0, metadata: metadata, context: JobContext()))
        let input = try regularFile(url)
        let transaction = try MetadataTransaction(archive: source, package: 0, metadata: metadata, input: input)
        try transaction.prepare(url: url); try input.close()
        XCTAssertThrowsError(try NUPArchive(url: url)); XCTAssertEqual(try Data(contentsOf: url), original)
        try fm.removeItem(at: MetadataTransaction.journals(for: url).pending)
        XCTAssertThrowsError(try NUPArchive(url: url)) // normal recovery, then strict original-layout failure
        noRepairJournal(url)
    }

    func testRepairSparseFourGiBFileNeverCopiesOrRepackagesItsData() throws {
        let url = try repairFixture(), file = try regularFile(url, writable: true)
        let size: UInt64 = 4 * 1024 * 1024 * 1024
        var header = try readRange(file, offset: 0, count: 128); header.put(size, at: 64, width: 8)
        try file.truncate(atOffset: size); try file.seek(toOffset: 0); try file.write(contentsOf: header)
        try file.seek(toOffset: size - 1); try file.write(contentsOf: Data([93])); try file.close()
        let report = try ArchiveDiagnosis.inspect(url), inode = try XCTUnwrap(report.source).revision.inode
        let updated = try ArchiveRepair.apply(report)
        XCTAssertEqual(updated.fileSize, size); XCTAssertEqual(updated.revision.inode, inode)
        let input = try regularFile(url); defer { try? input.close() }
        XCTAssertEqual(try readRange(input, offset: size - 1, count: 1), Data([93]))
        var info = stat(); XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertLessThan(info.st_blocks * 512, 2 * 1024 * 1024)
        try updated.verify(deep: true, context: JobContext()); noRepairJournal(url)
    }

    func testUnrelatedHeaderOrTOCChangesStopRepairRecoveryBeforeWriting() throws {
        for headerChange in [true, false] {
            let url = try repairFixture(), report = try ArchiveDiagnosis.inspect(url)
            let source = try XCTUnwrap(report.source), journal = try ArchiveRepairJournal(source: source, layout: XCTUnwrap(report.proposed))
            try journal.prepare(url: url)
            let file = try regularFile(url, writable: true)
            let at = headerChange ? UInt64(96) : try source.header.uint(8, 8) + UInt64(48 + source.packages.count * 64 + source.directories.count * 24 + 32)
            let byte = try readRange(file, offset: at, count: 1)
            try file.seek(toOffset: at); try file.write(contentsOf: Data([byte[0] ^ 1])); try file.close()
            let external = try Data(contentsOf: url)
            XCTAssertThrowsError(try NUPArchive(url: url))
            XCTAssertEqual(try Data(contentsOf: url), external)
            XCTAssertTrue(fm.fileExists(atPath: ArchiveRepairJournal.journals(for: url).pending.path))
        }
    }

    func testRepairJournalCannotRewriteRootsOrMetadataPointersEvenWithValidChecksum() throws {
        let url = try repairFixture(), report = try ArchiveDiagnosis.inspect(url)
        let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
        for offset in [8, 32] {
            var data = journal.data
            data[312 + 16 + 64 + offset] ^= 1
            let end = data.count - 32
            data.put(try data.bytes(0, end).sha256, at: end)
            XCTAssertThrowsError(try ArchiveRepairJournal(data: data))
        }
    }

    func testDiagnosticAndVirtualSnapshotsCannotBeUsedForNormalEditing() throws {
        let url = try repairFixture(), original = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
        let diagnostic = try XCTUnwrap(report.source)
        let virtual = try NUPArchive(url: url, recoverPendingMetadata: false, repairLayout: XCTUnwrap(report.proposed))
        for snapshot in [diagnostic, virtual] {
            XCTAssertFalse(snapshot.permitsEditing)
            XCTAssertThrowsError(try snapshot.editFiles(package: 0, directory: snapshot.packages[0].root, removing: [0]))
            XCTAssertThrowsError(try MetadataTransaction.update(archive: snapshot, package: 0, metadata: [:], context: JobContext()))
            let copy = root.appendingPathComponent("not-written.nup")
            XCTAssertThrowsError(try snapshot.saveMetadata(package: 0, changes: MetadataEdit(name: "unsafe", publisher: "", displayVersion: "", icon: nil),
                profile: .specification, destination: copy, context: JobContext()))
            XCTAssertFalse(fm.fileExists(atPath: copy.path))
            XCTAssertEqual(try Data(contentsOf: url), original); noRepairJournal(url)
        }
    }

    @MainActor func testFailedOpenOffersReadOnlyPreviewAndRepairRefreshesWorkspace() async throws {
        let url = try repairFixture(), original = try Data(contentsOf: url), suite = "NUPRepairStore-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { preferences.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: preferences)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("Reparaturauftrag wurde nicht beendet.") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(url); try await finish()
        XCTAssertNil(store.error); XCTAssertNil(store.archive); XCTAssertFalse(store.canReceiveFiles)
        let report = try XCTUnwrap(store.repairReport)
        XCTAssertTrue(report.canRepair); XCTAssertEqual(try Data(contentsOf: url), original)
        store.repair(report); try await finish()
        XCTAssertNil(store.repairError); XCTAssertNil(store.repairReport); XCTAssertTrue(store.canReceiveFiles)
        XCTAssertEqual(store.archive?.url, url)
        XCTAssertEqual(store.archive?.packages[0].titleID, 0x0400FF500E34A001)
        XCTAssertEqual(store.archive?.packages[1].kind, 1)
        try store.archive?.verify(deep: true, context: JobContext())
    }
}
