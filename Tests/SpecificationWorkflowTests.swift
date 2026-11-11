import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import NUPStudio

extension NUPCoreTests {
    private func specificationCover() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let output = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testDefaultWriterUsesEverySpecificationMetadataIdentifier() throws {
        var options = PackOptions()
        XCTAssertEqual(options.profile, .specification)
        XCTAssertEqual(MetadataProfile.allCases, [.specification])
        options.name = "Spielname"; options.publisher = "Publisher"; options.displayVersion = "3.2.0"
        options.icon = try specificationCover()
        options.localizedTitles = ["de": "Deutscher Titel"]
        options.localizedIcons = ["de": try specificationCover()]
        let archive = try packed(options: options), metadata = archive.packages[0].metadata
        XCTAssertNil(metadata[0])
        XCTAssertNotNil(metadata[1]) // NPDM
        XCTAssertEqual(metadata[3], options.icon)
        XCTAssertEqual(metadata[4], Data("3.2.0".utf8))
        XCTAssertEqual(metadata[5], Data("Spielname".utf8))
        XCTAssertEqual(metadata[6], Data("Publisher".utf8))
        XCTAssertEqual(metadata[7], Data(repeating: 0x42, count: 32))
        XCTAssertNotNil(metadata[8]) // Source
        XCTAssertEqual(try MetadataCodec.localized(XCTUnwrap(metadata[9]))["de"], Data("Deutscher Titel".utf8))
        XCTAssertEqual(try MetadataCodec.localized(XCTUnwrap(metadata[10]))["de"], options.localizedIcons["de"])
        XCTAssertEqual(LibraryMetadataReader.metadata(from: archive.packages).item.title, "Spielname")
        try archive.verify(deep: true, context: JobContext())
    }

    @MainActor func testStalePythonPreferencesCannotChangeAnyAppDefault() throws {
        let suite = "NUPSpecPreferences-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Python-Referenz", forKey: "libraryMetadataPolicy")
        let store = WorkspaceStore(defaults: defaults)
        XCTAssertEqual(store.profile, .specification)
        XCTAssertEqual(store.options.profile, .specification)
        XCTAssertNil(defaults.object(forKey: "libraryMetadataPolicy"))
        defaults.set("Automatisch", forKey: "libraryMetadataPolicy")
        _ = WorkspaceStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "libraryMetadataPolicy"))
    }

    @MainActor func testAppOpenEditLibraryAndCoverAllUseSpecificationDespiteTypeZeroRecord() async throws {
        var options = PackOptions(); options.name = "Spec-Spiel"; options.publisher = "Spec-Publisher"; options.displayVersion = "3.2.0"
        let initial = try packed(options: options)
        var metadata = initial.packages[0].metadata; metadata[0] = Data([7])
        try MetadataTransaction.update(archive: initial, package: 0, metadata: metadata, context: JobContext())
        let suite = "NUPSpecWorkflow-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("Python-Referenz", forKey: "libraryMetadataPolicy")
        let store = WorkspaceStore(defaults: defaults)
        func completed() async throws {
            let deadline = Date().addingTimeInterval(5)
            while store.busy {
                if Date() > deadline { throw NUPError("Spec-Vorgang wurde nicht beendet.") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.open(initial.url); try await completed()
        XCTAssertEqual(store.profile, .specification)
        XCTAssertEqual(store.archive?.packages[0].text(5, profile: store.profile), "Spec-Spiel")
        XCTAssertEqual(store.archive?.packages[0].text(6, profile: store.profile), "Spec-Publisher")
        store.scanLibrary(root); try await completed()
        let url = try XCTUnwrap(store.library?.entries.first(where: { $0.name == "game.nup" })?.url)
        let deadline = Date().addingTimeInterval(5)
        while store.libraryMetadata.loading {
            if Date() > deadline { throw NUPError("Spec-Bibliothek wurde nicht geladen.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(store.libraryMetadata.items[url]?.title, "Spec-Spiel")
        store.open(url); try await completed()
        store.save(changes: MetadataEdit(name: "Bearbeitet", publisher: "Publisher neu", displayVersion: "4.0", icon: nil), replacingOriginal: true)
        try await completed()
        let edited = try NUPArchive(url: url)
        XCTAssertEqual(edited.packages[0].metadata[0], Data([7]))
        XCTAssertEqual(edited.packages[0].metadata[4], Data("4.0".utf8))
        XCTAssertEqual(edited.packages[0].metadata[5], Data("Bearbeitet".utf8))
        XCTAssertEqual(edited.packages[0].metadata[6], Data("Publisher neu".utf8))
        store.section = .library
        store.requestLibraryCover(url); try await completed()
        let draft = try XCTUnwrap(store.libraryCoverDraft), cover = try specificationCover()
        store.saveLibraryCover(draft, package: draft.packageIndex, cover: cover); try await completed()
        let covered = try NUPArchive(url: url)
        XCTAssertEqual(covered.revision.inode, edited.revision.inode)
        XCTAssertEqual(covered.packages[0].metadata[3], cover)
        XCTAssertEqual(covered.packages[0].metadata[4], Data("4.0".utf8))
        XCTAssertEqual(covered.packages[0].metadata[5], Data("Bearbeitet".utf8))
        XCTAssertEqual(covered.packages[0].metadata[6], Data("Publisher neu".utf8))
        XCTAssertEqual(store.section, .library)
        try covered.verify(deep: true, context: JobContext())
    }
}
