import Foundation
import CryptoKit

enum StreamCodec {
    static let chunkSize = 1 << 20

    static func checked(_ code: Int) throws -> Int {
        if ZSTD_isError(code) != 0 { throw NUPError("Zstandard: \(String(cString: ZSTD_getErrorName(code)))") }
        return code
    }

    static func copy(_ input: FileHandle, output: FileHandle, context: JobContext) throws {
        while true {
            try context.check()
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
        }
    }

    static func raw(_ input: FileHandle, output: FileHandle, context: JobContext) throws -> (UInt64, Data) {
        var hash = SHA256()
        var size: UInt64 = 0
        while true {
            try context.check()
            let data = try input.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data); size += UInt64(data.count)
            try output.write(contentsOf: data)
        }
        return (size, Data(hash.finalize()))
    }

    static func encode(_ url: URL, output: FileHandle, level: Int, context: JobContext) throws -> NUPFile {
        let input = try regularFile(url)
        defer { try? input.close() }
        let expected = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let start = try output.offset()
        guard let encoder = ZSTD_createCCtx() else { throw NUPError("Zstandard-Speicher konnte nicht reserviert werden.") }
        defer { ZSTD_freeCCtx(encoder) }
        _ = try checked(ZSTD_CCtx_setParameter(encoder, ZSTD_c_compressionLevel, Int32(level)))
        _ = try checked(ZSTD_CCtx_setPledgedSrcSize(encoder, expected))
        var hash = SHA256()
        var size: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try context.check()
            let data = try input.read(upToCount: chunkSize) ?? Data()
            size += UInt64(data.count)
            hash.update(data: data)
            let end = data.isEmpty
            try data.withUnsafeBytes { source in
                var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                var remaining = 1
                repeat {
                    try context.check()
                    var produced = 0
                    try buffer.withUnsafeMutableBytes { target in
                        var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        remaining = try checked(ZSTD_compressStream2(encoder, &outBuffer, &inBuffer, end ? ZSTD_e_end : ZSTD_e_continue))
                        produced = outBuffer.pos
                    }
                    if produced > 0 { try output.write(contentsOf: Data(buffer.prefix(produced))) }
                } while inBuffer.pos < inBuffer.size || (end && remaining != 0)
            }
            if end { break }
        }
        try require(size == expected, "Quelldatei wurde beim Packen verändert: \(url.lastPathComponent)")
        let digest = Data(hash.finalize())
        let stored = try output.offset() - start
        if stored >= size {
            try output.truncate(atOffset: start)
            try output.seek(toOffset: start)
            try input.seek(toOffset: 0)
            let (rawSize, rawHash) = try raw(input, output: output, context: context)
            try require(rawSize == size && rawHash == digest, "Quelldatei wurde beim Packen verändert.")
            return NUPFile(name: url.lastPathComponent, size: size, offset: size == 0 ? 0 : start,
                           storedSize: size, hash: digest, codec: 0)
        }
        return NUPFile(name: url.lastPathComponent, size: size, offset: start,
                       storedSize: stored, hash: digest, codec: 1)
    }

    static func consume(_ file: NUPFile, input: FileHandle, context: JobContext,
                        sink: (Data) throws -> Void = { _ in }) throws {
        try input.seek(toOffset: file.offset)
        var remaining = file.storedSize
        var produced: UInt64 = 0
        var hash = SHA256()
        func accept(_ data: Data) throws {
            try require(UInt64(data.count) <= file.size - produced, "Dekomprimierte Datei überschreitet ihre deklarierte Größe.")
            produced += UInt64(data.count)
            hash.update(data: data)
            try sink(data)
        }
        if file.codec == 0 {
            while remaining > 0 {
                try context.check()
                let data = try readExactly(input, Int(min(UInt64(chunkSize), remaining)))
                remaining -= UInt64(data.count)
                try accept(data)
            }
        } else {
            guard let decoder = ZSTD_createDCtx() else { throw NUPError("Zstandard-Speicher konnte nicht reserviert werden.") }
            defer { ZSTD_freeDCtx(decoder) }
            _ = try checked(ZSTD_DCtx_setParameter(decoder, ZSTD_d_windowLogMax, 27))
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            var result = 1
            while remaining > 0 {
                try context.check()
                let data = try readExactly(input, Int(min(UInt64(chunkSize), remaining)))
                remaining -= UInt64(data.count)
                try data.withUnsafeBytes { source in
                    var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                    var outputFilled = false
                    repeat {
                        try context.check()
                        var count = 0
                        try buffer.withUnsafeMutableBytes { target in
                            var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                            result = try checked(ZSTD_decompressStream(decoder, &outBuffer, &inBuffer))
                            count = outBuffer.pos
                            outputFilled = count == target.count
                        }
                        try accept(Data(buffer.prefix(count)))
                        if result == 0 {
                            try require(inBuffer.pos == inBuffer.size && remaining == 0,
                                        "Zusätzliche Daten hinter dem Zstandard-Frame.")
                            break
                        }
                        try require(count > 0 || inBuffer.pos > 0, "Zstandard-Decoder macht keinen Fortschritt.")
                    } while inBuffer.pos < inBuffer.size || outputFilled
                }
            }
            try require(result == 0, "Abgeschnittener Zstandard-Frame.")
        }
        try require(produced == file.size, "Falsche Dateigröße: \(file.name)")
        try require(Data(hash.finalize()) == file.hash, "SHA-256 stimmt nicht überein: \(file.name)")
    }
}
