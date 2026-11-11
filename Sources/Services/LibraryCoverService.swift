import Foundation

enum LibraryCoverService {
    static func loadImage(_ url: URL) throws -> LibraryCoverImage {
        let input = try regularFile(url)
        defer { try? input.close() }
        let count = try input.seekToEnd()
        try require(count <= 16 * 1024 * 1024, "Cover dürfen höchstens 16 MiB groß sein.")
        try input.seek(toOffset: 0)
        let data = try readExactly(input, Int(count))
        guard let thumbnail = LibraryMetadataReader.makeThumbnail(data) else {
            throw NUPError("Bitte ein gültiges PNG- oder JPEG-Bild mit höchstens 64 Millionen Pixeln auswählen.")
        }
        return LibraryCoverImage(data: data, thumbnail: thumbnail)
    }

    static func save(_ cover: Data, in archive: NUPArchive, package index: Int,
                     profile: MetadataProfile, context: JobContext) throws -> NUPArchive {
        try context.check()
        try require(archive.packages.indices.contains(index), "Paket existiert nicht.")
        try require(LibraryMetadataReader.makeThumbnail(cover) != nil, "Das Cover ist kein unterstütztes PNG-/JPEG-Bild oder überschreitet die Bildgrenzen.")
        var metadata = archive.packages[index].metadata
        let type = profile.type(3)
        if let existing = metadata[type], !existing.isEmpty {
            let isImage = existing.starts(with: [137,80,78,71,13,10,26,10]) || existing.starts(with: [255,216,255])
            try require(isImage, "Das Cover-Feld enthält Nicht-Bild-Daten. Diese Datei verwendet möglicherweise andere Metadaten-Kennungen als Spezifikation v1.")
        }
        metadata[type] = cover
        // Touch only the cover TLV; preserve every other metadata record byte for byte.
        try MetadataTransaction.update(archive: archive, package: index, metadata: metadata, context: context)
        return try NUPArchive(url: archive.url)
    }
}
