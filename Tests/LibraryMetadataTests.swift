import XCTest
import ImageIO
import UniformTypeIdentifiers
import Combine
@testable import NUPStudio

final class LibraryMetadataTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "NUPLibraryMetadataTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func image() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
        let output = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func package(_ profile: MetadataProfile, title: String, icon: Data? = nil) -> NUPPackage {
        var p = NUPPackage(id: 0)
        p.metadata[profile.type(5)] = Data(title.utf8)
        p.metadata[profile.type(6)] = Data("Publisher".utf8)
        p.metadata[profile.type(4)] = Data("2.0.0".utf8)
        if let icon { p.metadata[profile.type(3)] = icon }
        return p
    }

    func testSpecificationShowsTitleRatherThanPublisherAndBoundsThumbnails() throws {
        for profile in MetadataProfile.allCases {
            let p = package(profile, title: "Spielname aus Metadaten", icon: try image())
            let result = LibraryMetadataReader.metadata(from: [p])
            XCTAssertEqual(result.item.title, "Spielname aus Metadaten")
            XCTAssertTrue(result.item.hasCover)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(result.thumbnail) as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 128)
            XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 64)
        }
    }

    func testSpecificationNeverReinterpretsVersionOrPublisherAsTitle() {
        var p = NUPPackage(id: 0)
        p.metadata = [0: Data([1]), 4: Data("3.2.0".utf8), 6: Data("Publisher".utf8)]
        XCTAssertNil(LibraryMetadataReader.metadata(from: [p]).item.title)
        p.metadata[5] = Data("Spezifikationstitel".utf8)
        XCTAssertEqual(LibraryMetadataReader.metadata(from: [p]).item.title, "Spezifikationstitel")
        XCTAssertNil(LibraryMetadataReader.metadata(from: [p]).item.notice)
    }

    func testBaseTitlePreferredAndUpdateCoverUsedAsFallback() throws {
        var update = package(.specification, title: "Update", icon: try image()); update.kind = 1
        let base = package(.specification, title: "Basisspiel")
        let result = LibraryMetadataReader.metadata(from: [update, base])
        XCTAssertEqual(result.item.title, "Basisspiel")
        XCTAssertTrue(result.item.hasCover)
    }

    func testLocalizedTitleAndCoverPreferGerman() throws {
        var p = NUPPackage(id: 0)
        p.metadata[9] = try MetadataCodec.localizedData(["de": Data("Deutscher Name".utf8), "en": Data("English title".utf8)])
        p.metadata[10] = try MetadataCodec.localizedData(["de": image()])
        let result = LibraryMetadataReader.metadata(from: [p])
        XCTAssertEqual(result.item.title, "Deutscher Name")
        XCTAssertTrue(result.item.hasCover)
    }

    func testMissingOrBrokenArtworkKeepsTitleAndSafeFallback() {
        var p = package(.specification, title: "Ohne Cover")
        p.metadata[3] = Data([137,80,78,71,13,10,26,10])
        let result = LibraryMetadataReader.metadata(from: [p])
        XCTAssertEqual(result.item.title, "Ohne Cover")
        XCTAssertFalse(result.item.hasCover)
        XCTAssertNil(result.thumbnail)
        XCTAssertNil(LibraryMetadataReader.metadata(from: [NUPPackage(id: 0)]).item.title)
    }

    private func packed(_ name: String, title: String) throws -> URL {
        let source = root.appendingPathComponent("dump/romfs")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([9,8,7]).write(to: source.appendingPathComponent("raw"))
        var options = PackOptions(); options.profile = .specification; options.name = title; options.icon = try image()
        let file = root.appendingPathComponent(name)
        try NUPWriter.pack(source: source.deletingLastPathComponent(), destination: file, options: options, context: JobContext())
        return file
    }

    func testPreviewIsReadOnlyAndDoesNotConsumeGamePayload() throws {
        let file = try packed("unrelated.nup", title: "Metadaten-Spiel")
        let archive = try NUPArchive(url: file)
        let writer = try FileHandle(forWritingTo: file)
        try writer.seek(toOffset: try XCTUnwrap(archive.files.first).offset)
        try writer.write(contentsOf: Data([255])); try writer.close()
        let before = try Data(contentsOf: file)
        let result = try LibraryMetadataReader.read(file, context: JobContext())
        XCTAssertEqual(result.item.title, "Metadaten-Spiel")
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertThrowsError(try NUPArchive(url: file).verify(deep: true, context: JobContext()))
        let context = JobContext(); context.cancel()
        XCTAssertThrowsError(try LibraryMetadataReader.read(file, context: context))
    }

    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { XCTFail("Metadaten wurden nicht geladen."); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor func testCatalogIsolatesBadFilesAndSearchesMetadataTitles() async throws {
        _ = try packed("Datei123.nup", title: "Besonderer Spielname")
        let bad = root.appendingPathComponent("Defekt.nup"); try Data([0]).write(to: bad)
        let snapshot = try LibraryScanner.scan(root)
        let good = try XCTUnwrap(snapshot.entries.first(where: { $0.name == "Datei123.nup" })).url
        let badEntry = try XCTUnwrap(snapshot.entries.first(where: { $0.name == "Defekt.nup" })).url
        let catalog = LibraryMetadataStore(defaults: defaults)
        catalog.load(snapshot)
        try await waitFor { !catalog.loading }
        XCTAssertEqual(catalog.completed, 2)
        XCTAssertEqual(catalog.items[good]?.title, "Besonderer Spielname")
        XCTAssertNotNil(catalog.items[badEntry]?.notice)
        XCTAssertNotNil(catalog.cover(for: good))
        XCTAssertEqual(snapshot.matching("besonderer", metadata: catalog.items).map(\.url), [good])
    }

    @MainActor func testCatalogReloadAndMetadataEditDiscardStaleResults() async throws {
        _ = try packed("game.nup", title: "Vorher")
        let catalog = LibraryMetadataStore(defaults: defaults)
        let snapshot = try LibraryScanner.scan(root)
        let file = try XCTUnwrap(snapshot.entries.first).url
        catalog.load(snapshot)
        catalog.load(snapshot)
        catalog.load(snapshot)
        try await waitFor { !catalog.loading }
        XCTAssertEqual(catalog.items[file]?.title, "Vorher")
        let archive = try NUPArchive(url: file)
        try archive.saveMetadata(package: 0, changes: MetadataEdit(name: "Nachher", publisher: "", displayVersion: "", icon: nil),
            profile: .specification, destination: file, replacingOriginal: true, context: JobContext())
        catalog.update(try NUPArchive(url: file))
        try await waitFor { catalog.items[file]?.title == "Nachher" }
        XCTAssertNil(defaults.object(forKey: "libraryMetadataPolicy"))
        let other = root.appendingPathComponent("leer"); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        catalog.load(try LibraryScanner.scan(other))
        XCTAssertTrue(catalog.items.isEmpty)
        XCTAssertFalse(catalog.loading)
    }

    @MainActor func testBatchedCatalogPublishesTailAndCoverRemovalWithoutChangingOtherRows() async throws {
        _ = try packed("good.nup", title: "Vorher")
        for index in 0..<61 {
            try Data([0]).write(to: root.appendingPathComponent("bad-\(index).nup"))
        }
        let snapshot = try LibraryScanner.scan(root), catalog = LibraryMetadataStore(defaults: defaults)
        let good = try XCTUnwrap(snapshot.entries.first { $0.name == "good.nup" }).url
        let bad = try XCTUnwrap(snapshot.entries.first { $0.name.hasPrefix("bad-") }).url
        var publications = 0
        let subscription = catalog.$revision.sink { _ in publications += 1 }
        defer { subscription.cancel() }
        catalog.load(snapshot)
        try await waitFor { !catalog.loading }
        XCTAssertEqual(catalog.completed, 62)
        XCTAssertEqual(catalog.items.count, 62)
        XCTAssertEqual(catalog.items[good]?.title, "Vorher")
        XCTAssertNotNil(catalog.cover(for: good))
        XCTAssertTrue(snapshot.entries.filter { $0.url != good }.allSatisfy { catalog.items[$0.url]?.notice != nil })
        print("Library catalog: \(publications) publications for 62 entries")
        let goodID = catalog.items[good]?.id, badID = catalog.items[bad]?.id
        let archive = try NUPArchive(url: good)
        try archive.saveMetadata(package: 0, changes: MetadataEdit(name: "Nachher", publisher: "", displayVersion: "", icon: nil, removeIcon: true),
                                 profile: .specification, destination: good, replacingOriginal: true, context: JobContext())
        catalog.update(try NUPArchive(url: good))
        try await waitFor { catalog.items[good]?.title == "Nachher" }
        XCTAssertNotEqual(catalog.items[good]?.id, goodID)
        XCTAssertEqual(catalog.items[bad]?.id, badID)
        XCTAssertFalse(catalog.items[good]!.hasCover)
        XCTAssertNil(catalog.cover(for: good))
    }
}
