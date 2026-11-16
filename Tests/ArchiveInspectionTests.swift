import XCTest
@testable import NUPStudio

extension NUPCoreTests {
    private func inspectionFixture() throws -> NUPArchive {
        let name = UUID().uuidString
        try write(name + "/dump/romfs/a-raw.txt", Data("raw one".utf8))
        try write(name + "/dump/romfs/b-frame.bin", Data(repeating: 42, count: 16384))
        try write(name + "/dump/romfs/c-valid.txt", Data("last file still checked".utf8))
        try write(name + "/dump/romfs/d-empty.txt", Data())
        let url = root.appendingPathComponent(name + ".nup")
        try NUPWriter.pack(source: root.appendingPathComponent(name + "/dump"), destination: url, options: PackOptions(), context: JobContext())
        return try NUPArchive(url: url)
    }
    private func corruptInspectionFile(_ archive: NUPArchive, name: String) throws {
        let file = try XCTUnwrap(archive.files.first { $0.name == name })
        let handle = try regularFile(archive.url, writable: true); defer { try? handle.close() }
        try handle.seek(toOffset: file.offset); let byte = try readExactly(handle, 1)
        try handle.seek(toOffset: file.offset); try handle.write(contentsOf: Data([byte[0] ^ 0xff])); try handle.synchronize()
    }

    func testInspectionCollectsHashAndFrameErrorsAndContinuesThroughLastFileWithoutWriting() throws {
        let archive = try inspectionFixture()
        XCTAssertEqual(archive.files.first { $0.name == "a-raw.txt" }?.codec, 0)
        XCTAssertEqual(archive.files.first { $0.name == "b-frame.bin" }?.codec, 1)
        try corruptInspectionFile(archive, name: "a-raw.txt")
        try corruptInspectionFile(archive, name: "b-frame.bin")
        let before = try Data(contentsOf: archive.url)
        let report = try ArchiveInspection.inspect(archive.url, deep: true), check = try XCTUnwrap(report.fileCheck)
        XCTAssertEqual(check.checked, 4); XCTAssertEqual(check.failed, 2)
        XCTAssertEqual(check.failures.map(\.path), ["/romfs/a-raw.txt", "/romfs/b-frame.bin"])
        XCTAssertEqual(check.failures.map(\.package), [0, 0])
        XCTAssertTrue(check.failures[0].message.contains("SHA-256"))
        XCTAssertFalse(report.canRepair)
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
    }

    func testInspectionDistinguishesStructureOnlyFromCompleteAndBlockedChecks() throws {
        let archive = try inspectionFixture(), before = try Data(contentsOf: archive.url)
        XCTAssertNil(try ArchiveInspection.inspect(archive.url, deep: false).fileCheck)
        let healthy = try ArchiveInspection.inspect(archive.url, deep: true)
        XCTAssertEqual(healthy.fileCheck?.checked, 4); XCTAssertEqual(healthy.fileCheck?.failed, 0)
        XCTAssertEqual(try Data(contentsOf: archive.url), before)
        let handle = try regularFile(archive.url, writable: true)
        try handle.seek(toOffset: 24); try handle.write(contentsOf: Data(repeating: 0, count: 32)); try handle.close()
        let damaged = try Data(contentsOf: archive.url), blocked = try ArchiveInspection.inspect(archive.url, deep: true)
        XCTAssertNil(blocked.fileCheck); XCTAssertFalse(blocked.blockers.isEmpty); XCTAssertFalse(blocked.canRepair)
        XCTAssertEqual(try Data(contentsOf: archive.url), damaged)
    }

    func testInspectionCancellationAndConcurrentModificationNeverProduceCompleteResult() throws {
        let archive = try inspectionFixture(), context = JobContext(); context.cancel()
        XCTAssertThrowsError(try ArchiveInspection.inspect(archive.url, deep: true, context: context)) { XCTAssertTrue($0 is CancellationError) }
        let url = archive.url
        let firstFileMessage = L10n.text("Datei \(String(describing: 1))/\(String(describing: archive.files.count)): \(archive.files[0].name)")
        let changing = JobContext { _, message in
            guard message == firstFileMessage else { return }
            let handle = try! regularFile(url, writable: true)
            try! handle.seek(toOffset: archive.files[0].offset)
            try! handle.write(contentsOf: Data([255])); try! handle.close()
        }
        XCTAssertThrowsError(try ArchiveInspection.inspect(url, deep: true, context: changing))
    }

    @MainActor func testOpenedInspectionPreservesDraftAndSelectsExactFailedFiles() async throws {
        let fixture = try inspectionFixture(); try corruptInspectionFile(fixture, name: "a-raw.txt")
        let suite = "NUPInspection-\(UUID().uuidString)", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: preferences)
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while store.busy {
                if Date() > deadline { throw NUPError("Inspection did not finish") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(fixture.url); try await finish()
        store.editDraft?.packages[0].name = "Unsaved inspection draft"
        let before = try Data(contentsOf: fixture.url)
        store.verify(deep: true); try await finish()
        let report = try XCTUnwrap(store.repairReport), failure = try XCTUnwrap(report.fileCheck?.failures.first)
        XCTAssertEqual(store.editDraft?.packages[0].name, "Unsaved inspection draft")
        XCTAssertTrue(store.hasPendingEdits); XCTAssertTrue(store.canSelectFailedFiles(report))
        store.selectFailedFiles(report, files: [failure.id])
        XCTAssertNil(store.repairReport)
        XCTAssertEqual(store.lastInspection?.id, report.id)
        XCTAssertEqual(store.fileSelection?.nodes, [fixture.directories.count + failure.id])
        XCTAssertEqual(store.fileSelection?.package, failure.package)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        try corruptInspectionFile(fixture, name: "c-valid.txt")
        store.selectFailedFiles(report, files: [failure.id])
        XCTAssertNotNil(store.repairError)
    }
}
