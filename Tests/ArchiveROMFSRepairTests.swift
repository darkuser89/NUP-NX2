import XCTest
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    func testIncompleteDependentROMFSSelectionIsRejectedWithoutWriting() throws {
        let healthy = try brokenROMFS(both: true, corruptUUID: true)
        let report = try ArchiveDiagnosis.inspect(healthy.url), before = try Data(contentsOf: healthy.url)
        XCTAssertTrue(report.repairTargets.contains(.uuid))
        let first = try XCTUnwrap(report.romfs.first)
        XCTAssertThrowsError(try report.selectedLayout([.romfs(first.id)]))
        XCTAssertThrowsError(try ArchiveRepair.apply(report, selection: [.romfs(first.id)]))
        XCTAssertEqual(try Data(contentsOf: healthy.url), before); absentROMFSJournal(healthy.url)
        let repaired = try ArchiveRepair.apply(report, selection: report.repairTargets)
        XCTAssertEqual(repaired.directories.map(\.children), healthy.directories.map(\.children))
    }

    private func romfsFixture() throws -> NUPArchive {
        let prefix = "romfs-\(UUID().uuidString)"
        var npdm = Data(count: 192)
        npdm.put(Data("META".utf8), at: 0); npdm.put(128, at: 0x70, width: 4); npdm.put(64, at: 0x74, width: 4)
        npdm.put(Data("ACI0".utf8), at: 128); npdm.put(0x04004D300C5AE001, at: 144, width: 8)
        try write(prefix + "/dump/base/exefs/main.npdm", npdm)
        for i in 0..<14 {
            try write(prefix + String(format: "/dump/base/romfs/dir%02d/file.bin", i), Data(repeating: UInt8(i), count: 8192))
        }
        try fm.createDirectory(at: root.appendingPathComponent(prefix + "/dump/base/romfs/dir00/empty"), withIntermediateDirectories: true)
        try write(prefix + "/dump/dlc/01004d300c5af001/0/romfs/addon.bin", Data("addon".utf8))
        var options = PackOptions(); options.name = "RomFS-Test – keine Spieldaten"
        let url = root.appendingPathComponent(prefix + ".nup")
        try NUPWriter.pack(source: root.appendingPathComponent(prefix + "/dump"), destination: url, options: options, context: JobContext())
        return try NUPArchive(url: url)
    }
    private func changeROMFS(_ archive: NUPArchive, _ change: (inout Data) throws -> Void, corruptUUID: Bool = false) throws {
        var toc = archive.toc; try change(&toc)
        var header = archive.header; header.put(toc.sha256, at: 24)
        if corruptUUID { header[80] ^= 1 }
        let file = try regularFile(archive.url, writable: true); defer { try? file.close() }
        try file.seek(toOffset: header.uint(8, 8)); try file.write(contentsOf: toc)
        try file.seek(toOffset: 0); try file.write(contentsOf: header); try file.synchronize()
    }
    private func romfsCountOffset(_ archive: NUPArchive, package: Int = 0) throws -> Int {
        48 + archive.packages.count * 64 + (try XCTUnwrap(archive.packages[package].romfs)) * 24 + 12
    }
    private func brokenROMFS(both: Bool = false, corruptUUID: Bool = false) throws -> NUPArchive {
        let archive = try romfsFixture()
        try changeROMFS(archive, { toc in
            toc.put(0, at: try romfsCountOffset(archive), width: 4)
            if both { toc.put(0, at: try romfsCountOffset(archive, package: 1), width: 4) }
        }, corruptUUID: corruptUUID)
        return archive
    }
    private func absentROMFSJournal(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let paths = ArchiveRepairJournal.journals(for: url)
        XCTAssertFalse(fm.fileExists(atPath: paths.pending.path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: paths.committed.path), file: file, line: line)
    }

    func testROMFSPreviewReattachesFourteenRootsWithoutWritingOrChangingIDs() throws {
        let healthy = try brokenROMFS(corruptUUID: true), url = healthy.url, before = try Data(contentsOf: url)
        XCTAssertThrowsError(try NUPArchive(url: url))
        let report = try ArchiveDiagnosis.inspect(url)
        XCTAssertTrue(report.canRepair, "\(report.blockers)"); XCTAssertTrue(report.uuidChanged)
        XCTAssertEqual(report.romfs.count, 1); XCTAssertEqual(report.romfs.first?.count, 14)
        XCTAssertEqual(report.romfs.first?.names.first, "dir00")
        XCTAssertFalse(report.packages.contains(where: \.changed))
        let source = try XCTUnwrap(report.source)
        XCTAssertFalse(source.permitsEditing); XCTAssertEqual(source.packages[0].titleID, 0x04004D300C5AE001)
        XCTAssertEqual(try source.toc.uint(romfsCountOffset(healthy), 4), 0)
        XCTAssertEqual(source.directories[try XCTUnwrap(source.packages[0].romfs)].children.count, 14)
        XCTAssertEqual(try Data(contentsOf: url), before); absentROMFSJournal(url)
    }

    func testROMFSRepairWritesOnlyFourByteCountAndHeaderAndKeepsFileEditingUsable() throws {
        let healthy = try brokenROMFS(), url = healthy.url, before = try Data(contentsOf: url)
        let report = try ArchiveDiagnosis.inspect(url), source = try XCTUnwrap(report.source)
        let repaired = try ArchiveRepair.apply(report), after = try Data(contentsOf: url)
        let at = try integer(source.header.uint(8, 8)) + romfsCountOffset(healthy)
        XCTAssertEqual(after.count, before.count)
        for index in before.indices where before[index] != after[index] {
            XCTAssertTrue(index < 128 || (at..<(at + 4)).contains(index), "Unexpected changed byte \(index)")
        }
        XCTAssertEqual(repaired.revision.inode, source.revision.inode)
        XCTAssertEqual(repaired.revision.permissions, source.revision.permissions)
        XCTAssertEqual(repaired.packages.map(\.metadata), healthy.packages.map(\.metadata))
        XCTAssertEqual(repaired.files.map(\.offset), healthy.files.map(\.offset))
        XCTAssertEqual(repaired.files.map(\.hash), healthy.files.map(\.hash))
        XCTAssertEqual(repaired.directories.map(\.children), healthy.directories.map(\.children))
        try repaired.verify(deep: true, context: JobContext()); absentROMFSJournal(url)
        XCTAssertFalse(try ArchiveDiagnosis.inspect(url).canRepair)
        let extra = try write("extra.bin", Data("editable".utf8))
        let edited = try repaired.editFiles(package: 0, directory: XCTUnwrap(repaired.packages[0].romfs), adding: [extra])
        try edited.verify(deep: true, context: JobContext())
    }

    func testROMFSRecoveryCanRepairIndependentBaseAndDLCRangesTogether() throws {
        let healthy = try brokenROMFS(both: true), report = try ArchiveDiagnosis.inspect(healthy.url)
        XCTAssertTrue(report.canRepair, "\(report.blockers)")
        XCTAssertEqual(report.romfs.map(\.count), [14, 1])
        let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
        XCTAssertEqual(journal.entries.map { $0.old.count }, [4, 4])
        let result = try ArchiveRepair.apply(report)
        XCTAssertEqual(result.directories.map(\.children), healthy.directories.map(\.children))
        try result.verify(deep: true, context: JobContext())
    }

    func testHealthyAndGenuinelyEmptyROMFSAreNotOfferedForRepair() throws {
        let healthy = try romfsFixture()
        XCTAssertFalse(try ArchiveDiagnosis.inspect(healthy.url).canRepair)
        try fm.createDirectory(at: root.appendingPathComponent("empty/base/romfs"), withIntermediateDirectories: true)
        try write("empty/base/exefs/main", Data("empty RomFS program fixture".utf8))
        let url = root.appendingPathComponent("empty.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("empty"), destination: url, options: PackOptions(), context: JobContext())
        let report = try ArchiveDiagnosis.inspect(url)
        XCTAssertTrue(report.blockers.isEmpty); XCTAssertTrue(report.romfs.isEmpty); XCTAssertFalse(report.canRepair)
    }

    func testROMFSRecoveryRejectsUnanchoredPartialAndNonROMFSGaps() throws {
        for variant in 0..<4 {
            let healthy = try romfsFixture()
            try changeROMFS(healthy) { toc in
                let at = try romfsCountOffset(healthy)
                toc.put(variant == 1 ? 1 : 0, at: at, width: 4)
                if variant == 0 { toc.put(try toc.uint(at - 4, 4) + 1, at: at - 4, width: 4) }
                if variant == 2 { toc.put(UInt64(UInt32.max), at: 48 + 16, width: 4) }
                if variant == 3 {
                    // Root children also become unused, outside any anchored RomFS gap.
                    let rootAt = 48 + healthy.packages.count * 64 + healthy.packages[0].root * 24 + 12
                    toc.put(0, at: rootAt, width: 4)
                }
            }
            let before = try Data(contentsOf: healthy.url), report = try ArchiveDiagnosis.inspect(healthy.url)
            XCTAssertFalse(report.canRepair, "variant \(variant)"); XCTAssertFalse(report.blockers.isEmpty)
            XCTAssertThrowsError(try ArchiveRepair.apply(report))
            XCTAssertEqual(try Data(contentsOf: healthy.url), before); absentROMFSJournal(healthy.url)
        }
    }

    func testPackageIdentityAndROMFSCountsCanBeRepairedInOneTransaction() throws {
        let healthy = try romfsFixture()
        try changeROMFS(healthy) { toc in
            toc.put(0, at: try romfsCountOffset(healthy), width: 4)
            toc.put(0x04004D300C5AE002, at: 48, width: 8)
        }
        let report = try ArchiveDiagnosis.inspect(healthy.url)
        XCTAssertTrue(report.canRepair, "\(report.blockers)")
        XCTAssertEqual(report.romfs.count, 1); XCTAssertTrue(report.packages[0].changed)
        let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
        XCTAssertEqual(journal.entries.map { $0.old.count }, [64, 4])
        let result = try ArchiveRepair.apply(report)
        XCTAssertEqual(result.packages[0].titleID, 0x04004D300C5AE001)
        XCTAssertEqual(result.directories.map(\.children), healthy.directories.map(\.children))
        try result.verify(deep: true, context: JobContext())
    }

    func testROMFSRecoveryRejectsAmbiguousPackageAnchors() throws {
        let healthy = try romfsFixture()
        try changeROMFS(healthy) { toc in
            let a = try romfsCountOffset(healthy), b = try romfsCountOffset(healthy, package: 1)
            toc.put(0, at: a, width: 4); toc.put(0, at: b, width: 4)
            toc.put(try toc.uint(a - 4, 4), at: b - 4, width: 4)
        }
        let report = try ArchiveDiagnosis.inspect(healthy.url)
        XCTAssertFalse(report.canRepair)
        XCTAssertTrue(report.blockers.contains(L10n.text("Unbenutzte Kindknotenplätze lassen sich keinem leeren /romfs eindeutig zuordnen.")))
    }

    func testROMFSRecoveryStillRejectsCyclesDuplicateNodesAndUnsortedNames() throws {
        for variant in 0..<3 {
            let healthy = try romfsFixture()
            try changeROMFS(healthy) { toc in
                let at = try romfsCountOffset(healthy), first = try integer(toc.uint(at - 4, 4))
                let children = 48 + healthy.packages.count * 64 + healthy.directories.count * 24 + healthy.files.count * 80
                toc.put(0, at: at, width: 4)
                if variant == 0 { toc.put(UInt64(try XCTUnwrap(healthy.packages[0].romfs)), at: children + first * 4, width: 4) }
                if variant == 1 { toc.put(try toc.uint(children + first * 4, 4), at: children + (first + 1) * 4, width: 4) }
                if variant == 2 {
                    let a = try toc.bytes(children + first * 4, 4), b = try toc.bytes(children + (first + 1) * 4, 4)
                    toc.put(b, at: children + first * 4); toc.put(a, at: children + (first + 1) * 4)
                }
            }
            let before = try Data(contentsOf: healthy.url), report = try ArchiveDiagnosis.inspect(healthy.url)
            XCTAssertFalse(report.canRepair); XCTAssertNil(report.source)
            XCTAssertEqual(try Data(contentsOf: healthy.url), before)
        }
    }

    func testROMFSRecoveryRetainsHashBoundsReservedFieldsAndRegionChecks() throws {
        for variant in 0..<4 {
            let healthy = try romfsFixture()
            try changeROMFS(healthy) { toc in
                toc.put(0, at: try romfsCountOffset(healthy), width: 4)
                let files = 48 + healthy.packages.count * 64 + healthy.directories.count * 24
                if variant == 0 { toc.put(1, at: files + 16, width: 8) }
                if variant == 1 { toc.put(1, at: files + 65, width: 1) }
                if variant == 2 {
                    toc.put(healthy.packages[0].metaOffset, at: files + 16, width: 8)
                    toc.put(16, at: files + 24, width: 8); toc.put(16, at: files + 8, width: 8); toc.put(0, at: files + 64, width: 1)
                }
            }
            if variant == 3 {
                let file = try regularFile(healthy.url, writable: true)
                let b = try readRange(file, offset: 24, count: 1)
                try file.seek(toOffset: 24); try file.write(contentsOf: Data([b[0] ^ 1])); try file.close()
            }
            let before = try Data(contentsOf: healthy.url), report = try ArchiveDiagnosis.inspect(healthy.url)
            XCTAssertFalse(report.canRepair, "variant \(variant)"); XCTAssertFalse(report.blockers.isEmpty)
            XCTAssertEqual(try Data(contentsOf: healthy.url), before)
        }
    }

    func testROMFSRepairCancellationRollsBackCountAndHeaderExactly() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let healthy = try brokenROMFS(), original = try Data(contentsOf: healthy.url)
        for phase in [L10n.text("Reparaturdatensätze korrigiert …"), L10n.text("Prüfe reparierte NUP …")] {
            let report = try ArchiveDiagnosis.inspect(healthy.url), box = Box()
            box.context = JobContext { _, message in if message == phase { box.context?.cancel() } }
            XCTAssertThrowsError(try ArchiveRepair.apply(report, context: box.context!)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: healthy.url), original); absentROMFSJournal(healthy.url)
        }
    }

    func testROMFSInterruptedAndCommittedJournalsRecoverAtEveryWriteStage() throws {
        for stage in 0...5 {
            let healthy = try brokenROMFS(both: true, corruptUUID: true), url = healthy.url
            let original = try Data(contentsOf: url), report = try ArchiveDiagnosis.inspect(url)
            let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
            try journal.prepare(url: url)
            let output = try regularFile(url, writable: true)
            if stage == 1 {
                let e = try XCTUnwrap(journal.entries.first)
                try output.seek(toOffset: journal.oldHeader.uint(8, 8) + UInt64(e.offset)); try output.write(contentsOf: e.new.prefix(1))
            } else if stage >= 2 { try journal.writeRecords(to: output) }
            if stage == 3 { try output.seek(toOffset: 0); try output.write(contentsOf: journal.newHeader.prefix(41)) }
            else if stage >= 4 { try journal.writeHeader(to: output) }
            if stage == 5 { try ArchiveRepairJournal.markCommitted(url: url) }
            try output.close()
            if stage < 5 {
                XCTAssertThrowsError(try NUPArchive(url: url))
                XCTAssertEqual(try Data(contentsOf: url), original, "stage \(stage)")
            } else { try NUPArchive(url: url).verify(deep: true, context: JobContext()) }
            absentROMFSJournal(url)
        }
    }

    func testROMFSJournalRejectsForgedCountsAndOffsetsBeforeRecoveryWrites() throws {
        for variant in 0..<3 {
            let healthy = try brokenROMFS(), report = try ArchiveDiagnosis.inspect(healthy.url)
            let source = try XCTUnwrap(report.source), layout = try XCTUnwrap(report.proposed)
            let journal = try ArchiveRepairJournal(source: source, layout: layout)
            var data = journal.data
            let entry = try XCTUnwrap(journal.entries.first)
            var forged = source.toc
            var offset = entry.offset, count: UInt64 = 13
            if variant == 1 {
                let empty = try XCTUnwrap(source.directories.firstIndex { $0.name == "empty" })
                offset = 48 + source.packages.count * 64 + empty * 24 + 12; count = 14
            }
            if variant == 2 { offset = entry.offset - 4; count = 14 }
            forged.put(count, at: offset, width: 4)
            var h = source.header; h.put(forged.sha256, at: 24); h.put(try ArchiveDiagnosis.uuid(toc: forged), at: 80)
            data.put(h, at: 184); data.put(UInt64(offset), at: 312, width: 8)
            data.put(try source.toc.bytes(offset, 4), at: 328); data.put(count, at: 332, width: 4)
            data.put(try data.bytes(0, data.count - 32).sha256, at: data.count - 32)
            let original = try Data(contentsOf: healthy.url)
            try data.write(to: ArchiveRepairJournal.journals(for: healthy.url).pending)
            XCTAssertThrowsError(try NUPArchive(url: healthy.url))
            XCTAssertEqual(try Data(contentsOf: healthy.url), original)
        }
    }

    func testV2JournalRejectsInvalidLengthsFlagsAndExtraTOCChanges() throws {
        let healthy = try brokenROMFS(), report = try ArchiveDiagnosis.inspect(healthy.url)
        let source = try XCTUnwrap(report.source), layout = try XCTUnwrap(report.proposed)
        let journal = try ArchiveRepairJournal(source: source, layout: layout)
        for variant in 0..<3 {
            var b = journal.data
            if variant == 0 { b.put(80, at: 320, width: 4) }
            if variant == 1 { b.put(1, at: 324, width: 4) }
            if variant == 2 { b.insert(0, at: b.count - 32) }
            b.put(try b.bytes(0, b.count - 32).sha256, at: b.count - 32)
            XCTAssertThrowsError(try ArchiveRepairJournal(data: b))
        }
        var extra = layout.toc; extra[40] = 1
        XCTAssertThrowsError(try ArchiveRepairJournal(source: source, layout: ArchiveRepairLayout(header: layout.header, toc: extra)))
    }

    func testLegacyPackageOnlyRepairJournalsStillRecover() throws {
        for committed in [false, true] {
            let healthy = try romfsFixture()
            try changeROMFS(healthy) { $0.put(0x04004D300C5AE002, at: 48, width: 8) }
            let original = try Data(contentsOf: healthy.url), report = try ArchiveDiagnosis.inspect(healthy.url)
            let journal = try ArchiveRepairJournal(source: XCTUnwrap(report.source), layout: XCTUnwrap(report.proposed))
            XCTAssertEqual(journal.entries.map { $0.old.count }, [64])
            var legacy = Data("NUPFIX01".utf8)
            legacy.append(try journal.data.bytes(8, 304))
            for e in journal.entries { legacy.appendLE(UInt64(e.offset), width: 8); legacy.append(e.old); legacy.append(e.new) }
            legacy.append(legacy.sha256)
            XCTAssertEqual(try ArchiveRepairJournal(data: legacy).data, legacy)
            try journal.prepare(url: healthy.url)
            try legacy.write(to: ArchiveRepairJournal.journals(for: healthy.url).pending)
            let output = try regularFile(healthy.url, writable: true)
            try journal.writeRecords(to: output); try journal.writeHeader(to: output); try output.close()
            if committed { try ArchiveRepairJournal.markCommitted(url: healthy.url) }
            if committed { try NUPArchive(url: healthy.url).verify(deep: true, context: JobContext()) }
            else { XCTAssertThrowsError(try NUPArchive(url: healthy.url)); XCTAssertEqual(try Data(contentsOf: healthy.url), original) }
            absentROMFSJournal(healthy.url)
        }
    }

    func testROMFSSparseFourGiBRepairDoesNotCopyPayloads() throws {
        let healthy = try brokenROMFS(), output = try regularFile(healthy.url, writable: true)
        let size: UInt64 = 4 * 1024 * 1024 * 1024
        var header = try readRange(output, offset: 0, count: 128); header.put(size, at: 64, width: 8)
        try output.truncate(atOffset: size); try output.seek(toOffset: 0); try output.write(contentsOf: header)
        try output.seek(toOffset: size - 1); try output.write(contentsOf: Data([91])); try output.close()
        let report = try ArchiveDiagnosis.inspect(healthy.url), source = try XCTUnwrap(report.source)
        let result = try ArchiveRepair.apply(report)
        XCTAssertEqual(result.fileSize, size); XCTAssertEqual(result.revision.inode, source.revision.inode)
        let input = try regularFile(healthy.url); defer { try? input.close() }
        XCTAssertEqual(try readRange(input, offset: size - 1, count: 1), Data([91]))
        var info = stat(); XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertLessThan(info.st_blocks * 512, 2 * 1024 * 1024)
        try result.verify(deep: true, context: JobContext())
    }

    @MainActor func testFailedROMFSOpenOffersPreviewAndRepairRefreshesWorkspace() async throws {
        let healthy = try brokenROMFS(), before = try Data(contentsOf: healthy.url)
        let suite = "ROMFSStore-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("ROMFS-Auftrag nicht beendet") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(healthy.url); try await finish()
        let report = try XCTUnwrap(store.repairReport)
        XCTAssertNil(store.error); XCTAssertTrue(report.canRepair); XCTAssertEqual(report.romfs.first?.count, 14)
        XCTAssertEqual(try Data(contentsOf: healthy.url), before)
        store.repair(report); try await finish()
        XCTAssertNil(store.repairReport); XCTAssertNil(store.repairError)
        XCTAssertEqual(store.archive?.directories.map(\.children), healthy.directories.map(\.children))
    }
}
