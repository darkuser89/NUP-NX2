import Foundation
import CryptoKit
import Darwin

struct NUPError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NUPError(message) }
}

extension Data {
    func bytes(_ offset: Int, _ length: Int) throws -> Data {
        try require(offset >= 0 && length >= 0 && offset <= count && length <= count - offset,
                    "Abgeschnittene oder ungültige Binärdaten.")
        return subdata(in: offset..<(offset + length))
    }
    func uint(_ offset: Int, _ width: Int) throws -> UInt64 {
        try require(offset >= 0 && width >= 1 && width <= 8 && offset <= count && width <= count - offset,
                    "Abgeschnittene oder ungültige Binärdaten.")
        return withUnsafeBytes { raw in
            switch width {
            case 1: return UInt64(raw.load(fromByteOffset: offset, as: UInt8.self))
            case 2: return UInt64(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
            case 4: return UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            case 8: return UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            default: return (0..<width).reduce(0) { $0 | UInt64(raw[offset + $1]) << ($1 * 8) }
            }
        }
    }
    func isZero(_ offset: Int, _ length: Int) throws -> Bool {
        try require(offset >= 0 && length >= 0 && offset <= count && length <= count - offset,
                    "Abgeschnittene oder ungültige Binärdaten.")
        return withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[offset..<(offset + length)].allSatisfy { $0 == 0 } }
    }
    mutating func put(_ value: UInt64, at offset: Int, width: Int) {
        precondition(offset >= 0 && offset + width <= count)
        for i in 0..<width { self[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    mutating func put(_ value: Data, at offset: Int) {
        replaceSubrange(offset..<(offset + value.count), with: value)
    }
    mutating func appendLE(_ value: UInt64, width: Int) {
        let offset = count
        append(Data(count: width))
        put(value, at: offset, width: width)
    }
    var sha256: Data { Data(SHA256.hash(data: self)) }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

func integer(_ value: UInt64) throws -> Int {
    try require(value <= UInt64(Int.max), "Ganzzahl außerhalb des unterstützten Bereichs.")
    return Int(value)
}

func aligned(_ value: UInt64) throws -> UInt64 {
    try require(value <= UInt64.max - 15, "Datei zu groß.")
    return (value + 15) & ~15
}

func bounded(_ offset: UInt64, _ size: UInt64, by limit: UInt64) throws {
    try require(offset <= limit && size <= limit - offset, "Dateibereich außerhalb des Containers.")
}

func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
    var result = Data()
    while result.count < count {
        let chunk = try handle.read(upToCount: count - result.count) ?? Data()
        try require(!chunk.isEmpty, "Unerwartetes Dateiende; Datei wurde möglicherweise verändert.")
        result.append(chunk)
    }
    return result
}

func readRange(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
    try handle.seek(toOffset: offset)
    return try readExactly(handle, count)
}

func safeName(_ name: String, allowEmpty: Bool = false) throws {
    try require((allowEmpty || !name.isEmpty) && name != "." && name != ".." &&
                !name.contains("/") && !name.contains("\\") && !name.contains("\0"),
                "Unsicherer Dateiname im Container: \(name)")
}

func regularFile(_ url: URL, writable: Bool = false) throws -> FileHandle {
    let descriptor = Darwin.open(url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw NUPError("Datei kann nicht sicher geöffnet werden: \(url.lastPathComponent)") }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
        Darwin.close(descriptor)
        throw NUPError("Nur reguläre Dateien werden unterstützt: \(url.lastPathComponent)")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

struct FileRevision: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let permissions: mode_t

    private init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
        permissions = info.st_mode & 0o777
    }
    init(handle: FileHandle) throws {
        var info = stat()
        try require(fstat(handle.fileDescriptor, &info) == 0, "Dateistand konnte nicht gelesen werden.")
        self.init(info)
    }
    func requireCurrent(at url: URL) throws {
        var info = stat()
        try require(lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG,
                    "Die Originaldatei ist nicht mehr verfügbar oder wurde ersetzt. Bitte erneut öffnen.")
        try require(FileRevision(info) == self,
                    "Die Originaldatei wurde inzwischen verändert. Bitte erneut öffnen, bevor du speicherst.")
    }
}

func publishFile(_ temporary: URL, to destination: URL) throws {
    // Hard-link publication is atomic and refuses to replace an existing destination.
    guard Darwin.link(temporary.path, destination.path) == 0 else {
        throw NUPError("Ziel konnte nicht angelegt werden (existiert es bereits?): \(destination.lastPathComponent)")
    }
    try? FileManager.default.removeItem(at: temporary)
}

func publishDirectory(_ temporary: URL, to destination: URL) throws {
    guard renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw NUPError("Zielordner konnte nicht angelegt werden; vorhandene Ordner werden nicht ersetzt.")
    }
}

final class JobContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastUpdate = Date.distantPast
    private let callback: @Sendable (Double, String) -> Void

    init(progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) { callback = progress }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func report(_ fraction: Double, _ message: String, force: Bool = false) throws {
        try check()
        lock.lock()
        let now = Date()
        let emit = force || now.timeIntervalSince(lastUpdate) > 0.08 || fraction >= 1
        if emit { lastUpdate = now }
        lock.unlock()
        if emit { callback(min(1, max(0, fraction)), message) }
    }
}
