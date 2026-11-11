import XCTest
import UniformTypeIdentifiers
@testable import NUPStudio

final class FileDropTests: XCTestCase {
    private var root: URL!
    private var preferences: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "NUPFileDropTests-\(UUID().uuidString)"
        preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func provider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    private func container() throws -> URL {
        let source = root.appendingPathComponent("dump/romfs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("drop payload".utf8).write(to: source.appendingPathComponent("file"))
        let url = root.appendingPathComponent("Drag Test [1234].NUP")
        try NUPWriter.pack(source: source.deletingLastPathComponent(), destination: url,
                           options: PackOptions(), context: JobContext())
        return url
    }

    @MainActor private func completed(_ store: WorkspaceStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.busy {
            if Date() > deadline { XCTFail("Drop-Auftrag wurde nicht beendet."); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testFinderFileURLProviderPreservesSpacesAndBrackets() async throws {
        let file = root.appendingPathComponent("Spiel [1234].NUP")
        let decoded = try await FileDropReader.url(from: provider(file))
        XCTAssertEqual(decoded, file)
        XCTAssertThrowsError(try FileDropReader.decode(NSURL(string: "https://example.invalid/game.nup")))
        XCTAssertThrowsError(try FileDropReader.decode(Data([0xff, 0x00]) as NSData))
    }

    @MainActor func testProviderDropOpensNUPWithoutModifyingIt() async throws {
        let file = try container(), original = try Data(contentsOf: file)
        let store = WorkspaceStore(defaults: preferences)
        XCTAssertTrue(store.receiveDrop([provider(file)]))
        let deadline = Date().addingTimeInterval(5)
        while store.archive == nil && store.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await completed(store)
        XCTAssertEqual(store.archive?.url, file)
        XCTAssertEqual(store.section, .archive)
        XCTAssertNil(store.error)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor func testFolderDropLoadsAndRemembersLibrary() async throws {
        let file = try container()
        let store = WorkspaceStore(defaults: preferences)
        XCTAssertTrue(store.receiveFileURLs([root]))
        try await completed(store)
        XCTAssertEqual(store.section, .library)
        XCTAssertEqual(store.library?.entries.map(\.name), [file.lastPathComponent])
        let selected = try XCTUnwrap(store.library?.entries.first?.url)
        XCTAssertTrue(FileManager.default.contentsEqual(atPath: selected.path, andPath: file.path))
        XCTAssertEqual(preferences.string(forKey: "libraryFolderPath"), root.path)
        XCTAssertNil(store.error)
    }

    @MainActor func testFolderDropInCreateSelectsSourceWithoutScanningOrWriting() throws {
        let store = WorkspaceStore(defaults: preferences)
        store.section = .pack
        XCTAssertTrue(store.receiveFileURLs([root]))
        XCTAssertEqual(store.sourceFolder?.path, root.path)
        XCTAssertEqual(store.section, .pack)
        XCTAssertFalse(store.busy)
        XCTAssertNil(store.library)
        XCTAssertNil(preferences.string(forKey: "libraryFolderPath"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor func testUnsupportedAndMultipleFilesAreRejectedWithoutOpeningFirst() throws {
        let file = try container(), other = root.appendingPathComponent("Not a NUP.txt")
        try Data([1]).write(to: other)
        let store = WorkspaceStore(defaults: preferences)
        for urls in [[], [file, other], [other], [URL(string: "https://example.invalid/game.nup")!]] {
            store.error = nil
            XCTAssertFalse(store.receiveFileURLs(urls))
            XCTAssertNotNil(store.error)
            XCTAssertNil(store.archive)
            XCTAssertFalse(store.busy)
        }
        XCTAssertFalse(store.receiveDrop([provider(file), provider(other)]))
    }

    @MainActor func testRunningJobCannotBeReplacedByDrop() throws {
        let file = try container()
        let store = WorkspaceStore(defaults: preferences)
        store.busy = true
        XCTAssertFalse(store.canReceiveFiles)
        XCTAssertFalse(store.receiveFileURLs([file]))
        XCTAssertFalse(store.receiveDrop([provider(file)]))
        XCTAssertNil(store.archive)
        XCTAssertNil(store.sourceFolder)
    }

    @MainActor func testExplicitDropTakesPriorityOverStartupRestore() async throws {
        let file = try container()
        preferences.set(root.path, forKey: "libraryFolderPath")
        let store = WorkspaceStore(defaults: preferences)
        store.restoreLibraryIfNeeded()
        XCTAssertTrue(store.canReceiveFiles)
        XCTAssertTrue(store.receiveFileURLs([file]))
        try await completed(store)
        XCTAssertEqual(store.archive?.url, file)
        XCTAssertEqual(store.section, .archive)
        XCTAssertNil(store.error)
    }
}
