import Foundation
import zlib

struct ApplicationControl: Sendable {
    static let size = 0x4000

    let name: String
    let publisher: String
    let displayVersion: String
    let titles: [String: String]

    // NACP language slot order from libnx and the Switchbrew format notes.
    private static let languages = [
        "en-us", "en-gb", "ja", "fr", "de", "es-419", "es", "it",
        "nl", "fr-ca", "pt", "ru", "ko", "zh-hant", "zh-hans", "pt-br", "pl", "th"
    ]

    init(_ data: Data, preferredLanguages: [String] = Locale.preferredLanguages) throws {
        try require(data.count == Self.size, "Eine control.nacp muss genau 16 KiB groß sein.")
        let entries: Data
        switch try data.uint(0x3215, 1) {
        case 0: entries = try data.bytes(0, 0x3000)
        case 1: entries = try Self.inflateTitles(data)
        default: throw NUPError("Dieses NACP-Sprachformat wird nicht unterstützt.")
        }
        var records: [(language: String, name: String, publisher: String)] = []
        for (index, language) in Self.languages.prefix(entries.count / 0x300).enumerated() {
            let offset = index * 0x300
            let name = try Self.text(entries, offset, 0x200)
            let publisher = try Self.text(entries, offset + 0x200, 0x100)
            if !name.isEmpty || !publisher.isEmpty { records.append((language, name, publisher)) }
        }
        var primary = records.first
        for preferred in preferredLanguages {
            let tag = preferred.replacingOccurrences(of: "_", with: "-").lowercased()
            let language = tag.split(separator: "-").first
            if let match = records.first(where: { $0.language == tag })
                ?? records.first(where: { $0.language.split(separator: "-").first == language }) {
                primary = match
                break
            }
        }
        name = primary?.name ?? ""
        publisher = primary?.publisher ?? ""
        displayVersion = try Self.text(data, 0x3060, 0x10)
        titles = Dictionary(uniqueKeysWithValues: records.filter { !$0.name.isEmpty }.map { ($0.language, $0.name) })
        try require(!name.isEmpty || !publisher.isEmpty || !displayVersion.isEmpty || !titles.isEmpty,
                    "Die control.nacp enthält keine lesbaren Anwendungsdaten.")
    }

    private static func text(_ data: Data, _ offset: Int, _ size: Int) throws -> String {
        let bytes = try data.bytes(offset, size).prefix { $0 != 0 }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw NUPError("Ungültiger UTF-8-Text in control.nacp.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func inflateTitles(_ data: Data) throws -> Data {
        let size = try integer(data.uint(0, 2))
        try require((1...0x2ffe).contains(size), "Ungültige Länge der komprimierten NACP-Sprachdaten.")
        var compressed = try data.bytes(2, size)
        var output = Data(count: 0x6000)
        var stream = z_stream()
        try require(inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK,
                    "NACP-Dekompression konnte nicht gestartet werden.")
        defer { inflateEnd(&stream) }
        let result = compressed.withUnsafeMutableBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = input.bindMemory(to: UInt8.self).baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        try require(result == Z_STREAM_END && stream.avail_in == 0 && stream.total_out == 0x6000,
                    "Komprimierte NACP-Sprachdaten sind beschädigt.")
        return output
    }

    static func read(from archive: NUPArchive, package: Int, context: JobContext) throws -> (ApplicationControl, String) {
        try context.check()
        try archive.revision.requireCurrent(at: archive.url)
        let data: Data
        let source: String
        if let embedded = archive.packages[package].metadata[2] {
            data = embedded
            source = "NACP-Metadaten"
        } else {
            var match: Int?
            for index in archive.files.indices {
                try context.check()
                let node = archive.directories.count + index
                guard archive.files[index].name.lowercased() == "control.nacp",
                      archive.owns(node: node, package: package) else { continue }
                try require(match == nil, "Mehrere control.nacp im Paket. Bitte die gewünschte NACP-Datei separat auswählen.")
                match = index
            }
            guard let match else { throw NUPError("Dieses Paket enthält keine control.nacp. Du kannst eine separate NACP-Datei auswählen oder Titel und Publisher aus einem anderen Paket ergänzen.") }
            let file = archive.files[match]
            try require(file.size == UInt64(Self.size) && file.storedSize <= UInt64(Self.size * 2),
                        "Die control.nacp im Paket hat eine ungültige Größe.")
            let input = try regularFile(archive.url)
            defer { try? input.close() }
            try require(FileRevision(handle: input) == archive.revision, "Die NUP wurde verändert. Bitte erneut öffnen.")
            var content = Data()
            try StreamCodec.consume(file, input: input, context: context) { content.append($0) }
            data = content
            source = "control.nacp im Paket"
        }
        try archive.revision.requireCurrent(at: archive.url)
        return (try ApplicationControl(data), source)
    }

    static func read(from url: URL) throws -> ApplicationControl {
        let input = try regularFile(url)
        defer { try? input.close() }
        let revision = try FileRevision(handle: input)
        try require(revision.size == Self.size, "Eine control.nacp muss genau 16 KiB groß sein.")
        let data = try readExactly(input, Self.size)
        try revision.requireCurrent(at: url)
        return try ApplicationControl(data)
    }
}
