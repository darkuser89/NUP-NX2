import XCTest
import Darwin
@testable import NUPStudio

final class NUPCoreTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("NUPStudioTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    @discardableResult
    func write(_ relative: String, _ data: Data = Data("hello".utf8)) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }
    func fixture() throws -> URL {
        let compressed = Data(repeating: 65, count: 3 * 1024 * 1024 + 133)
        try write("dump/base/romfs/large.bin", compressed)
        try write("dump/base/romfs/duplicate.bin", compressed)
        try write("dump/base/romfs/empty", Data())
        try write("dump/base/romfs/.listing", Data("skip".utf8))
        try write("dump/base/romfs/日本語.txt", Data("Grüße 🌍".utf8))
        var raw = Data()
        var state: UInt64 = 0x123456789abcdef
        for _ in 0..<4096 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; raw.append(UInt8(truncatingIfNeeded: state)) }
        try write("dump/base/romfs/raw.bin", raw)
        var npdm = Data(count: 128)
        npdm.put(Data("ACI0".utf8), at: 32)
        npdm.put(0x040074A01BF12000, at: 48, width: 8)
        try write("dump/base/exefs/main.npdm", npdm)
        var main = Data(count: 96)
        main.put(Data("NSO0".utf8), at: 0)
        main.put(Data(repeating: 0x42, count: 32), at: 64)
        try write("dump/base/exefs/main", main)
        try write("dump/updates/458752/romfs/update", Data("patch".utf8))
        try write("dump/dlc/040074a01bf13001/0/romfs/dlc", Data("addon".utf8))
        return root.appendingPathComponent("dump")
    }
    func packed(options: PackOptions = PackOptions()) throws -> NUPArchive {
        let source = try fixture()
        let output = root.appendingPathComponent("game.nup")
        try NUPWriter.pack(source: source, destination: output, options: options, context: JobContext())
        return try NUPArchive(url: output)
    }
    func mutate(_ archive: NUPArchive, _ change: (inout Data) throws -> Void) throws -> URL {
        var data = try Data(contentsOf: archive.url)
        var toc = archive.toc
        try change(&toc)
        data.put(toc, at: 128)
        data.put(toc.sha256, at: 24)
        let url = root.appendingPathComponent("mutated.nup")
        try data.write(to: url)
        return url
    }

    func testRoundTripCompressionDedupAndPackages() throws {
        var options = PackOptions()
        options.name = "Swift-Test"; options.publisher = "Test"; options.displayVersion = "7.0"
        let archive = try packed(options: options)
        XCTAssertEqual(archive.packages.map(\.kind), [0, 1, 2])
        XCTAssertEqual(archive.packages[0].titleIDString, "040074A01BF12000")
        XCTAssertEqual(archive.packages[1].version, 458752)
        XCTAssertEqual(archive.packages[2].titleIDString, "040074A01BF13001")
        XCTAssertEqual(archive.packages[0].text(5, profile: .specification), "Swift-Test")
        XCTAssertFalse(archive.files.contains { $0.name == ".listing" })
        let large = try XCTUnwrap(archive.files.first { $0.name == "large.bin" })
        let duplicate = try XCTUnwrap(archive.files.first { $0.name == "duplicate.bin" })
        XCTAssertEqual(large.codec, 1)
        XCTAssertEqual(large.offset, duplicate.offset)
        XCTAssertEqual(archive.files.first { $0.name == "raw.bin" }?.codec, 0)
        try archive.verify(deep: true, context: JobContext())
        let target = root.appendingPathComponent("unpacked")
        try archive.extract(package: 0, subtree: nil, destination: target, context: JobContext())
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("romfs/large.bin")), Data(repeating: 65, count: 3 * 1024 * 1024 + 133))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("romfs/日本語.txt")), Data("Grüße 🌍".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("romfs/empty")), Data())
    }
    func testSpecificationProfileAndLocalizedMetadata() throws {
        var options = PackOptions()
        options.profile = .specification; options.name = "Spec"
        options.localizedTitles = ["ja": "テスト", "de": "Prüfung"]
        options.localizedIcons = ["ja": Data([1, 2, 3])]
        let archive = try packed(options: options)
        XCTAssertEqual(archive.packages[0].text(5, profile: .specification), "Spec")
        let names = try MetadataCodec.localized(XCTUnwrap(archive.packages[0].metadata[9]))
        XCTAssertEqual(names["ja"], Data("テスト".utf8))
        XCTAssertEqual(archive.packages[0].metadata[7], Data(repeating: 0x42, count: 32))
        try archive.verify(deep: true, context: JobContext())
    }
    func testMetadataEditPreservesExtentsAndUnknownRecords() throws {
        let archive = try packed()
        var extended = archive
        extended.packages[0].metadata[0x8000] = Data([7, 8, 9])
        let target = root.appendingPathComponent("edited.nup")
        let changes = MetadataEdit(name: "Edited", publisher: "Publisher", displayVersion: "1.2.3", icon: nil,
                                   localizedTitles: ["de": "Geändert"])
        try extended.saveMetadata(package: 0, changes: changes, profile: .specification, destination: target, context: JobContext())
        let result = try NUPArchive(url: target)
        XCTAssertEqual(result.uuid, archive.uuid)
        XCTAssertEqual(result.files.map(\.offset), archive.files.map(\.offset))
        XCTAssertEqual(result.files.map(\.hash), archive.files.map(\.hash))
        XCTAssertEqual(result.packages[0].metadata[0x8000], Data([7, 8, 9]))
        XCTAssertEqual(result.packages[0].text(5, profile: .specification), "Edited")
        try result.verify(deep: true, context: JobContext())
    }
    func testMetadataCanReplaceOriginalWithoutChangingContent() throws {
        var options = PackOptions(); options.profile = .specification; options.name = "Original"
        let first = try packed(options: options)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: first.url.path)
        let attribute = Data("finder-test".utf8)
        let attributeResult = attribute.withUnsafeBytes {
            setxattr(first.url.path, "de.local.nupstudio.test", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(attributeResult, 0)
        let archive = try NUPArchive(url: first.url)
        let originalBytes = try Data(contentsOf: archive.url)
        let changes = MetadataEdit(name: "Aktualisiert", publisher: "Native", displayVersion: "2.3", icon: nil,
                                   localizedTitles: ["de": "Neuer Titel"])
        try archive.saveMetadata(package: 1, changes: changes, profile: .specification,
                                 destination: archive.url, replacingOriginal: true, context: JobContext())
        let result = try NUPArchive(url: archive.url)
        XCTAssertEqual(result.url, archive.url)
        XCTAssertEqual(result.revision.inode, archive.revision.inode)
        XCTAssertEqual(result.packages[0].metadata, archive.packages[0].metadata)
        XCTAssertEqual(result.packages[1].text(5, profile: .specification), "Aktualisiert")
        XCTAssertEqual(result.uuid, archive.uuid)
        XCTAssertEqual(result.files.map(\.offset), archive.files.map(\.offset))
        let updatedBytes = try Data(contentsOf: result.url)
        for file in archive.files where file.storedSize > 0 {
            XCTAssertEqual(try updatedBytes.bytes(Int(file.offset), Int(file.storedSize)),
                           try originalBytes.bytes(Int(file.offset), Int(file.storedSize)))
        }
        XCTAssertEqual(result.revision.permissions, 0o640)
        var restoredAttribute = Data(count: attribute.count)
        let restoredCount = restoredAttribute.withUnsafeMutableBytes {
            getxattr(result.url.path, "de.local.nupstudio.test", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(restoredCount, attribute.count)
        XCTAssertEqual(restoredAttribute, attribute)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-metadata-") })
        try result.verify(deep: true, context: JobContext())
    }
    func testCancellingMetadataReplacementKeepsOriginal() throws {
        final class Holder: @unchecked Sendable { var job: JobContext? }
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let holder = Holder()
        let context = JobContext { _, _ in holder.job?.cancel() }
        holder.job = context; defer { holder.job = nil }
        let changes = MetadataEdit(name: "Cancelled", publisher: "", displayVersion: "", icon: nil)
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: archive.url, replacingOriginal: true, context: context))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-edit-") })
    }
    func testMetadataReplacementRejectsStaleArchive() throws {
        let archive = try packed()
        var external = try Data(contentsOf: archive.url)
        external[external.count - 1] ^= 1
        try external.write(to: archive.url)
        let changes = MetadataEdit(name: "Stale", publisher: "", displayVersion: "", icon: nil)
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: archive.url, replacingOriginal: true, context: JobContext()))
        XCTAssertEqual(try Data(contentsOf: archive.url), external)
    }
    func testMetadataReplacementPreservesConcurrentExternalChange() throws {
        let archive = try packed()
        let source = archive.url
        let external = try Data(contentsOf: source) + Data([1])
        let context = JobContext { _, _ in try? external.write(to: source) }
        let changes = MetadataEdit(name: "Conflict", publisher: "", displayVersion: "", icon: nil)
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: source, replacingOriginal: true, context: context))
        XCTAssertEqual(try Data(contentsOf: source), external)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-edit-") })
    }
    func testMetadataSaveAsStillRefusesOverwrite() throws {
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        let changes = MetadataEdit(name: "No overwrite", publisher: "", displayVersion: "", icon: nil)
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: archive.url, context: JobContext()))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let different = root.appendingPathComponent("other.nup")
        XCTAssertThrowsError(try archive.saveMetadata(package: 0, changes: changes, profile: .specification,
                                                      destination: different, replacingOriginal: true, context: JobContext()))
        XCTAssertFalse(fm.fileExists(atPath: different.path))
    }
    func testEmptyBaseBecomesStandaloneUpdate() throws {
        try fm.createDirectory(at: root.appendingPathComponent("only/base"), withIntermediateDirectories: true)
        try write("only/updates/65536/romfs/file")
        let output = root.appendingPathComponent("only.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("only"), destination: output, options: PackOptions(), context: JobContext())
        let archive = try NUPArchive(url: output)
        XCTAssertEqual(archive.packages.count, 1)
        XCTAssertEqual(archive.packages[0].kind, 1)
        XCTAssertEqual(archive.packages[0].flags, 1)
    }
    func testTitleIDOverrideAndSubtreeExtraction() throws {
        var options = PackOptions(); options.titleID = "0100123456789000"; options.keepListings = true
        let archive = try packed(options: options)
        XCTAssertEqual(archive.packages[0].titleIDString, options.titleID)
        XCTAssertTrue(archive.files.contains { $0.name == ".listing" })
        let target = root.appendingPathComponent("romfs")
        try archive.extract(package: 0, subtree: "romfs", destination: target, context: JobContext())
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("large.bin").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("exefs").path))
    }
    func testRejectsTOCHashMismatch() throws {
        let archive = try packed()
        var data = try Data(contentsOf: archive.url); data[140] ^= 1
        let url = try write("bad-hash.nup", data)
        XCTAssertThrowsError(try NUPArchive(url: url)) { XCTAssertTrue($0.localizedDescription.contains("TOC-SHA-256")) }
    }
    func testAcceptsTOCPaddingAfterDeclaredStringPool() throws {
        try write("padding/romfs/a", Data("payload".utf8))
        let output = root.appendingPathComponent("padding.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("padding"), destination: output, options: PackOptions(), context: JobContext())
        let original = try NUPArchive(url: output)
        let paddedSize = Int(original.blobOffset) - 128
        XCTAssertGreaterThan(paddedSize, original.toc.count)
        var data = try Data(contentsOf: output)
        let paddedTOC = try data.bytes(128, paddedSize)
        data.put(UInt64(paddedSize), at: 16, width: 8)
        data.put(paddedTOC.sha256, at: 24)
        try data.write(to: output)
        let padded = try NUPArchive(url: output)
        XCTAssertEqual(padded.files.map(\.hash), original.files.map(\.hash))
        try padded.verify(deep: true, context: JobContext())
        let invalid = try mutate(padded) { toc in
            let poolOffset = try toc.uint(24, 8)
            toc.put(UInt64(toc.count) - poolOffset + 1, at: 32, width: 8)
        }
        XCTAssertThrowsError(try NUPArchive(url: invalid))
    }
    func testRejectsTruncationAndOverflow() throws {
        let archive = try packed()
        var data = try Data(contentsOf: archive.url)
        data.removeLast()
        XCTAssertThrowsError(try NUPArchive(url: write("truncated.nup", data)))
        let url = try mutate(archive) { $0.put(UInt64.max, at: 8, width: 8) }
        XCTAssertThrowsError(try NUPArchive(url: url))
    }
    func testRejectsTraversalLabel() throws {
        let archive = try packed()
        let url = try mutate(archive) { toc in
            let pool = try integer(toc.uint(24, 8))
            let filePosition = 48 + archive.packages.count * 64 + archive.directories.count * 24
            let nameOffset = try integer(toc.uint(filePosition, 4))
            toc.put(Data("../".utf8), at: pool + nameOffset)
        }
        XCTAssertThrowsError(try NUPArchive(url: url))
    }
    func testRejectsCycleAndOutOfRangeChild() throws {
        let archive = try packed()
        let start = 48 + archive.packages.count * 64 + archive.directories.count * 24 + archive.files.count * 80
        let cycle = try mutate(archive) { $0.put(0, at: start, width: 4) }
        XCTAssertThrowsError(try NUPArchive(url: cycle))
        let outOfRange = try mutate(archive) { $0.put(UInt64(UInt32.max), at: start, width: 4) }
        XCTAssertThrowsError(try NUPArchive(url: outOfRange))
    }
    func testRejectsUnknownCodecAndOverlappingExtent() throws {
        let archive = try packed()
        let start = 48 + archive.packages.count * 64 + archive.directories.count * 24
        let codec = try mutate(archive) { $0.put(99, at: start + 64, width: 1) }
        XCTAssertThrowsError(try NUPArchive(url: codec))
        let rawIndex = try XCTUnwrap(archive.files.firstIndex { $0.name == "raw.bin" })
        let overlap = try mutate(archive) { toc in
            toc.put(archive.blobOffset, at: start + rawIndex * 80 + 16, width: 8)
        }
        XCTAssertThrowsError(try NUPArchive(url: overlap))
    }
    func testDeepVerificationFindsCorruptionAndExtractionRollsBack() throws {
        let archive = try packed()
        let raw = try XCTUnwrap(archive.files.first { $0.name == "raw.bin" })
        let handle = try FileHandle(forUpdating: archive.url)
        try handle.seek(toOffset: raw.offset)
        let data = try readExactly(handle, 1)
        try handle.seek(toOffset: raw.offset)
        try handle.write(contentsOf: Data([data[0] ^ 255])); try handle.close()
        try archive.verify(deep: false, context: JobContext())
        XCTAssertThrowsError(try archive.verify(deep: true, context: JobContext()))
        let destination = root.appendingPathComponent("must-not-exist")
        XCTAssertThrowsError(try archive.extract(package: 0, subtree: nil, destination: destination, context: JobContext()))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-extract-") })
    }
    func testCancellationCleansOutput() throws {
        let source = try fixture()
        let context = JobContext(); context.cancel()
        let output = root.appendingPathComponent("cancel.nup")
        XCTAssertThrowsError(try NUPWriter.pack(source: source, destination: output, options: PackOptions(), context: context))
        XCTAssertFalse(fm.fileExists(atPath: output.path))
    }
    func testNeverOverwritesExistingFilesOrFolders() throws {
        let archive = try packed()
        let original = try Data(contentsOf: archive.url)
        XCTAssertThrowsError(try NUPWriter.pack(source: root.appendingPathComponent("dump"), destination: archive.url, options: PackOptions(), context: JobContext()))
        XCTAssertEqual(try Data(contentsOf: archive.url), original)
        let folder = root.appendingPathComponent("existing")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try archive.extract(package: 0, subtree: nil, destination: folder, context: JobContext()))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.path), [])
    }
    func testRejectsOutputInsideSourceAndSymbolicLinks() throws {
        let source = try fixture()
        XCTAssertThrowsError(try NUPWriter.pack(source: source, destination: source.appendingPathComponent("inside.nup"), options: PackOptions(), context: JobContext()))
        try fm.createSymbolicLink(at: source.appendingPathComponent("base/romfs/link"), withDestinationURL: root.appendingPathComponent("dump/base/romfs/raw.bin"))
        XCTAssertThrowsError(try NUPWriter.pack(source: source, destination: root.appendingPathComponent("link.nup"), options: PackOptions(), context: JobContext()))
    }
    func testLocalizedRecordsRejectMalformedAndDuplicateTags() throws {
        XCTAssertThrowsError(try MetadataCodec.localized(Data([2, 100])))
        XCTAssertThrowsError(try MetadataCodec.localizedData(["DE": Data([1]), "de": Data([2])]))
        let encoded = try MetadataCodec.localizedData(["de": Data("Titel".utf8)])
        XCTAssertThrowsError(try MetadataCodec.localized(encoded + encoded))
    }
    func testDeterministicPacking() throws {
        let archive = try packed()
        let second = root.appendingPathComponent("second.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("dump"), destination: second, options: PackOptions(), context: JobContext())
        XCTAssertEqual(try Data(contentsOf: archive.url), try Data(contentsOf: second))
    }
    func testCompressedDataAcrossMultipleInputAndOutputChunks() throws {
        var seed: UInt64 = 0x987654321
        var block = Data()
        for _ in 0..<(2 * 1024 * 1024) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            block.append(UInt8(truncatingIfNeeded: seed))
        }
        let first = Data(block.prefix(1024 * 1024))
        let second = Data(block.suffix(1024 * 1024))
        let data = first + first + second + second
        try write("stream/romfs/mixed.bin", data)
        let target = root.appendingPathComponent("stream.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("stream"), destination: target, options: PackOptions(), context: JobContext())
        let archive = try NUPArchive(url: target)
        XCTAssertEqual(archive.files[0].codec, 1)
        XCTAssertGreaterThan(archive.files[0].storedSize, UInt64(StreamCodec.chunkSize))
        let extracted = root.appendingPathComponent("stream-output")
        try archive.extract(package: 0, subtree: nil, destination: extracted, context: JobContext())
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("romfs/mixed.bin")), data)
    }
    func testCaseCollisionIsRejectedBeforeExtraction() throws {
        try write("case/romfs/A.txt", Data("upper".utf8))
        try write("case/romfs/B.txt", Data("lower".utf8))
        let output = root.appendingPathComponent("case.nup")
        try NUPWriter.pack(source: root.appendingPathComponent("case"), destination: output, options: PackOptions(), context: JobContext())
        let archive = try NUPArchive(url: output)
        let mutated = try mutate(archive) { toc in
            let pool = try integer(toc.uint(24, 8))
            let start = 48 + archive.packages.count * 64 + archive.directories.count * 24
            let index = try XCTUnwrap(archive.files.firstIndex { $0.name == "B.txt" })
            let offset = try integer(toc.uint(start + index * 80, 4))
            toc.put(Data("a.txt".utf8), at: pool + offset)
        }
        let colliding = try NUPArchive(url: mutated)
        let destination = root.appendingPathComponent("collision")
        XCTAssertThrowsError(try colliding.extract(package: 0, subtree: nil, destination: destination, context: JobContext()))
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }
    func testCancellationAfterTemporaryFileCreationCleansPartialFile() throws {
        final class Holder: @unchecked Sendable { var job: JobContext? }
        let holder = Holder()
        let context = JobContext { _, _ in holder.job?.cancel() }
        holder.job = context
        defer { holder.job = nil }
        let source = try fixture()
        let output = root.appendingPathComponent("cancel-midway.nup")
        XCTAssertThrowsError(try NUPWriter.pack(source: source, destination: output, options: PackOptions(), context: context))
        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".nup-") })
    }
}
