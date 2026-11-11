import XCTest
import ImageIO
import UniformTypeIdentifiers
import Darwin
@testable import NUPStudio

extension NUPCoreTests {
    private func libraryCoverPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let output = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testLibraryCoverPreservesAllOtherMetadataPayloadAndInodeInSpecification() throws {
        let source = try fixture(), cover = try libraryCoverPNG()
        for profile in MetadataProfile.allCases {
            var options = PackOptions(); options.profile = profile; options.name = "Beibehalten"; options.publisher = "Publisher"; options.displayVersion = "7.0"
            let url = root.appendingPathComponent(profile.id + ".nup")
            try NUPWriter.pack(source: source, destination: url, options: options, context: JobContext())
            let original = try NUPArchive(url: url)
            var records = original.packages[0].metadata
            records[0x8000] = Data([0,255,7])
            records[profile.type(9)] = Data([255,1]) // Unparseable locale bytes must remain untouched.
            try MetadataTransaction.update(archive: original, package: 0, metadata: records, context: JobContext())
            let before = try NUPArchive(url: url)
            let handle = try regularFile(url)
            let payload = try before.files.map { try readRange(handle, offset: $0.offset, count: integer($0.storedSize)) }
            try handle.close()
            let after = try LibraryCoverService.save(cover, in: before, package: 0, profile: profile, context: JobContext())
            XCTAssertEqual(after.revision.inode, before.revision.inode)
            XCTAssertEqual(after.uuid, before.uuid)
            XCTAssertEqual(after.files.map(\.offset), before.files.map(\.offset))
            var expected = before.packages[0].metadata; expected[profile.type(3)] = cover
            XCTAssertEqual(after.packages[0].metadata, expected)
            XCTAssertEqual(Array(after.packages.dropFirst()).map(\.metadata), Array(before.packages.dropFirst()).map(\.metadata))
            let input = try regularFile(url)
            XCTAssertEqual(try after.files.map { try readRange(input, offset: $0.offset, count: integer($0.storedSize)) }, payload)
            try input.close()
            try after.verify(deep: true, context: JobContext())
            XCTAssertFalse(fm.fileExists(atPath: MetadataTransaction.journals(for: url).pending.path))
        }
    }

    func testLibraryCoverInvalidImageOccupiedFieldAndCancellationDoNotWrite() throws {
        var options = PackOptions(); options.displayVersion = "7.0"
        let initial = try packed(options: options), cover = try libraryCoverPNG()
        var metadata = initial.packages[0].metadata; metadata[3] = Data("Nicht-Bild-Daten".utf8)
        try MetadataTransaction.update(archive: initial, package: 0, metadata: metadata, context: JobContext())
        let archive = try NUPArchive(url: initial.url)
        let original = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try LibraryCoverService.save(Data([0]), in: archive, package: 0, profile: .specification, context: JobContext()))
        XCTAssertThrowsError(try LibraryCoverService.save(cover, in: archive, package: 0, profile: .specification, context: JobContext()))
        let cancelled = JobContext(); cancelled.cancel()
        XCTAssertThrowsError(try LibraryCoverService.save(cover, in: archive, package: 0, profile: .specification, context: cancelled))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
    }

    func testLibraryCoverRejectsChangedFileSinceDialogWasOpened() throws {
        let archive = try packed(), cover = try libraryCoverPNG()
        let output = try regularFile(archive.url, writable: true)
        try output.seekToEnd(); try output.write(contentsOf: Data([9])); try output.close()
        let changed = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try LibraryCoverService.save(cover, in: archive, package: 0, profile: .specification, context: JobContext()))
        XCTAssertEqual(try Data(contentsOf: archive.url), changed)
        XCTAssertFalse(fm.fileExists(atPath: MetadataTransaction.journals(for: archive.url).pending.path))
    }

    func testLibraryCoverOnFourGiBSparseNUPKeepsSparsePayloadAndInode() throws {
        try write("cover-sparse/romfs/a", Data("sentinel".utf8))
        let url = root.appendingPathComponent("cover-sparse.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("cover-sparse"), destination: url, options: PackOptions(), context: JobContext())
        let small = try NUPArchive(url: url), size: UInt64 = 4 * 1024 * 1024 * 1024
        let extent = small.files[0].offset, meta = try MetadataCodec.serialize(small.packages[0].metadata)
        var toc = small.toc, header = small.header
        let filePosition = 48 + small.packages.count * 64 + small.directories.count * 24
        toc.put(size, at: filePosition + 8, width: 8); toc.put(size, at: filePosition + 24, width: 8)
        toc.put(0, at: filePosition + 64, width: 1); toc.put(extent + size, at: 80, width: 8)
        header.put(extent + size + UInt64(meta.count), at: 64, width: 8); header.put(toc.sha256, at: 24)
        let output = try regularFile(url, writable: true)
        try output.truncate(atOffset: extent + size + UInt64(meta.count))
        try output.seek(toOffset: extent + size); try output.write(contentsOf: meta)
        try output.seek(toOffset: 128); try output.write(contentsOf: toc)
        try output.seek(toOffset: 0); try output.write(contentsOf: header); try output.close()
        let before = try NUPArchive(url: url)
        let after = try LibraryCoverService.save(libraryCoverPNG(), in: before, package: 0, profile: .specification, context: JobContext())
        XCTAssertEqual(after.revision.inode, before.revision.inode)
        XCTAssertEqual(after.files[0].offset, extent)
        let input = try regularFile(url); var info = stat()
        XCTAssertEqual(fstat(input.fileDescriptor, &info), 0)
        XCTAssertLessThan(Int64(info.st_blocks) * 512, 1024 * 1024)
        XCTAssertEqual(try readRange(input, offset: extent, count: 8), Data("sentinel".utf8)); try input.close()
        // This structure-only sparse fixture intentionally has no recomputed 4-GiB payload hash.
    }

    func testLibraryCoverLoadsOriginalImageAndRejectsInvalidImageFile() throws {
        let cover = try libraryCoverPNG(), url = try write("cover.png", cover)
        let selection = try LibraryCoverService.loadImage(url)
        XCTAssertEqual(selection.data, cover)
        XCTAssertNotNil(LibraryMetadataReader.makeThumbnail(selection.thumbnail))
        XCTAssertThrowsError(try LibraryCoverService.loadImage(write("invalid.png", Data([0]))))
    }

    @MainActor func testLibraryCoverSaveStaysInLibraryAndRefreshesRow() async throws {
        let archive = try packed(), cover = try libraryCoverPNG()
        let suite = "NUPLibraryCoverTests-\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(defaults: defaults)
        func completed() async throws {
            let deadline = Date().addingTimeInterval(5)
            while store.busy {
                if Date() > deadline { throw NUPError("Cover-Vorgang wurde nicht beendet.") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        store.scanLibrary(root); try await completed()
        let url = try XCTUnwrap(store.library?.entries.first(where: { $0.name == archive.url.lastPathComponent })?.url)
        store.requestLibraryCover(url); try await completed()
        let draft = try XCTUnwrap(store.libraryCoverDraft)
        store.saveLibraryCover(draft, package: draft.packageIndex, cover: cover)
        try await completed()
        XCTAssertEqual(store.section, .library)
        XCTAssertNil(store.libraryCoverDraft)
        XCTAssertNil(store.libraryCoverError)
        XCTAssertNil(store.archive)
        XCTAssertEqual(store.library?.entries.first(where: { $0.url == url })?.size, Int64(try NUPArchive(url: url).fileSize))
        let deadline = Date().addingTimeInterval(5)
        while store.libraryMetadata.items[url]?.hasCover != true {
            if Date() > deadline { throw NUPError("Cover-Vorschau wurde nicht aktualisiert.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(store.libraryMetadata.cover(for: url))
    }
}
