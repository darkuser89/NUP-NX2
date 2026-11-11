import AppKit
import UniformTypeIdentifiers

enum FileDropReader {
    static func url(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                do { continuation.resume(returning: try decode(item)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func decode(_ item: NSSecureCoding?) throws -> URL {
        let url: URL?
        if let value = item as? URL { url = value }
        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
        else if let value = item as? String { url = URL(string: value) }
        else { url = nil }
        guard let url, url.isFileURL, !url.path.contains("\0") else {
            throw NUPError("Bitte eine lokale NUP-Datei oder einen Ordner aus dem Finder ablegen.")
        }
        return url.standardizedFileURL
    }

    static func validate(_ urls: [URL]) throws -> URL {
        try require(urls.count == 1, "Bitte eine NUP-Datei oder einen Ordner auf einmal ablegen.")
        let input = urls[0]
        try require(input.isFileURL && !input.path.contains("\0"), "Bitte eine lokale Datei oder einen lokalen Ordner ablegen.")
        let url = input.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        try require(values.isDirectory == true || (values.isRegularFile == true && url.pathExtension.lowercased() == "nup"),
                    "Hier können NUP-Dateien und Ordner abgelegt werden.")
        return url
    }
}
