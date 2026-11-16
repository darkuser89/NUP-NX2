import AppKit
import UniformTypeIdentifiers

@MainActor
enum FilePanels {
    static func archive() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("NUP-Container öffnen")
        panel.prompt = L10n.text("Öffnen")
        panel.allowedContentTypes = [UTType(filenameExtension: "nup") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func folder(title: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title; panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = L10n.text("Auswählen …")
        panel.canCreateDirectories = true
        return await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
        }
    }
    static func image() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Paket-Icon auswählen")
        panel.prompt = L10n.text("Auswählen …")
        panel.allowedContentTypes = [.png, .jpeg]
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func applicationControl() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.text("NACP-Datei auswählen")
        panel.prompt = L10n.text("Auswählen …")
        panel.allowedContentTypes = [UTType(filenameExtension: "nacp") ?? .data]
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func filesToAdd(target: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Dateien zur NUP hinzufügen")
        panel.prompt = L10n.text("Dateien hinzufügen …")
        panel.message = L10n.text("Ziel im ausgewählten Paket: \(String(describing: target))")
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }
    static func save(name: String, title: String, folder: Bool = false) -> URL? {
        let panel = NSSavePanel()
        panel.title = title; panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if !folder { panel.allowedContentTypes = [UTType(filenameExtension: "nup") ?? .data] }
        panel.message = folder ? L10n.text("Ein neuer Unterordner wird erstellt. Vorhandene Ordner werden nicht ersetzt.") : L10n.text("Bitte einen neuen Dateinamen wählen. Vorhandene Dateien werden nicht ersetzt.")
        return panel.runModal() == .OK ? panel.url : nil
    }
    static func imageData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        try require((values.fileSize ?? Int.max) <= 16 * 1024 * 1024, L10n.text("Icons dürfen höchstens 16 MB groß sein."))
        let data = try Data(contentsOf: url)
        try require(NSImage(data: data) != nil, L10n.text("Das Bild konnte nicht gelesen werden."))
        return data
    }
}
