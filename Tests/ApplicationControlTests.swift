import XCTest
@testable import NUPStudio

extension NUPCoreTests {
    private func controlData() -> Data {
        var data = Data(count: 0x4000)
        data.put(Data("Example Game".utf8), at: 0)
        data.put(Data("Example Publisher".utf8), at: 0x200)
        data.put(Data("Beispielspiel".utf8), at: 4 * 0x300)
        data.put(Data("Beispielverlag".utf8), at: 4 * 0x300 + 0x200)
        data.put(Data("2.0.1a".utf8), at: 0x3060)
        return data
    }

    func testControlDataReadsLocalizedTitlePublisherAndDisplayVersion() throws {
        let data = controlData()
        let control = try ApplicationControl(data, preferredLanguages: ["de-DE"])
        XCTAssertEqual(control.name, "Beispielspiel")
        XCTAssertEqual(control.publisher, "Beispielverlag")
        XCTAssertEqual(control.displayVersion, "2.0.1a")
        XCTAssertEqual(control.titles, ["de": "Beispielspiel", "en-us": "Example Game"])
        XCTAssertThrowsError(try ApplicationControl(Data(data.dropLast())))
    }

    func testControlDataReadsCompressedLanguageTable() throws {
        // Raw DEFLATE fixture for a 32-entry table containing "Polska" in slot 16.
        let deflate = try XCTUnwrap(Data(base64Encoded: "7c4xDQAgDACwSZwFbpZw4D+Zg71wtAoaAQAAAAAAAAAAAAAA/C5P3b1eLwAAAAAAAAAAAAAAgEkD"))
        var data = Data(count: 0x4000)
        data.put(UInt64(deflate.count), at: 0, width: 2)
        data.put(deflate, at: 2)
        data[0x3215] = 1
        let control = try ApplicationControl(data, preferredLanguages: ["pl-PL"])
        XCTAssertEqual(control.name, "Polska")
        XCTAssertEqual(control.titles, ["pl": "Polska"])
    }

    @MainActor func testPackageImportAndCoverCopyAreStagedAndKeepUpdateVersion() async throws {
        let directory = root.appendingPathComponent("application-data")
        try write("application-data/base/romfs/control.nacp", controlData())
        try write("application-data/updates/65536/romfs/update.bin", Data("payload".utf8))
        let url = root.appendingPathComponent("application-data.nup")
        var options = PackOptions()
        let icon = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPQCmr4DwADogH8SmkI7gAAAABJRU5ErkJggg=="))
        options.icon = icon
        try NUPWriter.pack(source: directory, destination: url, options: options, context: JobContext())
        let archive = try NUPArchive(url: url)
        let suite = "NUPApplicationData-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        store.archive = archive
        store.editDraft = ArchiveEditDraft(archive: archive)
        store.editDraft?.packages[1].displayVersion = "3.0.0"
        let before = try Data(contentsOf: url)
        store.importApplicationData(package: 0)
        let deadline = Date().addingTimeInterval(10)
        while store.busy {
            if Date() > deadline { throw NUPError("NACP import did not finish") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(store.error)
        XCTAssertEqual(store.editDraft?.packages[0].displayVersion, "2.0.1a")
        XCTAssertEqual(store.editDraft?.packages[0].localized.count, 2)
        XCTAssertThrowsError(try ApplicationControl.read(from: archive, package: 1, context: JobContext()))
        store.stageCover(from: 0, to: [1], onlyMissing: true)
        store.stageMissingApplicationText(from: 0, to: 1)
        let draft = try XCTUnwrap(store.editDraft)
        XCTAssertEqual(draft.packages[1].icon, icon)
        XCTAssertEqual(draft.packages[1].name, draft.packages[0].name)
        XCTAssertEqual(draft.packages[1].displayVersion, "3.0.0")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let saved = try archive.applyEdits(draft.request(), context: JobContext())
        XCTAssertEqual(saved.packages[1].metadata[3], icon)
        XCTAssertEqual(saved.packages[1].metadata[4], Data("3.0.0".utf8))
        XCTAssertEqual(saved.packages[1].version, archive.packages[1].version)
        XCTAssertEqual(saved.revision.inode, archive.revision.inode)
    }
}
