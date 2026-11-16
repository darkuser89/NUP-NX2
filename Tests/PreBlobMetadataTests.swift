import XCTest
@testable import NUPStudio

extension NUPCoreTests {
    private func preBlobFixture() throws -> NUPArchive {
        let prefix = "preblob-\(UUID().uuidString)"
        var npdm = Data(count: 192)
        npdm.put(Data("META".utf8), at: 0); npdm.put(128, at: 0x70, width: 4); npdm.put(64, at: 0x74, width: 4)
        npdm.put(Data("ACI0".utf8), at: 128); npdm.put(0x0400486024DEC000, at: 144, width: 8)
        for folder in ["base", "updates/131072"] {
            try write(prefix + "/dump/" + folder + "/exefs/main.npdm", npdm)
            try write(prefix + "/dump/" + folder + "/romfs/data.bin", Data(repeating: 41, count: 16000))
        }
        var options = PackOptions(); options.name = "Pre-Blob-Test"; options.displayVersion = "1.0.0"
        let url = root.appendingPathComponent(prefix + ".nup")
        try NUPWriter.pack(source: root.appendingPathComponent(prefix + "/dump"), destination: url, options: options, context: JobContext())
        let original = try NUPArchive(url: url), bytes = try Data(contentsOf: url)
        var toc = original.toc, prefixData = Data()
        for package in original.packages {
            prefixData.append(Data(count: Int(try aligned(UInt64(prefixData.count))) - prefixData.count))
            toc.put(original.blobOffset + UInt64(prefixData.count), at: 48 + package.id * 64 + 32, width: 8)
            prefixData.append(try bytes.bytes(integer(package.metaOffset), package.metaSize))
        }
        prefixData.append(Data(count: Int(try aligned(UInt64(prefixData.count))) - prefixData.count))
        let files = 48 + original.packages.count * 64 + original.directories.count * 24
        for index in original.files.indices where original.files[index].storedSize > 0 {
            toc.put(original.files[index].offset + UInt64(prefixData.count), at: files + index * 80 + 16, width: 8)
        }
        var header = original.header
        header.put(original.blobOffset + UInt64(prefixData.count), at: 56, width: 8)
        header.put(original.fileSize + UInt64(prefixData.count), at: 64, width: 8); header.put(toc.sha256, at: 24)
        var result = header; result.append(toc)
        result.append(Data(count: Int(original.blobOffset) - result.count)); result.append(prefixData)
        result.append(bytes.suffix(from: Int(original.blobOffset)))
        try result.write(to: url)
        return try NUPArchive(url: url)
    }

    func testPreBlobMetadataOpensInLibraryAndDiagnosisWithoutRewriting() throws {
        let archive = try preBlobFixture(), before = try Data(contentsOf: archive.url)
        XCTAssertTrue(archive.packages.allSatisfy { $0.metaOffset < archive.blobOffset })
        XCTAssertEqual(archive.packages[0].text(5, profile: .specification), "Pre-Blob-Test")
        XCTAssertEqual(try LibraryMetadataReader.read(archive.url, context: JobContext()).item.title, "Pre-Blob-Test")
        let report = try ArchiveDiagnosis.inspect(archive.url)
        XCTAssertTrue(report.blockers.isEmpty, "\(report.blockers)"); XCTAssertFalse(report.canRepair)
        try archive.verify(deep: true, context: JobContext())
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
    }

    func testPreBlobMetadataCanBeEditedDirectlyWithoutMovingFileExtents() throws {
        let archive = try preBlobFixture(), input = try regularFile(archive.url)
        let oldPrefix = try readRange(input, offset: archive.packages[0].metaOffset,
                                     count: integer(archive.blobOffset - archive.packages[0].metaOffset))
        try input.close()
        var metadata = archive.packages[0].metadata; metadata[5] = Data("Changed locally".utf8)
        try MetadataTransaction.update(archive: archive, package: 0, metadata: metadata, context: JobContext())
        let updated = try NUPArchive(url: archive.url)
        XCTAssertEqual(updated.revision.inode, archive.revision.inode)
        XCTAssertEqual(updated.blobOffset, archive.blobOffset)
        XCTAssertEqual(updated.files.map(\.offset), archive.files.map(\.offset))
        XCTAssertEqual(updated.packages[1].metaOffset, archive.packages[1].metaOffset)
        XCTAssertGreaterThanOrEqual(updated.packages[0].metaOffset, archive.fileSize)
        XCTAssertEqual(updated.packages[0].text(5, profile: .specification), "Changed locally")
        let output = try regularFile(archive.url); defer { try? output.close() }
        XCTAssertEqual(try readRange(output, offset: archive.packages[0].metaOffset, count: oldPrefix.count), oldPrefix)
        try updated.verify(deep: true, context: JobContext())
    }

    func testPreBlobMetadataSaveAsPreservesOriginalAndFileHashes() throws {
        let archive = try preBlobFixture(), original = try Data(contentsOf: archive.url)
        let destination = root.appendingPathComponent("saved-as.nup")
        try archive.saveMetadata(package: 0, changes: MetadataEdit(name: "Saved as", publisher: "", displayVersion: "1", icon: nil),
            profile: .specification, destination: destination, context: JobContext())
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let copy = try NUPArchive(url: destination)
        XCTAssertEqual(copy.files.map(\.hash), archive.files.map(\.hash))
        XCTAssertEqual(copy.packages[0].text(5, profile: .specification), "Saved as")
        try copy.verify(deep: true, context: JobContext())
    }

    func testPreBlobMetadataSurvivesGrowingTOCAndFileEditRollback() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let archive = try preBlobFixture(), original = try Data(contentsOf: archive.url)
        let additions = try (0..<12).map { try write(String(repeating: "x", count: 180) + String($0) + ".bin", Data([UInt8($0)])) }
        let directory = try XCTUnwrap(archive.packages[0].romfs), box = Box()
        box.context = JobContext { _, message in if message.text(in: L10n.language) == L10n.text("Prüfe geänderten Container …") { box.context?.cancel() } }
        XCTAssertThrowsError(try archive.editFiles(package: 0, directory: directory, adding: additions, context: box.context!))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let reopened = try NUPArchive(url: archive.url)
        let updated = try reopened.editFiles(package: 0, directory: directory, adding: additions)
        XCTAssertEqual(updated.packages.map(\.metadata), archive.packages.map(\.metadata))
        XCTAssertEqual(updated.files.count, archive.files.count + additions.count)
        try updated.verify(deep: true, context: JobContext())
    }

    func testInterruptedPreBlobMetadataEditsRestoreOriginalLayout() throws {
        for committed in [false, true] {
            let archive = try preBlobFixture(), original = try Data(contentsOf: archive.url)
            let file = try regularFile(archive.url, writable: true)
            var metadata = archive.packages[0].metadata; metadata[5] = Data("Journal title".utf8)
            let transaction = try MetadataTransaction(archive: archive, package: 0, metadata: metadata, input: file)
            try transaction.prepare(url: archive.url); try transaction.writePayload(to: file)
            try transaction.writeRecord(to: file); try transaction.writeHeader(to: file)
            if committed { try transaction.markCommitted(url: archive.url) }
            try file.close()
            let reopened = try NUPArchive(url: archive.url)
            if committed { XCTAssertEqual(reopened.packages[0].text(5, profile: .specification), "Journal title") }
            else { XCTAssertEqual(try Data(contentsOf: archive.url), original) }
            try reopened.verify(deep: true, context: JobContext())
        }
    }

    func testPreBlobMetadataDoesNotPermitActualTOCOrPayloadOverlap() throws {
        let archive = try preBlobFixture()
        for offset in [try archive.header.uint(8, 8), archive.files[0].offset, archive.fileSize] {
            let url = try mutate(archive) { $0.put(offset, at: 48 + 32, width: 8) }
            XCTAssertThrowsError(try NUPArchive(url: url))
        }
    }

    func testMetadataAtEOFBeforeEmptyBlobIsAppendedInsteadOfShrinkingPastBlob() throws {
        var package = NUPPackage(id: 0); package.titleID = 0x0400486024DEC000
        let meta = try MetadataCodec.serialize([5: Data("12345678".utf8)])
        XCTAssertEqual(meta.count, 16)
        var toc = Data(count: 136); toc.put(Data([84,79,67,1]), at: 0)
        toc.put(1, at: 4, width: 4); toc.put(1, at: 8, width: 8); toc.put(136, at: 24, width: 8)
        toc.put(package.titleID, at: 48, width: 8)
        toc.put(UInt64(UInt32.max), at: 48 + 12, width: 4); toc.put(UInt64(UInt32.max), at: 48 + 16, width: 4)
        toc.put(272, at: 48 + 32, width: 8); toc.put(UInt64(meta.count), at: 48 + 40, width: 4)
        var header = Data(count: 128); header.put(Data([78,85,80,1]), at: 0); header.put(128, at: 4, width: 2)
        header.put(1, at: 6, width: 2); header.put(128, at: 8, width: 8); header.put(136, at: 16, width: 8)
        header.put(toc.sha256, at: 24); header.put(288, at: 56, width: 8); header.put(288, at: 64, width: 8)
        header.put(1, at: 72, width: 4); header.put(try ArchiveDiagnosis.uuid(toc: toc), at: 80)
        var bytes = header; bytes.append(toc); bytes.append(Data(count: 8)); bytes.append(meta)
        let url = try write("empty-blob.nup", bytes), archive = try NUPArchive(url: url)
        try MetadataTransaction.update(archive: archive, package: 0, metadata: [5: Data("X".utf8)], context: JobContext())
        let updated = try NUPArchive(url: url)
        XCTAssertEqual(updated.packages[0].metaOffset, 288); XCTAssertEqual(updated.blobOffset, 288)
        XCTAssertEqual(updated.packages[0].text(5, profile: .specification), "X")
        try updated.verify(deep: true, context: JobContext())
    }
}
