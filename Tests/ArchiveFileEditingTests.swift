import XCTest
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    private func noFileJournal(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let paths = ArchiveContentJournal.journals(for: url)
        XCTAssertFalse(fm.fileExists(atPath: paths.pending.path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: paths.committed.path), file: file, line: line)
        let children = (try? fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(children.contains { $0.hasPrefix(".nup-stage-") }, file: file, line: line)
    }

    func testAddFilesRetainsStoredBytesMetadataIdentityAndDeduplication() throws {
        var archive = try packed()
        var metadata = archive.packages[0].metadata
        metadata[65000] = Data([1,2,3]); metadata[9] = Data([255])
        try MetadataTransaction.update(archive: archive, package: 0, metadata: metadata, context: JobContext())
        archive = try NUPArchive(url: archive.url)
        let input = try regularFile(archive.url)
        let originalBytes = try archive.files.map { try readRange(input, offset: $0.offset, count: Int($0.storedSize)) }
        try input.close()
        let sources = [try write("incoming/new.bin", Data(repeating: 77, count: 2 * 1024 * 1024)),
                       try write("incoming/tiny.txt", Data("abc".utf8)), try write("incoming/added-empty", Data())]
        let directory = try XCTUnwrap(archive.packages[0].romfs)
        let updated = try archive.editFiles(package: 0, directory: directory, adding: sources)
        XCTAssertEqual(updated.revision.inode, archive.revision.inode)
        XCTAssertEqual(updated.revision.permissions, archive.revision.permissions)
        XCTAssertEqual(updated.uuid, archive.uuid)
        XCTAssertEqual(updated.packages.map(\.metadata), archive.packages.map(\.metadata))
        XCTAssertEqual(updated.files.count, archive.files.count + 3)
        let current = try regularFile(updated.url)
        defer { try? current.close() }
        for index in archive.files.indices {
            let a = archive.files[index], b = updated.files[index]
            XCTAssertEqual(a.hash, b.hash); XCTAssertEqual(a.codec, b.codec); XCTAssertEqual(a.storedSize, b.storedSize)
            XCTAssertEqual(try readRange(current, offset: b.offset, count: Int(b.storedSize)), originalBytes[index])
        }
        XCTAssertEqual(updated.files.first { $0.name == "large.bin" }?.offset, updated.files.first { $0.name == "duplicate.bin" }?.offset)
        XCTAssertEqual(updated.files.first { $0.name == "new.bin" }?.codec, 1)
        XCTAssertEqual(updated.files.first { $0.name == "tiny.txt" }?.codec, 0)
        XCTAssertEqual(updated.files.first { $0.name == "added-empty" }?.offset, 0)
        XCTAssertTrue(zip(archive.files, updated.files).contains { $0.offset != $1.offset })
        try updated.verify(deep: true, context: JobContext())
        noFileJournal(updated.url)
    }

    func testRemoveSharedFileAndEmptyUpdatePreserveOtherPackages() throws {
        let archive = try packed(), directory = archive.packages[0].root
        let removed = try XCTUnwrap(archive.files.firstIndex { $0.name == "duplicate.bin" })
        let large = try XCTUnwrap(archive.files.first { $0.name == "large.bin" })
        let first = try archive.editFiles(package: 0, directory: directory, removing: [removed])
        XCTAssertFalse(first.files.contains { $0.name == "duplicate.bin" })
        XCTAssertEqual(first.files.first { $0.name == "large.bin" }?.offset, large.offset)
        XCTAssertEqual(first.fileSize, archive.fileSize)
        let update = try XCTUnwrap(first.files.firstIndex { $0.name == "update" })
        let second = try first.editFiles(package: 1, directory: first.packages[1].root, removing: [update])
        XCTAssertNotNil(second.packages[1].romfs)
        XCTAssertFalse(second.files.contains { $0.name == "update" })
        XCTAssertTrue(second.files.contains { $0.name == "dlc" })
        XCTAssertEqual(second.fileSize, archive.fileSize)
        XCTAssertEqual(second.uuid, archive.uuid)
        try second.verify(deep: true, context: JobContext()); noFileJournal(second.url)
    }

    func testAddAndRemoveSameNameInOneTransaction() throws {
        let archive = try packed(), removed = try XCTUnwrap(archive.files.firstIndex { $0.name == "raw.bin" })
        let source = try write("incoming/raw.bin", Data("replacement".utf8))
        let updated = try archive.editFiles(package: 0, directory: XCTUnwrap(archive.packages[0].romfs),
                                           adding: [source], removing: [removed])
        XCTAssertEqual(updated.files.count, archive.files.count)
        let file = try XCTUnwrap(updated.files.first { $0.name == "raw.bin" }), input = try regularFile(updated.url)
        defer { try? input.close() }
        var data = Data(); try StreamCodec.consume(file, input: input, context: JobContext()) { data.append($0) }
        XCTAssertEqual(data, Data("replacement".utf8)); try updated.verify(deep: true, context: JobContext())
    }

    func testInvalidFileEditsDoNotTouchOriginal() throws {
        var archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let romfs = try XCTUnwrap(archive.packages[0].romfs)
        let collision = try write("incoming/RAW.bin"), duplicate = try write("incoming/other/RAW.bin")
        let unsafe = try write("incoming/a\\b"), link = root.appendingPathComponent("source-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: collision)
        let selfLink = root.appendingPathComponent("self.nup"); try fm.linkItem(at: archive.url, to: selfLink)
        archive = try NUPArchive(url: archive.url)
        let other = try XCTUnwrap(archive.files.firstIndex { $0.name == "dlc" })
        let attempts: [() throws -> NUPArchive] = [
            { try archive.editFiles(package: 0, directory: romfs, adding: [collision]) },
            { try archive.editFiles(package: 0, directory: romfs, adding: [collision, duplicate]) },
            { try archive.editFiles(package: 0, directory: romfs, adding: [unsafe]) },
            { try archive.editFiles(package: 0, directory: romfs, adding: [link]) },
            { try archive.editFiles(package: 0, directory: romfs, adding: [selfLink]) },
            { try archive.editFiles(package: 0, directory: archive.packages[2].root, adding: [collision]) },
            { try archive.editFiles(package: 0, directory: romfs, removing: [other]) },
            { try archive.editFiles(package: 0, directory: romfs, removing: [99999]) }
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt()); XCTAssertEqual(try Data(contentsOf: archive.url), original)
            noFileJournal(archive.url)
        }
    }

    func testStaleFileEditAndCancelledPreparationLeaveOriginalUntouched() throws {
        let archive = try packed(), source = try write("incoming/add.txt")
        let original = try Data(contentsOf: archive.url), context = JobContext(); context.cancel()
        XCTAssertThrowsError(try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: [source], context: context))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let output = try regularFile(archive.url, writable: true)
        try output.seekToEnd(); try output.write(contentsOf: Data([7])); try output.close()
        let external = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: [source]))
        XCTAssertEqual(try Data(contentsOf: archive.url), external); noFileJournal(archive.url)
    }

    func testCancellationAfterAppendAndHeaderRestoresExactOriginal() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        var archive = try packed()
        let original = try Data(contentsOf: archive.url), source = try write("incoming/add.txt", Data(repeating: 90, count: 1048576))
        for message in ["Aktualisiere Dateiverzeichnis", "Prüfe geänderten Container"] {
            let box = Box()
            box.context = JobContext { _, phase in if phase.hasPrefix(message) { box.context?.cancel() } }
            XCTAssertThrowsError(try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: [source], context: box.context!)) { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertEqual(try Data(contentsOf: archive.url), original)
            noFileJournal(archive.url)
            archive = try NUPArchive(url: archive.url)
            try archive.verify(deep: true, context: JobContext())
        }
    }

    func testInterruptedFileEditsRecoverAtEveryWriteStageAndCommittedEditsStay() throws {
        var archive = try packed()
        let original = try Data(contentsOf: archive.url), source = try write("incoming/interrupted.txt")
        for phase in 0...6 {
            let stage = try ArchiveFileStage(archive: archive, urls: [source], context: JobContext())
            let plan = try ArchiveFilePlan(archive: archive, package: 0, directory: archive.packages[0].root,
                                          additions: stage.files, stageSize: stage.size, removing: [])
            let journal = ArchiveContentJournal(archive: archive, plan: plan), input = try regularFile(archive.url)
            try journal.prepare(url: archive.url, file: input)
            let output = try regularFile(archive.url, writable: true)
            if phase >= 1 { _ = try plan.appendPayloads(input: input, output: output, stage: stage.handle, context: JobContext()) }
            if phase == 2 {
                try output.seek(toOffset: plan.header.uint(8, 8)); try output.write(contentsOf: plan.toc.prefix(51))
            } else if phase >= 3 { try plan.writeTOC(to: output) }
            if phase == 4 { try output.seek(toOffset: 0); try output.write(contentsOf: plan.header.prefix(41)) }
            else if phase >= 5 { try plan.writeHeader(to: output) }
            if phase == 6 { try ArchiveContentJournal.markCommitted(url: archive.url) }
            try input.close(); try output.close()
            let recovered = try NUPArchive(url: archive.url)
            if phase < 6 { XCTAssertEqual(try Data(contentsOf: archive.url), original, "phase \(phase)") }
            else { XCTAssertTrue(recovered.files.contains { $0.name == "interrupted.txt" }) }
            XCTAssertEqual(recovered.revision.inode, archive.revision.inode)
            try recovered.verify(deep: true, context: JobContext()); noFileJournal(archive.url)
            archive = recovered
        }
    }

    func testCorruptOrForeignFileJournalIsRefusedWithoutRecoveryWrites() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        let plan = try ArchiveFilePlan(archive: archive, package: 0, directory: archive.packages[0].root,
                                      additions: [], stageSize: 0, removing: [0])
        let journal = ArchiveContentJournal(archive: archive, plan: plan), input = try regularFile(archive.url)
        defer { try? input.close() }
        try journal.prepare(url: archive.url, file: input)
        let path = ArchiveContentJournal.journals(for: archive.url).pending
        let bytes = try Data(contentsOf: path)
        var corrupt = bytes; corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: path)
        XCTAssertThrowsError(try NUPArchive(url: archive.url)); XCTAssertEqual(try Data(contentsOf: archive.url), original)
        try bytes.write(to: path)
        let foreign = root.appendingPathComponent("foreign.nup"); try original.write(to: foreign)
        try bytes.write(to: ArchiveContentJournal.journals(for: foreign).pending)
        XCTAssertThrowsError(try NUPArchive(url: foreign)); XCTAssertEqual(try Data(contentsOf: foreign), original)
        try fm.removeItem(at: path)
    }

    func testExternalPrefixChangeAndLockAreNotOverwritten() throws {
        let archive = try packed()
        let output = try regularFile(archive.url, writable: true)
        try MetadataTransaction.lock(output)
        XCTAssertThrowsError(try archive.editFiles(package: 0, directory: archive.packages[0].root, removing: [0]))
        try output.close()
        let plan = try ArchiveFilePlan(archive: archive, package: 0, directory: archive.packages[0].root,
                                      additions: [], stageSize: 0, removing: [0])
        let input = try regularFile(archive.url)
        try ArchiveContentJournal(archive: archive, plan: plan).prepare(url: archive.url, file: input)
        try input.close()
        let changed = try regularFile(archive.url, writable: true)
        try changed.seek(toOffset: 96); try changed.write(contentsOf: Data([77])); try changed.close()
        let external = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try NUPArchive(url: archive.url)); XCTAssertEqual(try Data(contentsOf: archive.url), external)
    }

    func testFileEditCanGrowTOCPastTinyOriginalAndHandleEmptyFiles() throws {
        let source = root.appendingPathComponent("minimal/romfs")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("original-empty"))
        let target = root.appendingPathComponent("minimal.nup")
        try NUPWriter.pack(source: source.deletingLastPathComponent(), destination: target, options: PackOptions(), context: JobContext())
        let archive = try NUPArchive(url: target)
        let additions = try (0..<30).map { try write("empty/long-empty-name-\($0).bin", Data()) }
        let updated = try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: additions, removing: [0])
        XCTAssertEqual(updated.files.count, 30); XCTAssertGreaterThan(updated.blobOffset, archive.fileSize)
        XCTAssertTrue(updated.files.allSatisfy { $0.size == 0 && $0.offset == 0 })
        try updated.verify(deep: true, context: JobContext()); noFileJournal(target)
    }

    func testFileChangesKeepMetadataEditorUsable() throws {
        let archive = try packed(), source = try write("incoming/add.txt")
        let updated = try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: [source])
        let edit = MetadataEdit(name: "After file edit", publisher: "Local", displayVersion: "1", icon: nil)
        try updated.saveMetadata(package: 0, changes: edit, profile: .specification, destination: updated.url, replacingOriginal: true, context: JobContext())
        let final = try NUPArchive(url: archive.url)
        XCTAssertEqual(final.packages[0].text(5, profile: .specification), "After file edit")
        XCTAssertTrue(final.files.contains { $0.name == "add.txt" }); try final.verify(deep: true, context: JobContext())
    }

    func testContentAndMetadataTransactionsCannotOverlapAndReadOnlyDoesNotRecover() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        let plan = try ArchiveFilePlan(archive: archive, package: 0, directory: archive.packages[0].root,
                                      additions: [], stageSize: 0, removing: [0])
        let input = try regularFile(archive.url)
        try ArchiveContentJournal(archive: archive, plan: plan).prepare(url: archive.url, file: input)
        var metadata = archive.packages[0].metadata; metadata[5] = Data("blocked".utf8)
        XCTAssertThrowsError(try MetadataTransaction.update(archive: archive, package: 0, metadata: metadata, context: JobContext()))
        _ = try NUPArchive(url: archive.url, recoverPendingMetadata: false)
        XCTAssertTrue(fm.fileExists(atPath: ArchiveContentJournal.journals(for: archive.url).pending.path))
        let transaction = try MetadataTransaction(archive: archive, package: 0, metadata: metadata, input: input)
        try transaction.prepare(url: archive.url)
        XCTAssertThrowsError(try NUPArchive(url: archive.url))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        try fm.removeItem(at: MetadataTransaction.journals(for: archive.url).pending)
        try input.close()
        _ = try NUPArchive(url: archive.url)
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        noFileJournal(archive.url)
    }

    @MainActor func testFileEditingStoreRefreshesSelectedPackageAndLibrarySize() async throws {
        let initial = try packed(), source = try write("incoming/store-add.txt")
        let suite = "FileEditingStore-\(UUID().uuidString)", preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: preferences)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(5)
            while store.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(store.busy); XCTAssertNil(store.error)
        }
        store.scanLibrary(root); try await finish()
        let libraryURL = try XCTUnwrap(store.library?.entries.first { $0.name == initial.url.lastPathComponent }?.url)
        store.open(libraryURL); try await finish()
        store.packageIndex = 1
        store.editFiles(directory: try XCTUnwrap(store.archive?.packages[1].romfs), adding: [source])
        try await finish()
        let added = try XCTUnwrap(store.archive)
        XCTAssertEqual(store.packageIndex, 1)
        XCTAssertTrue(added.files.contains { $0.name == "store-add.txt" })
        XCTAssertEqual(store.library?.entries.first { $0.name == initial.url.lastPathComponent }?.size, Int64(added.fileSize))
        let index = try XCTUnwrap(added.files.firstIndex { $0.name == "store-add.txt" })
        store.editFiles(directory: added.packages[1].root, removing: [index]); try await finish()
        XCTAssertFalse(store.archive!.files.contains { $0.name == "store-add.txt" })
        XCTAssertEqual(store.packageIndex, 1)
        try store.archive!.verify(deep: true, context: JobContext())
        store.libraryMetadata.cancel()
    }

    func testAddToFourGiBSparseContainerKeepsUntouchedExtentAndLowAllocation() throws {
        try write("sparse/romfs/a", Data("sentinel".utf8))
        let target = root.appendingPathComponent("sparse-files.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("sparse"), destination: target, options: PackOptions(), context: JobContext())
        let small = try NUPArchive(url: target), metadata = try MetadataCodec.serialize(small.packages[0].metadata)
        var toc = small.toc, header = small.header
        let position = 48 + small.packages.count * 64 + small.directories.count * 24
        let extent: UInt64 = 1048576, size: UInt64 = 4 * 1024 * 1024 * 1024, meta = extent + size
        toc.put(size, at: position + 8, width: 8); toc.put(extent, at: position + 16, width: 8)
        toc.put(size, at: position + 24, width: 8); toc.put(0, at: position + 64, width: 1)
        toc.put(meta, at: 48 + 32, width: 8)
        header.put(meta + UInt64(metadata.count), at: 64, width: 8); header.put(toc.sha256, at: 24)
        let output = try regularFile(target, writable: true)
        try output.truncate(atOffset: meta + UInt64(metadata.count))
        try output.seek(toOffset: extent); try output.write(contentsOf: Data("sentinel".utf8))
        try output.seek(toOffset: meta); try output.write(contentsOf: metadata)
        try output.seek(toOffset: 128); try output.write(contentsOf: toc)
        try output.seek(toOffset: 0); try output.write(contentsOf: header); try output.close()
        let archive = try NUPArchive(url: target), source = try write("incoming/added.txt")
        let updated = try archive.editFiles(package: 0, directory: archive.packages[0].root, adding: [source])
        XCTAssertEqual(updated.revision.inode, archive.revision.inode)
        XCTAssertEqual(updated.files[0].offset, extent); XCTAssertEqual(updated.files[0].size, size)
        let input = try regularFile(target); defer { try? input.close() }
        XCTAssertEqual(try readRange(input, offset: extent, count: 8), Data("sentinel".utf8))
        try StreamCodec.consume(updated.files.last!, input: input, context: JobContext())
        var info = stat(); XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertLessThan(info.st_blocks * 512, 2 * 1024 * 1024)
        noFileJournal(target)
        // Original 4-GiB payload deliberately has a synthetic hash: structure and
        // sentinels checked here; normal fixtures above receive full deep checks.
    }
}
