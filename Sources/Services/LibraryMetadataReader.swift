import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LibraryMetadataReader {
    static func read(_ url: URL, context: JobContext) throws -> LibraryMetadataResult {
        try context.check()
        // Library previews never recover journals or write to the user's NUP.
        let archive = try NUPArchive(url: url, context: context, recoverPendingMetadata: false)
        try context.check()
        let result = metadata(from: archive.packages)
        try archive.revision.requireCurrent(at: url)
        return result
    }

    static func metadata(from packages: [NUPPackage]) -> LibraryMetadataResult {
        let ordered = packages.filter { $0.kind == 0 } + packages.filter { $0.kind != 0 }
        var title: String?, cover: Data?
        for package in ordered {
            let profile = MetadataProfile.specification
            let name = readableText(package.metadata[profile.type(5)]) ?? localizedTitle(package.metadata[profile.type(9)])
            if title == nil, let name {
                title = name
            }
            if cover == nil, let data = package.metadata[profile.type(3)], isImage(data) { cover = data }
            if cover == nil { cover = localizedValue(package.metadata[profile.type(10)], valid: isImage) }
        }
        let thumbnail = cover.flatMap(makeThumbnail)
        return LibraryMetadataResult(item: LibraryItemMetadata(title: title, hasCover: thumbnail != nil), thumbnail: thumbnail)
    }

    private static func readableText(_ data: Data?) -> String? {
        guard let data, data.count <= 65536, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    private static func localizedTitle(_ data: Data?) -> String? {
        localizedValue(data, valid: { readableText($0) != nil }).flatMap(readableText)
    }

    private static func localizedValue(_ data: Data?, valid: (Data) -> Bool) -> Data? {
        guard let data, let values = try? MetadataCodec.localized(data) else { return nil }
        for language in ["de", "de-de", "en", "en-us"] + values.keys.sorted() {
            if let value = values[language], valid(value) { return value }
        }
        return nil
    }

    private static func isImage(_ data: Data) -> Bool {
        guard data.count <= 16 * 1024 * 1024 else { return false }
        return data.starts(with: [137,80,78,71,13,10,26,10]) || data.starts(with: [255,216,255])
    }

    static func makeThumbnail(_ data: Data) -> Data? {
        guard isImage(data),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 64_000_000 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// One serial actor bounds archive parsing and image decoding to a single background read.
actor LibraryMetadataLoader {
    func read(_ entry: LibraryEntry, context: JobContext) throws -> LibraryMetadataResult {
        try autoreleasepool { try LibraryMetadataReader.read(entry.url, context: context) }
    }
}
