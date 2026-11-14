import XCTest
@testable import NUPStudio

extension NUPCoreTests {
    func testIndexedLocationsMatchEveryPackageAndRejectForeignNodes() throws {
        let source = try fixture()
        try write("dump/base/romfs/日本語/深い/leaf.bin")
        let url = root.appendingPathComponent("locations.nup")
        try NUPWriter.pack(source: source, destination: url, options: PackOptions(), context: JobContext())
        let archive = try NUPArchive(url: url)
        for package in archive.packages {
            var stack = [(package.root, "/")]
            while let (directory, path) = stack.popLast() {
                XCTAssertEqual(archive.fileLocation(node: directory, package: package.id)?.path, path)
                XCTAssertEqual(archive.fileLocation(node: directory, package: package.id)?.directory, directory)
                for other in archive.packages where other.id != package.id {
                    XCTAssertNil(archive.fileLocation(node: directory, package: other.id))
                }
                for child in archive.directories[directory].children {
                    if child < archive.directories.count {
                        stack.append((child, (path == "/" ? path : path + "/") + archive.directories[child].name))
                    } else {
                        XCTAssertEqual(archive.fileLocation(node: child, package: package.id)?.directory, directory)
                        XCTAssertEqual(archive.fileLocation(node: child, package: package.id)?.path, path)
                        XCTAssertTrue(archive.owns(node: child, package: package.id))
                    }
                }
            }
        }
        for node in [-1, archive.directories.count + archive.files.count, Int.max] {
            XCTAssertNil(archive.fileLocation(node: node, package: 0))
        }
        XCTAssertNil(archive.fileLocation(node: 0, package: -1))
        XCTAssertNil(archive.fileLocation(node: 0, package: archive.packages.count))
    }

    func testRegionValidationRejectsConflictingSharedExtentsAndMetadataOverlap() throws {
        let archive = try packed()
        let shared = try XCTUnwrap(archive.files.firstIndex { $0.name == "duplicate.bin" })
        let start = 48 + archive.packages.count * 64 + archive.directories.count * 24
        for field in [8, 32] {
            let changed = try mutate(archive) { toc in
                let at = start + shared * 80 + field
                if field == 8 { toc.put(archive.files[shared].size + 1, at: at, width: 8) }
                else { toc[at] ^= 1 }
            }
            XCTAssertThrowsError(try NUPArchive(url: changed))
        }
        let meta = archive.packages[0]
        XCTAssertGreaterThan(meta.metaSize, 0)
        let overlap = try mutate(archive) { toc in
            let at = start + shared * 80
            toc.put(UInt64(meta.metaSize), at: at + 8, width: 8)
            toc.put(meta.metaOffset, at: at + 16, width: 8)
            toc.put(UInt64(meta.metaSize), at: at + 24, width: 8)
            toc.put(0, at: at + 64, width: 1)
        }
        XCTAssertThrowsError(try NUPArchive(url: overlap))
        try archive.verify(deep: true, context: JobContext())
    }

    func testLargeTOCIndexedLookupsAndRemovalKeepSharedDataAndPackageOwnership() throws {
        let archive = try packed(), directory = try XCTUnwrap(archive.packages[0].romfs)
        let payload = Data([7]), count = 10_000
        let additions = (0..<count).map {
            NUPFile(name: String(format: "bulk-%05d.bin", $0), size: 1, offset: 0,
                    storedSize: 1, hash: payload.sha256, codec: 0)
        }
        let stage = try regularFile(write("stage.bin", payload)), input = try regularFile(archive.url)
        let output = try regularFile(archive.url, writable: true)
        let plan = try ArchiveFilePlan(archive: archive, package: 0, directory: directory,
                                      additions: additions, stageSize: 1, removing: [])
        _ = try plan.appendPayloads(input: input, output: output, stage: stage, context: JobContext())
        try plan.writeTOC(to: output); try plan.writeHeader(to: output)
        try stage.close(); try input.close(); try output.close()
        let clock = ContinuousClock(), parseStart = clock.now
        let large = try NUPArchive(url: archive.url)
        print("Large TOC (10,000 added files), parse: \(parseStart.duration(to: clock.now))")
        XCTAssertEqual(large.files.count, archive.files.count + count)
        let lookupStart = clock.now
        for file in stride(from: archive.files.count, to: large.files.count, by: 5) {
            let node = large.directories.count + file
            XCTAssertEqual(large.fileLocation(node: node, package: 0)?.path, "/romfs")
            XCTAssertEqual(large.fileLocation(node: node, package: 0)?.directory, directory)
            XCTAssertNil(large.fileLocation(node: node, package: 1))
        }
        print("Large TOC, 6,000 indexed lookups: \(lookupStart.duration(to: clock.now))")
        let updated = try large.editFiles(package: 0, directory: directory,
                                         removing: [archive.files.count, large.files.count - 1])
        XCTAssertEqual(updated.files.count, large.files.count - 2)
        XCTAssertFalse(updated.files.contains { $0.name == "bulk-00000.bin" || $0.name == "bulk-09999.bin" })
        let kept = try XCTUnwrap(updated.files.firstIndex { $0.name == "bulk-05000.bin" })
        XCTAssertEqual(updated.files[kept].offset, large.files[archive.files.count].offset)
        XCTAssertEqual(updated.fileLocation(node: updated.directories.count + kept, package: 0)?.path, "/romfs")
        try updated.verify(deep: true, context: JobContext())
    }
}
