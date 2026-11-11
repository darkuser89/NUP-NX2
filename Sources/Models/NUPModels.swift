import Foundation

enum MetadataProfile: String, CaseIterable, Identifiable, Sendable {
    case specification = "Spezifikation v1"
    var id: String { rawValue }
    // The native app exclusively reads/writes the one-based SPEC.md TLV identifiers.
    func type(_ specificationType: UInt16) -> UInt16 { specificationType }
}

struct NUPPackage: Identifiable, Sendable {
    var id: Int
    var titleID: UInt64 = 0
    var root: Int = 0
    var exefs: Int? = nil
    var romfs: Int? = nil
    var version: UInt32 = 0
    var kind: UInt8 = 0
    var flags: UInt8 = 0
    var metaOffset: UInt64 = 0
    var metaSize: Int = 0
    var metadata: [UInt16: Data] = [:]

    var kindName: String { ["Basis", "Update", "DLC", "DLC-Update", "System"][Int(kind)] }
    var titleIDString: String { String(format: "%016llX", titleID) }
    var versionString: String { "\(version >> 16).\((version >> 8) & 255).\(version & 255)" }
    func text(_ type: UInt16, profile: MetadataProfile) -> String {
        metadata[profile.type(type)].flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct NUPDirectory: Sendable {
    var name: String
    var children: [Int]
}

struct NUPFile: Sendable {
    var name: String
    var size: UInt64 = 0
    var offset: UInt64 = 0
    var storedSize: UInt64 = 0
    var hash = Data(count: 32)
    var codec: UInt8 = 0
}

struct BrowserNode: Identifiable, Sendable {
    var id: Int
    var name: String
    var size: UInt64?
    var storedSize: UInt64?
    var codec: UInt8?
    var children: [BrowserNode]?
    var isDirectory: Bool { children != nil }
}

struct PackOptions: Sendable {
    var titleID = ""
    var name = ""
    var publisher = ""
    var displayVersion = ""
    var level = 3
    var keepListings = false
    var profile = MetadataProfile.specification
    var icon: Data? = nil
    var localizedTitles: [String: String] = [:]
    var localizedIcons: [String: Data] = [:]
}

struct MetadataEdit: Sendable {
    var name: String
    var publisher: String
    var displayVersion: String
    var icon: Data?
    var removeIcon = false
    var localizedTitles: [String: String] = [:]
    var localizedIcons: [String: Data] = [:]
}

enum MetadataCodec {
    static func parse(_ data: Data) throws -> [UInt16: Data] {
        var records: [UInt16: Data] = [:]
        var position = 0
        while position < data.count {
            try require(data.count - position >= 8, "Abgeschnittene Metadaten.")
            let type = UInt16(try data.uint(position, 2))
            try require(try data.uint(position + 2, 2) == 0, "Unbekannte Metadaten-Flags.")
            let count = try integer(data.uint(position + 4, 4))
            try require(records[type] == nil, "Doppelte Metadaten-Kennung.")
            records[type] = try data.bytes(position + 8, count)
            position += 8 + count
        }
        return records
    }
    static func serialize(_ records: [UInt16: Data]) throws -> Data {
        var data = Data()
        for type in records.keys.sorted() {
            let payload = records[type]!
            try require(payload.count <= Int(UInt32.max), "Metadaten zu groß.")
            data.appendLE(UInt64(type), width: 2)
            data.appendLE(0, width: 2)
            data.appendLE(UInt64(payload.count), width: 4)
            data.append(payload)
        }
        return data
    }
    static func localized(_ data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        var position = 0
        while position < data.count {
            let length = Int(data[position]); position += 1
            let tagData = try data.bytes(position, length); position += length
            guard let tag = String(data: tagData, encoding: .ascii)?.lowercased(), !tag.isEmpty else {
                throw NUPError("Ungültiges Sprachkürzel.")
            }
            try require(result[tag] == nil, "Doppeltes Sprachkürzel.")
            let count = try integer(data.uint(position, 4)); position += 4
            result[tag] = try data.bytes(position, count); position += count
        }
        return result
    }
    static func localizedData(_ values: [String: Data]) throws -> Data {
        var result = Data()
        var tags = Set<String>()
        for key in values.keys.sorted() {
            let tag = key.lowercased()
            guard let bytes = tag.data(using: .ascii), (1...255).contains(bytes.count), tags.insert(tag).inserted else {
                throw NUPError("Ungültiges oder doppeltes Sprachkürzel: \(key)")
            }
            result.append(UInt8(bytes.count)); result.append(bytes)
            let value = values[key]!
            try require(value.count <= Int(UInt32.max), "Lokalisierte Metadaten zu groß.")
            result.appendLE(UInt64(value.count), width: 4); result.append(value)
        }
        return result
    }
}
