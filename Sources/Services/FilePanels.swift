import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    static func archive() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "NUP-Container öffnen"
        panel.allowedContentTypes = [UTType(filenameExtension: "nup") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func folder(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title; panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    static func image() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Paket-Icon auswählen"
        panel.allowedContentTypes = [.png, .jpeg]
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func filesToAdd(target: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Dateien zur NUP hinzufügen"
        panel.message = "Ziel im ausgewählten Paket: \(target)"
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    static func save(name: String, title: String, folder: Bool = false) -> URL? {
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "nup") ?? .data] }
        panel.message = folder ? "Ein neuer Unterordner wird erstellt. Vorhandene Ordner werden nicht ersetzt." : "Bitte einen neuen Dateinamen wählen. Vorhandene Dateien werden nicht ersetzt."
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func imageData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        try require((values.fileSize ?? Int.max) <= 16 * 1024 * 1024, "Icons dürfen höchstens 16 MB groß sein.")
        let data = try Data(contentsOf: url)
        try require(NSImage(data: data) != nil, "Das Bild konnte nicht gelesen werden.")
        return data
    }
}
