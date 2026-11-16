import XCTest
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    private func draftCover() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let data = try XCTUnwrap(CFDataCreateMutable(nil, 0)), image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil); XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
    private func combinedDraft(_ archive: NUPArchive) throws -> ArchiveEditDraft {
        var draft = ArchiveEditDraft(archive: archive)
        draft.packages[0].name = "Gemeinsam bearbeitet"; draft.packages[0].publisher = "Publisher neu"
        draft.packages[0].icon = try draftCover()
        draft.packages[0].localized = [LocalizedEntry(language: "de", title: "Neuer Sprachtitel", icon: try draftCover())]
        draft.packages[1].displayVersion = "7.1.0"; draft.packages[1].source = "lokaler Entwurf"
        let source = try write("incoming/new-file.txt", Data("new file".utf8))
        try draft.stageFiles(package: 0, directory: XCTUnwrap(archive.packages[0].romfs), urls: [source])
        let other = try write("incoming/other-file.txt", Data("other new file".utf8))
        try draft.stageFiles(package: 1, directory: XCTUnwrap(archive.packages[1].romfs), urls: [other])
        let removed = try XCTUnwrap(archive.files.firstIndex { $0.name == "dlc" })
        try draft.stageFiles(package: 2, directory: archive.packages[2].root, urls: [], removing: [removed])
        return draft
    }
    private func stagedPlan(_ archive: NUPArchive, request: ArchiveEditRequest) throws -> (ArchiveFileStage, ArchiveFilePlan) {
        let stage = try ArchiveFileStage(archive: archive, urls: request.files.flatMap(\.additions), context: JobContext())
        var position = 0
        let groups = request.files.map { mutation -> ArchiveFilePlanGroup in
            let end = position + mutation.additions.count; defer { position = end }
            return ArchiveFilePlanGroup(package: mutation.package, directory: mutation.directory,
                additions: Array(stage.files[position..<end]), removing: mutation.removing)
        }
        return (stage, try ArchiveFilePlan(archive: archive, groups: groups, stageSize: stage.size, metadata: request.metadata))
    }
    private func noDraftJournals(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        for paths in [ArchiveContentJournal.journals(for: url), MetadataTransaction.journals(for: url)] {
            XCTAssertFalse(fm.fileExists(atPath: paths.pending.path), file: file, line: line)
            XCTAssertFalse(fm.fileExists(atPath: paths.committed.path), file: file, line: line)
        }
    }

    func testDraftCollectsEveryPackageMetadataCoverLanguageAndFileWithoutWriting() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url), draft = try combinedDraft(archive)
        XCTAssertTrue(draft.hasChanges); XCTAssertNil(draft.validationError)
        XCTAssertEqual(draft.additions.count, 2); XCTAssertEqual(draft.removals.count, 1)
        XCTAssertTrue(draft.nodes(package: 0, query: "new-file").contains { $0.isDirectory })
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        XCTAssertEqual(try FileRevision(handle: regularFile(archive.url)).inode, archive.revision.inode)
        noDraftJournals(archive.url)
    }

    func testApplyCombinesMetadataAndFilesAcrossPackagesAndPreservesUntouchedContent() throws {
        let archive = try packed(), draft = try combinedDraft(archive), request = try draft.request()
        let updated = try archive.applyEdits(request)
        XCTAssertEqual(updated.revision.inode, archive.revision.inode)
        XCTAssertEqual(updated.uuid, archive.uuid); XCTAssertEqual(updated.packages.map(\.titleID), archive.packages.map(\.titleID))
        XCTAssertEqual(updated.packages.map(\.kind), archive.packages.map(\.kind)); XCTAssertEqual(updated.packages.map(\.version), archive.packages.map(\.version))
        for (index, metadata) in request.metadata { XCTAssertEqual(updated.packages[index].metadata, metadata) }
        XCTAssertTrue(updated.files.contains { $0.name == "new-file.txt" }); XCTAssertTrue(updated.files.contains { $0.name == "other-file.txt" })
        XCTAssertFalse(updated.files.contains { $0.name == "dlc" })
        let retained = try XCTUnwrap(archive.files.first { $0.name == "large.bin" })
        XCTAssertEqual(updated.files.first { $0.name == "large.bin" }?.hash, retained.hash)
        XCTAssertEqual(updated.files.first { $0.name == "large.bin" }?.storedSize, retained.storedSize)
        XCTAssertEqual(updated.packages[0].metadata[1], archive.packages[0].metadata[1])
        try updated.verify(deep: true, context: JobContext()); noDraftJournals(archive.url)
    }

    func testDraftSingleMetadataEditUsesSmallTransactionAndKeepsAllFileOffsets() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        var draft = ArchiveEditDraft(archive: archive); draft.packages[0].name = "Only title"
        let updated = try archive.applyEdits(draft.request())
        XCTAssertEqual(updated.files.map(\.offset), archive.files.map(\.offset))
        XCTAssertEqual(updated.toc.count, archive.toc.count); XCTAssertEqual(updated.uuid, archive.uuid)
        for file in archive.files where file.storedSize > 0 {
            let output = try regularFile(archive.url); defer { try? output.close() }
            XCTAssertEqual(try readRange(output, offset: file.offset, count: integer(file.storedSize)), try original.bytes(integer(file.offset), integer(file.storedSize)))
        }
        try updated.verify(deep: true, context: JobContext())
    }

    func testDraftMultipleMetadataOnlyEditIsOneRecoverableTransaction() throws {
        let archive = try packed()
        var draft = ArchiveEditDraft(archive: archive); draft.packages[0].name = "Base"; draft.packages[1].name = "Update"
        let updated = try archive.applyEdits(draft.request())
        XCTAssertEqual(updated.toc.count, archive.toc.count); XCTAssertEqual(updated.files.map(\.offset), archive.files.map(\.offset))
        XCTAssertEqual(updated.packages[0].text(5, profile: .specification), "Base")
        XCTAssertEqual(updated.packages[1].text(5, profile: .specification), "Update")
        try updated.verify(deep: true, context: JobContext()); noDraftJournals(archive.url)
    }

    func testDraftCancellationRestoresWholeBatchAndCanBeRetriedWithoutLosingEdits() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        var draft = try combinedDraft(archive)
        for phase in [L10n.text("Aktualisiere Dateiverzeichnis …"), L10n.text("Prüfe geänderten Container …")] {
            let box = Box(); box.context = JobContext { _, message in if message == phase { box.context?.cancel() } }
            do { _ = try draft.archive.applyEdits(draft.request(), context: box.context!); XCTFail("Expected cancellation") }
            catch let failure as ArchiveEditFailure {
                XCTAssertTrue(failure.underlying is CancellationError)
                try draft.rebase(on: failure.recovered)
            }
            XCTAssertEqual(try Data(contentsOf: archive.url), original); XCTAssertTrue(draft.hasChanges); noDraftJournals(archive.url)
        }
        let result = try draft.archive.applyEdits(draft.request())
        XCTAssertEqual(result.packages[0].text(5, profile: .specification), "Gemeinsam bearbeitet")
        try result.verify(deep: true, context: JobContext())
    }

    func testSingleMetadataCancellationRebasesDraftAfterVerifiedRollback() throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        var draft = ArchiveEditDraft(archive: archive); draft.packages[0].name = "Retry title"
        let box = Box(); box.context = JobContext { _, message in if message == L10n.text("Prüfe Metadatenänderung …") { box.context?.cancel() } }
        do { _ = try archive.applyEdits(draft.request(), context: box.context!); XCTFail("Expected cancellation") }
        catch let failure as ArchiveEditFailure { XCTAssertTrue(failure.underlying is CancellationError); try draft.rebase(on: failure.recovered) }
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        XCTAssertEqual(try draft.archive.applyEdits(draft.request()).packages[0].text(5, profile: .specification), "Retry title")
    }

    func testInterruptedCombinedTransactionsRecoverPartialTOCHeaderAndCommittedState() throws {
        let initial = try packed()
        for phase in 0...4 {
            let archive = try NUPArchive(url: initial.url), original = try Data(contentsOf: archive.url), draft = try combinedDraft(archive)
            let request = try draft.request(), (stage, plan) = try stagedPlan(archive, request: request)
            let journal = ArchiveContentJournal(archive: archive, plan: plan), file = try regularFile(archive.url, writable: true)
            try journal.prepare(url: archive.url, file: file)
            if phase >= 1 {
                let input = try regularFile(archive.url)
                _ = try plan.appendPayloads(input: input, output: file, stage: stage.handle, context: JobContext())
                try input.close()
            }
            if phase == 2 { try file.seek(toOffset: plan.header.uint(8, 8)); try file.write(contentsOf: plan.toc.prefix(plan.toc.count / 2)) }
            else if phase >= 3 { try plan.writeTOC(to: file); try plan.writeHeader(to: file) }
            if phase == 4 { try ArchiveContentJournal.markCommitted(url: archive.url) }
            try file.close()
            let reopened = try NUPArchive(url: archive.url)
            if phase < 4 { XCTAssertEqual(try Data(contentsOf: archive.url), original, "phase \(phase)") }
            else { XCTAssertEqual(reopened.packages[0].text(5, profile: .specification), "Gemeinsam bearbeitet") }
            try reopened.verify(deep: true, context: JobContext()); noDraftJournals(archive.url)
        }
    }

    func testDraftRejectsCollisionsSelfInsertionSymlinksAndForeignRemovalsWithoutChangingDraft() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        var draft = ArchiveEditDraft(archive: archive)
        let directory = try XCTUnwrap(archive.packages[0].romfs), source = try write("incoming/new.txt")
        try draft.stageFiles(package: 0, directory: directory, urls: [source])
        let duplicate = try write("incoming/other/NEW.txt"), link = root.appendingPathComponent("incoming/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        let foreign = try XCTUnwrap(archive.files.firstIndex { $0.name == "dlc" })
        for url in [duplicate, archive.url, link] {
            XCTAssertThrowsError(try draft.stageFiles(package: 0, directory: directory, urls: [url]))
            XCTAssertEqual(draft.additions.count, 1)
        }
        XCTAssertThrowsError(try draft.stageFiles(package: 0, directory: directory, urls: [], removing: [foreign]))
        XCTAssertTrue(draft.removals.isEmpty); XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }

    func testDraftSupportsReplacingNameAndUndoingStagedAdditionAndRemoval() throws {
        let archive = try packed(), index = try XCTUnwrap(archive.files.firstIndex { $0.name == "raw.bin" })
        let file = try write("incoming/raw.bin", Data("replacement".utf8)), directory = try XCTUnwrap(archive.packages[0].romfs)
        var draft = ArchiveEditDraft(archive: archive)
        try draft.stageFiles(package: 0, directory: directory, urls: [], removing: [index])
        try draft.stageFiles(package: 0, directory: directory, urls: [file])
        let added = try XCTUnwrap(draft.additions.first)
        draft.removePending(nodes: [added.nodeID]); draft.restoreFiles([index])
        XCTAssertFalse(draft.hasChanges)
        try draft.stageFiles(package: 0, directory: directory, urls: [file], removing: [index])
        let result = try archive.applyEdits(draft.request())
        XCTAssertEqual(result.files.first { $0.name == "raw.bin" }?.hash, Data("replacement".utf8).sha256)
        try result.verify(deep: true, context: JobContext())
    }

    func testChangedQueuedSourceAndChangedOriginalAreRefusedWithoutNUPWrites() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url), source = try write("incoming/change.txt")
        var draft = ArchiveEditDraft(archive: archive)
        try draft.stageFiles(package: 0, directory: archive.packages[0].root, urls: [source])
        try Data("changed after selection".utf8).write(to: source)
        XCTAssertThrowsError(try archive.applyEdits(draft.request()))
        XCTAssertEqual(try Data(contentsOf: archive.url), original); noDraftJournals(archive.url)
        let file = try regularFile(archive.url, writable: true)
        try file.seekToEnd(); try file.write(contentsOf: Data([1])); try file.close()
        let changed = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try archive.applyEdits(draft.request())); XCTAssertEqual(try Data(contentsOf: archive.url), changed)
    }

    func testDraftValidationPreservesOpaqueLanguageAndVendorFieldsUntilExplicitlyEdited() throws {
        var archive = try packed(), metadata = archive.packages[0].metadata
        metadata[9] = Data([255, 1]); metadata[0x8000] = Data([0, 255, 1])
        try MetadataTransaction.update(archive: archive, package: 0, metadata: metadata, context: JobContext())
        archive = try NUPArchive(url: archive.url)
        var draft = ArchiveEditDraft(archive: archive)
        XCTAssertFalse(draft.hasChanges); draft.packages[0].publisher = "Changed"
        XCTAssertEqual(try draft.request().metadata[0]?[9], metadata[9])
        XCTAssertEqual(try draft.request().metadata[0]?[0x8000], metadata[0x8000])
        draft.packages[0].localized = [LocalizedEntry(language: "", title: "Invalid")]
        XCTAssertNotNil(draft.validationError); XCTAssertThrowsError(try draft.request())
        draft.packages[0].localized = [LocalizedEntry(language: "de", title: "German"), LocalizedEntry(language: "DE", title: "Duplicate")]
        XCTAssertNotNil(draft.validationError)
        draft.packages[0].localized = []; draft.packages[0].buildID = "not hex"
        XCTAssertNotNil(draft.validationError)
        let original = try Data(contentsOf: archive.url)
        var invalid = ArchiveEditRequest(); var bad = metadata; bad[3] = Data([1]); invalid.metadata[0] = bad
        XCTAssertThrowsError(try archive.applyEdits(invalid)); XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }

    func testSaveWholeDraftAsPreservesOriginalAndFailedCopyLeavesNoArtifacts() throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url), draft = try combinedDraft(archive)
        let target = root.appendingPathComponent("combined-copy.nup")
        let copy = try archive.saveEditsAs(draft.request(), destination: target, context: JobContext())
        XCTAssertEqual(copy.packages[0].text(5, profile: .specification), "Gemeinsam bearbeitet")
        XCTAssertTrue(copy.files.contains { $0.name == "new-file.txt" })
        try copy.verify(deep: true, context: JobContext()); XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let context = JobContext(); context.cancel()
        XCTAssertThrowsError(try archive.saveEditsAs(draft.request(), destination: root.appendingPathComponent("cancelled.nup"), context: context))
        XCTAssertThrowsError(try archive.saveEditsAs(draft.request(), destination: target, context: JobContext()))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-") })
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }
}

extension NUPCoreTests {
    func testEditingLanguageTitleKeepsUnchangedOpaqueLanguageIconsByteForByte() throws {
        var archive = try packed(), metadata = archive.packages[0].metadata
        metadata[9] = try MetadataCodec.localizedData(["de": Data("Alt".utf8)])
        metadata[10] = try MetadataCodec.localizedData(["en": Data([1, 255, 7])])
        try MetadataTransaction.update(archive: archive, package: 0, metadata: metadata, context: JobContext())
        archive = try NUPArchive(url: archive.url)
        var draft = ArchiveEditDraft(archive: archive)
        let index = try XCTUnwrap(draft.packages[0].localized.firstIndex { $0.language == "de" })
        draft.packages[0].localized[index].title = "Neu"
        XCTAssertEqual(try draft.request().metadata[0]?[10], metadata[10])
        let updated = try archive.applyEdits(draft.request())
        XCTAssertEqual(updated.packages[0].metadata[10], metadata[10])
        XCTAssertEqual(try MetadataCodec.localized(XCTUnwrap(updated.packages[0].metadata[9]))["de"], Data("Neu".utf8))
    }

    func testCombinedDraftOnFourGiBSparseContainerKeepsAllocationAndSentinel() throws {
        let small = try packed(), size: UInt64 = 4 * 1024 * 1024 * 1024
        let output = try regularFile(small.url, writable: true)
        var header = small.header; header.put(size, at: 64, width: 8)
        try output.truncate(atOffset: size); try output.seek(toOffset: size - 1); try output.write(contentsOf: Data([91]))
        try output.seek(toOffset: 0); try output.write(contentsOf: header); try output.close()
        let archive = try NUPArchive(url: small.url), draft = try combinedDraft(archive)
        let updated = try archive.applyEdits(draft.request())
        XCTAssertEqual(updated.revision.inode, archive.revision.inode)
        let input = try regularFile(archive.url); defer { try? input.close() }
        XCTAssertEqual(try readRange(input, offset: size - 1, count: 1), Data([91]))
        var info = stat(); XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertLessThan(info.st_blocks * 512, 2 * 1024 * 1024)
        try updated.verify(deep: true, context: JobContext())
    }

    @MainActor func testWorkspaceDraftSurvivesPackageAndSectionChangesAndDiscardWritesNothing() async throws {
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        let suite = "NUPDraftStore-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("Draft store timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(archive.url); try await finish()
        store.editDraft?.packages[0].name = "Uncommitted title"
        store.packageIndex = 1; store.editDraft?.packages[1].publisher = "Uncommitted publisher"
        store.section = .library; store.section = .pack; store.section = .archive; store.packageIndex = 0
        XCTAssertEqual(store.editDraft?.packages[0].name, "Uncommitted title")
        XCTAssertEqual(store.editDraft?.packages[1].publisher, "Uncommitted publisher")
        XCTAssertTrue(store.hasPendingEdits); XCTAssertTrue(store.canApplyEdits)
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        store.discardEdits()
        XCTAssertFalse(store.hasPendingEdits); XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }

    @MainActor func testWorkspaceOpenConfirmationSupportsCancelDiscardAndApplyBeforeContinue() async throws {
        let first = try packed(), original = try Data(contentsOf: first.url)
        let secondURL = try write("second.nup", original)
        let suite = "NUPDraftNavigation-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("Navigation timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(first.url); try await finish()
        store.editDraft?.packages[0].name = "First pending"
        store.open(secondURL)
        XCTAssertNotNil(store.pendingNavigation); XCTAssertEqual(store.archive?.url, first.url)
        store.pendingNavigation = nil // cancel the dialog
        XCTAssertTrue(store.hasPendingEdits); XCTAssertEqual(try Data(contentsOf: first.url), original)
        store.open(secondURL); store.discardAndContinue(); try await finish()
        XCTAssertEqual(store.archive?.url, secondURL); XCTAssertEqual(try Data(contentsOf: first.url), original)
        store.editDraft?.packages[0].name = "Saved before navigation"
        store.open(first.url); store.applyAndContinue(); try await finish()
        XCTAssertEqual(store.archive?.url, first.url)
        XCTAssertEqual(try NUPArchive(url: secondURL).packages[0].text(5, profile: .specification), "Saved before navigation")
        XCTAssertFalse(store.hasPendingEdits)
    }

    @MainActor func testWorkspaceVerifiedRollbackKeepsDraftAndAllowsRetry() async throws {
        final class Box: @unchecked Sendable { var context: JobContext? }
        let archive = try packed(), original = try Data(contentsOf: archive.url)
        let suite = "NUPDraftRetry-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("Retry timeout") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(archive.url); try await finish()
        store.editDraft = try combinedDraft(XCTUnwrap(store.archive))
        let draft = try XCTUnwrap(store.editDraft), box = Box()
        box.context = JobContext { _, message in if message == L10n.text("Prüfe geänderten Container …") { box.context?.cancel() } }
        let context = box.context!
        store.perform("Cancel batch") { _ in
            let updated = try draft.archive.applyEdits(draft.request(), context: context)
            return JobResult(message: "unexpected", archive: updated)
        }
        try await finish()
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        XCTAssertTrue(store.hasPendingEdits); XCTAssertTrue(store.canApplyEdits); XCTAssertNil(store.error)
        XCTAssertEqual(store.editDraft?.packages[0].name, "Gemeinsam bearbeitet")
        store.applyEdits(); try await finish()
        XCTAssertFalse(store.hasPendingEdits); XCTAssertNil(store.error)
        XCTAssertEqual(try NUPArchive(url: archive.url).packages[0].text(5, profile: .specification), "Gemeinsam bearbeitet")
    }

    @MainActor func testNativeQuitAndWindowCloseAreDeferredWhileDraftIsDirty() async throws {
        let archive = try packed(), suite = "NUPDraftClose-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        store.archive = archive; store.editDraft = ArchiveEditDraft(archive: archive)
        store.editDraft?.packages[0].name = "Pending"
        let delegate = WorkspaceApplicationDelegate(); delegate.store = store
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertNotNil(store.pendingNavigation); store.pendingNavigation = nil
        let coordinator = WorkspaceWindowGuard.Coordinator(store: store), window = NSWindow()
        store.requestWindowClose(window); XCTAssertNotNil(store.pendingNavigation); store.pendingNavigation = nil
        store.requestQuit(); XCTAssertNotNil(store.pendingNavigation); store.pendingNavigation = nil
        XCTAssertFalse(coordinator.windowShouldClose(window)); XCTAssertNotNil(store.pendingNavigation)
        XCTAssertTrue(store.hasPendingEdits)
        store.pendingNavigation = nil; store.discardEdits()
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
