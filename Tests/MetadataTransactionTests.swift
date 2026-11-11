import XCTest
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    private func transaction(_ archive: NUPArchive, package: Int, name: String = String(repeating: "N", count: 2000)) throws -> MetadataTransaction {
        var metadata = archive.packages[package].metadata
        metadata[MetadataProfile.specification.type(5)] = Data(name.utf8)
        let input = try regularFile(archive.url)
        defer { try? input.close() }
        return try MetadataTransaction(archive: archive, package: package, metadata: metadata, input: input)
    }

    func testInterruptedMetadataWritesRecoverOriginalAtEveryStage() throws {
        let source = try fixture()
        for package in [0, 2] {
            for stage in 0...3 {
                let target = root.appendingPathComponent("interrupted-\(package)-\(stage).nup")
                try NUPWriter.pack(source: source, destination: target, options: PackOptions(), context: JobContext())
                let archive = try NUPArchive(url: target)
                let original = try Data(contentsOf: target)
                let transaction = try transaction(archive, package: package)
                try transaction.prepare(url: target)
                let output = try regularFile(target, writable: true)
                if stage >= 1 { try transaction.writePayload(to: output) }
                if stage >= 2 { try transaction.writeRecord(to: output) }
                if stage >= 3 { try transaction.writeHeader(to: output) }
                try output.close()
                // Opening after the simulated process exit must undo all writes.
                let recovered = try NUPArchive(url: target)
                XCTAssertEqual(try Data(contentsOf: target), original, "package \(package), stage \(stage)")
                XCTAssertEqual(recovered.revision.inode, archive.revision.inode)
                XCTAssertFalse(fm.fileExists(atPath: MetadataTransaction.journals(for: target).pending.path))
                try recovered.verify(deep: true, context: JobContext())
            }
        }
    }

    func testPartialMetadataHeaderAndRecordWritesRecover() throws {
        let source = try fixture()
        for phase in ["payload", "record", "header"] {
            let target = root.appendingPathComponent("partial-\(phase).nup")
            try NUPWriter.pack(source: source, destination: target, options: PackOptions(), context: JobContext())
            let archive = try NUPArchive(url: target)
            let original = try Data(contentsOf: target)
            let transaction = try transaction(archive, package: 2)
            try transaction.prepare(url: target)
            let output = try regularFile(target, writable: true)
            if phase == "payload" {
                try output.seek(toOffset: transaction.writeOffset)
                try output.write(contentsOf: transaction.newBlock.prefix(15))
                try output.synchronize()
            } else {
                try transaction.writePayload(to: output)
                try output.seek(toOffset: transaction.recordOffset)
                if phase == "record" {
                    try output.write(contentsOf: transaction.newRecord.prefix(36))
                } else {
                    try transaction.writeRecord(to: output)
                    try output.seek(toOffset: 0)
                    try output.write(contentsOf: transaction.newHeader.prefix(41))
                }
                try output.synchronize()
            }
            try output.close()
            _ = try NUPArchive(url: target)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testCommittedJournalPreservesCompletedEditAfterReopening() throws {
        let archive = try packed()
        let transaction = try transaction(archive, package: 0, name: "Committed")
        try transaction.prepare(url: archive.url)
        let output = try regularFile(archive.url, writable: true)
        try transaction.writePayload(to: output)
        try transaction.writeRecord(to: output)
        try transaction.writeHeader(to: output)
        try transaction.markCommitted(url: archive.url)
        try output.close()
        let reopened = try NUPArchive(url: archive.url)
        XCTAssertEqual(reopened.packages[0].text(5, profile: .specification), "Committed")
        XCTAssertFalse(fm.fileExists(atPath: MetadataTransaction.journals(for: archive.url).committed.path))
        try reopened.verify(deep: true, context: JobContext())
    }

    func testRepeatedMetadataEditsReuseTailAndCanShrink() throws {
        var archive = try packed()
        let inode = archive.revision.inode
        var changes = MetadataEdit(name: "Stable title 0", publisher: "Publisher", displayVersion: "1", icon: nil)
        try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                 destination: archive.url, replacingOriginal: true, context: JobContext())
        archive = try NUPArchive(url: archive.url)
        let sizeAfterFirstEdit = archive.fileSize
        let metadataOffset = archive.packages[0].metaOffset
        for index in 1...4 {
            changes.name = "Stable title \(index)"
            try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                     destination: archive.url, replacingOriginal: true, context: JobContext())
            archive = try NUPArchive(url: archive.url)
            XCTAssertEqual(archive.fileSize, sizeAfterFirstEdit)
            XCTAssertEqual(archive.packages[0].metaOffset, metadataOffset)
            XCTAssertEqual(archive.revision.inode, inode)
        }
        let unchangedRevision = archive.revision
        try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                 destination: archive.url, replacingOriginal: true, context: JobContext())
        XCTAssertEqual(try NUPArchive(url: archive.url).revision, unchangedRevision)
        let shorter = MetadataEdit(name: "X", publisher: "", displayVersion: "", icon: nil)
        try archive.saveMetadata(package: 0, changes: shorter, profile: .specification,
                                 destination: archive.url, replacingOriginal: true, context: JobContext())
        let shrunk = try NUPArchive(url: archive.url)
        XCTAssertLessThan(shrunk.fileSize, sizeAfterFirstEdit)
        XCTAssertEqual(shrunk.packages[0].metaOffset, metadataOffset)
        try shrunk.verify(deep: true, context: JobContext())
    }

    func testRemovingLastMetadataBlockAndRecoveringAnInterruptedRemoval() throws {
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let input = try regularFile(archive.url)
        let transaction = try MetadataTransaction(archive: archive, package: 2, metadata: [:], input: input)
        try input.close()
        try transaction.prepare(url: archive.url)
        let output = try regularFile(archive.url, writable: true)
        try transaction.writePayload(to: output)
        try transaction.writeRecord(to: output)
        try transaction.writeHeader(to: output)
        try output.close()
        _ = try NUPArchive(url: archive.url)
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let current = try NUPArchive(url: archive.url)
        try MetadataTransaction.update(archive: current, package: 2, metadata: [:], context: JobContext())
        let cleared = try NUPArchive(url: archive.url)
        XCTAssertEqual(cleared.packages[2].metaOffset, 0)
        XCTAssertEqual(cleared.packages[2].metaSize, 0)
        try cleared.verify(deep: true, context: JobContext())
    }

    func testCorruptJournalAndWrongFileIdentityAreRejectedWithoutWriting() throws {
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let transaction = try transaction(archive, package: 0)
        try transaction.prepare(url: archive.url)
        let path = MetadataTransaction.journals(for: archive.url).pending
        var corrupt = try Data(contentsOf: path); corrupt[90] ^= 1
        try corrupt.write(to: path)
        XCTAssertThrowsError(try NUPArchive(url: archive.url))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        try transaction.journalData.write(to: path)
        try original.write(to: archive.url, options: .atomic)
        XCTAssertThrowsError(try NUPArchive(url: archive.url))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }

    func testMetadataLockPreventsSecondWriterAndRecovery() throws {
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let locked = try regularFile(archive.url, writable: true)
        defer { try? locked.close() }
        XCTAssertEqual(flock(locked.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        let changes = MetadataEdit(name: "Locked", publisher: "", displayVersion: "", icon: nil)
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: archive.url, replacingOriginal: true, context: JobContext()))
        let transaction = try transaction(archive, package: 0)
        try transaction.prepare(url: archive.url)
        XCTAssertThrowsError(try NUPArchive(url: archive.url))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        XCTAssertEqual(flock(locked.fileDescriptor, LOCK_UN), 0)
        _ = try NUPArchive(url: archive.url)
    }

    func testMetadataOnlyUpdateOnFourGiBSparseContainer() throws {
        try write("sparse/romfs/a", Data("sentinel".utf8))
        let target = root.appendingPathComponent("sparse.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("sparse"), destination: target, options: PackOptions(), context: JobContext())
        let small = try NUPArchive(url: target)
        let metadata = try MetadataCodec.serialize(small.packages[0].metadata)
        var toc = small.toc
        let filePosition = 48 + small.packages.count * 64 + small.directories.count * 24
        let extent = small.files[0].offset
        let payloadSize: UInt64 = 4 * 1024 * 1024 * 1024
        let metadataOffset = extent + payloadSize
        toc.put(payloadSize, at: filePosition + 8, width: 8)
        toc.put(payloadSize, at: filePosition + 24, width: 8)
        toc.put(0, at: filePosition + 64, width: 1)
        toc.put(metadataOffset, at: 48 + 32, width: 8)
        var header = small.header
        header.put(metadataOffset + UInt64(metadata.count), at: 64, width: 8)
        header.put(toc.sha256, at: 24)
        let output = try regularFile(target, writable: true)
        try output.truncate(atOffset: metadataOffset + UInt64(metadata.count))
        try output.seek(toOffset: metadataOffset); try output.write(contentsOf: metadata)
        try output.seek(toOffset: 128); try output.write(contentsOf: toc)
        try output.seek(toOffset: 0); try output.write(contentsOf: header)
        try output.close()
        // Structure-only fixture: payload hash is deliberately not recomputed.
        let archive = try NUPArchive(url: target)
        let plan = try transaction(archive, package: 0, name: "Sparse edit")
        XCTAssertLessThan(plan.journalData.count, 16 * 1024)
        let changes = MetadataEdit(name: "Sparse edit", publisher: "", displayVersion: "", icon: nil)
        try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                 destination: target, replacingOriginal: true, context: JobContext())
        let edited = try NUPArchive(url: target)
        XCTAssertEqual(edited.revision.inode, archive.revision.inode)
        XCTAssertEqual(edited.files[0].offset, extent)
        XCTAssertEqual(edited.files[0].size, payloadSize)
        XCTAssertEqual(edited.packages[0].text(5, profile: .specification), "Sparse edit")
        let input = try regularFile(target)
        defer { try? input.close() }
        XCTAssertEqual(try readRange(input, offset: extent, count: 8), Data("sentinel".utf8))
        let usage = try fm.attributesOfItem(atPath: target.path)
        XCTAssertGreaterThan((usage[.size] as? NSNumber)?.uint64Value ?? 0, payloadSize)
        XCTAssertFalse(fm.fileExists(atPath: MetadataTransaction.journals(for: target).pending.path))
    }
}
