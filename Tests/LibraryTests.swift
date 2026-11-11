import XCTest
@testable import NUPStudio

final class LibraryTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("NUPLibraryTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    @discardableResult private func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Invalid NUP bytes prove the scanner does not parse containers or load covers.
        try Data([7]).write(to: url)
        return url
    }

    func testRecursiveScanIncludesUppercaseHiddenAndDuplicateNames() throws {
        try file("Basis.nup"); try file("Updates/Spiel.NUP"); try file("DLC/Spiel.nup")
        try file(".versteckt/Geheim.nup"); try file("ignorieren.nup.txt")
        let snapshot = try LibraryScanner.scan(root)
        XCTAssertEqual(snapshot.entries.count, 4)
        XCTAssertEqual(Set(snapshot.entries.map(\.relativePath)), ["Basis.nup", "Updates/Spiel.NUP", "DLC/Spiel.nup", ".versteckt/Geheim.nup"])
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.size == 1 })
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testSymlinksAreSkippedWithoutFollowingDirectoryLoops() throws {
        let target = try file("A.nup")
        try fm.createSymbolicLink(at: root.appendingPathComponent("Link.nup"), withDestinationURL: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("Loop"), withDestinationURL: root)
        try fm.createDirectory(at: root.appendingPathComponent("Ordner.nup"), withIntermediateDirectories: true)
        XCTAssertEqual(try LibraryScanner.scan(root).entries.map(\.relativePath), ["A.nup"])
    }

    func testNaturalSortAndNameOrPathSearch() throws {
        try file("Spiel 10.nup"); try file("Spiel 2.nup"); try file("Updates/Öffnen.NUP")
        let snapshot = try LibraryScanner.scan(root)
        XCTAssertEqual(snapshot.entries.prefix(2).map(\.name), ["Spiel 2.nup", "Spiel 10.nup"])
        XCTAssertEqual(snapshot.matching("OFFNEN").map(\.name), ["Öffnen.NUP"])
        XCTAssertEqual(snapshot.matching("UPDATES/").count, 1)
        XCTAssertEqual(snapshot.matching("  ").count, 3)
        XCTAssertTrue(snapshot.matching("nicht vorhanden").isEmpty)
    }

    func testRefreshSeesAddedAndRemovedFiles() throws {
        let a = try file("A.nup")
        let first = try LibraryScanner.scan(root)
        try fm.removeItem(at: a); try file("B.nup")
        let second = try LibraryScanner.scan(root)
        XCTAssertEqual(first.entries.map(\.name), ["A.nup"])
        XCTAssertEqual(second.entries.map(\.name), ["B.nup"])
        XCTAssertNotEqual(first.id, second.id)
    }

    func testEmptyFolderInvalidRootAndCancellation() throws {
        XCTAssertTrue(try LibraryScanner.scan(root).entries.isEmpty)
        let invalid = try file("a.nup")
        XCTAssertThrowsError(try LibraryScanner.scan(invalid))
        let context = JobContext(); context.cancel()
        XCTAssertThrowsError(try LibraryScanner.scan(root, context: context)) { XCTAssertTrue($0 is CancellationError) }
    }

    func testBinaryReadsAreUnalignedLittleEndianAndBoundsChecked() throws {
        let data = Data([255,1,2,3,4,5,6,7,8,9])
        XCTAssertEqual(try data.uint(1, 8), 0x0807060504030201)
        XCTAssertEqual(try data.uint(1, 4), 0x04030201)
        XCTAssertEqual(try data.uint(3, 2), 0x0403)
        XCTAssertEqual(try data.uint(1, 3), 0x030201)
        let slice = data[1..<9]
        XCTAssertEqual(try slice.uint(0, 8), 0x0807060504030201)
        for (offset, width) in [(-1,1),(0,0),(0,9),(Int.max,8),(9,2)] {
            XCTAssertThrowsError(try data.uint(offset, width))
        }
        XCTAssertTrue(try Data([9,0,0,9]).isZero(1, 2))
        XCTAssertFalse(try data.isZero(1, 2))
        XCTAssertThrowsError(try data.isZero(Int.max, 1))
    }

    func testTreeCacheBuildsOnlyOncePerPackageAndKeepsValueSemantics() {
        let cache = BrowserTreeCache()
        var builds = 0
        func build() -> [BrowserNode] { builds += 1; return [BrowserNode(id: 0, name: "Original")] }
        var first = cache.nodes(package: 0, build: build)
        first[0].name = "Lokale Kopie"
        XCTAssertEqual(cache.nodes(package: 0, build: build)[0].name, "Original")
        XCTAssertEqual(builds, 1)
        _ = cache.nodes(package: 1, build: build)
        XCTAssertEqual(builds, 2)
    }

    func testTreeSearchKeepsAncestorsAndWholeMatchingDirectories() {
        let tree = [BrowserNode(id: 0, name: "romfs", children: [BrowserNode(id: 1, name: "Treffer.bin"), BrowserNode(id: 2, name: "Andere.bin")])]
        XCTAssertEqual(BrowserTreeSearch.matching(tree, query: "TREFFER").first?.children?.map(\.name), ["Treffer.bin"])
        XCTAssertEqual(BrowserTreeSearch.matching(tree, query: "ROMFS").first?.children?.count, 2)
        XCTAssertTrue(BrowserTreeSearch.matching(tree, query: "xyz").isEmpty)
    }
}
