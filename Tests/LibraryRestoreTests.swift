import XCTest
@testable import NUPStudio

final class LibraryRestoreTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "NUPLibraryRestoreTests-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    @MainActor private func completed(_ store: WorkspaceStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.busy {
            if Date() > deadline { XCTFail("Bibliotheksvorgang wurde nicht beendet."); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor func testSuccessfulSelectionRestoresFreshListAndOnlyOnce() async throws {
        try Data([1]).write(to: root.appendingPathComponent("A.nup"))
        let first = WorkspaceStore(defaults: preferences)
        first.scanLibrary(root)
        try await completed(first)
        let saved = try XCTUnwrap(preferences.string(forKey: "libraryFolderPath"))
        XCTAssertEqual(saved, first.library?.folder.path)
        try Data([2]).write(to: root.appendingPathComponent("Neu.NUP"))

        // A separate store and defaults instance represent a fresh app session.
        let next = WorkspaceStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        next.restoreLibraryIfNeeded()
        try await completed(next)
        XCTAssertEqual(next.section, .library)
        XCTAssertEqual(next.library?.entries.map(\.name), ["A.nup", "Neu.NUP"])
        XCTAssertNil(next.error)
        let identity = next.library?.id
        next.restoreLibraryIfNeeded()
        XCTAssertFalse(next.busy)
        XCTAssertEqual(next.library?.id, identity)
    }

    @MainActor func testUnavailableDiskIsRememberedWithoutModalAndCanBeRetried() async throws {
        let offline = root.appendingPathComponent("Offline")
        preferences.set(offline.path, forKey: "libraryFolderPath")
        let store = WorkspaceStore(defaults: preferences)
        store.restoreLibraryIfNeeded()
        try await completed(store)
        XCTAssertEqual(store.section, .library)
        XCTAssertNil(store.library)
        XCTAssertNil(store.error)
        XCTAssertNotNil(store.libraryUnavailableMessage)
        XCTAssertEqual(preferences.string(forKey: "libraryFolderPath"), offline.path)
        try FileManager.default.createDirectory(at: offline, withIntermediateDirectories: true)
        try Data([1]).write(to: offline.appendingPathComponent("A.nup"))
        store.refreshLibrary()
        try await completed(store)
        XCTAssertEqual(store.library?.entries.count, 1)
        XCTAssertNil(store.libraryUnavailableMessage)
    }

    @MainActor func testFailedOrCancelledSelectionDoesNotReplaceSavedFolder() async throws {
        preferences.set(root.path, forKey: "libraryFolderPath")
        let store = WorkspaceStore(defaults: preferences)
        store.scanLibrary(root.appendingPathComponent("Nicht vorhanden"))
        try await completed(store)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(preferences.string(forKey: "libraryFolderPath"), root.path)
        store.error = nil
        store.scanLibrary(root)
        store.cancel()
        try await completed(store)
        XCTAssertNil(store.library)
        XCTAssertEqual(preferences.string(forKey: "libraryFolderPath"), root.path)
    }

    @MainActor func testExplicitFileOpenWinsBeforeAndDuringStartupRestore() async throws {
        let dump = root.appendingPathComponent("dump/romfs")
        try FileManager.default.createDirectory(at: dump, withIntermediateDirectories: true)
        try Data([1]).write(to: dump.appendingPathComponent("file"))
        let file = root.appendingPathComponent("Explicit.nup")
        try NUPWriter.pack(source: dump.deletingLastPathComponent(), destination: file, options: PackOptions(), context: JobContext())
        preferences.set(root.path, forKey: "libraryFolderPath")
        let before = WorkspaceStore(defaults: preferences)
        before.open(file)
        before.restoreLibraryIfNeeded()
        try await completed(before)
        XCTAssertEqual(before.archive?.url, file)
        XCTAssertEqual(before.section, .archive)

        let during = WorkspaceStore(defaults: preferences)
        during.restoreLibraryIfNeeded()
        during.open(file)
        try await completed(during)
        XCTAssertEqual(during.archive?.url, file)
        XCTAssertEqual(during.section, .archive)
        XCTAssertNil(during.error)
    }

    @MainActor func testNoSavedOrInvalidFolderLeavesWelcomeUnchanged() {
        for path in [nil, "", "relativer/pfad", "\0"] as [String?] {
            preferences.set(path, forKey: "libraryFolderPath")
            let store = WorkspaceStore(defaults: preferences)
            store.restoreLibraryIfNeeded()
            XCTAssertNil(store.rememberedLibraryFolder)
            XCTAssertFalse(store.busy)
            XCTAssertEqual(store.section, .archive)
        }
    }
}
