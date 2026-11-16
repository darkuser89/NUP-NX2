import SwiftUI

struct PackView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    @State private var localized: [LocalizedEntry] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("Container erstellen")).font(.system(size: 27, weight: .semibold))
                Text(language.text("Basis, Updates und DLC in einer NUP-Datei bündeln.")).foregroundStyle(.secondary)
            }.padding(24)
            Form {
                Section(language.text("Quelle")) {
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.tint).font(.title2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.sourceFolder?.lastPathComponent ?? language.text("Dump-Ordner auswählen")).font(.headline)
                            Text(store.sourceFolder?.path ?? language.text("base/ · updates/<Version>/ · dlc/<Titel-ID>/<Index>/"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                        }
                        Spacer()
                        Button(language.text("Auswählen …"), action: store.chooseSource)
                    }.padding(.vertical, 8)
                    Text(language.text("Dump-Ordner können aus dem Finder direkt ins Fenster gezogen werden. Auch einzelne Inhaltsordner mit exefs/ oder romfs/ werden erkannt. Der Quellordner muss bereits unverschlüsselte Dateien enthalten."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(language.text("Metadaten · optional")) {
                    TextField(language.text("Titel"), text: $store.options.name)
                    TextField(language.text("Publisher"), text: $store.options.publisher)
                    TextField(language.text("Angezeigte Version"), text: $store.options.displayVersion)
                    TextField(language.text("Titel-ID (16 Hex-Zeichen)"), text: $store.options.titleID)
                    Text(language.text("Ohne Eingabe wird die Titel-ID aus main.npdm gelesen, sofern vorhanden.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(language.text("Icon")); Spacer()
                        if let data = store.options.icon, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 36, height: 36)
                            Button(language.text("Entfernen")) { store.options.icon = nil }
                        }
                        Button(language.text("Bild auswählen …")) {
                            if let url = FilePanels.image() {
                                do { store.options.icon = try FilePanels.imageData(url) } catch { store.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Section(language.text("Sprachen · optional")) { LocalizationEditor(entries: $localized) }
                Section(language.text("Kompression und Format")) {
                    Stepper(language.text("Zstandard-Stufe: \(String(describing: store.options.level))"), value: $store.options.level, in: 1...19)
                    Text(language.text("Stufe 3 ist ein guter Ausgangspunkt. Dateien, die nicht kleiner werden, werden unkomprimiert gespeichert. Identische Inhalte teilen sich einen Datenbereich."))
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent(language.text("Metadaten-Format"), value: language.text("Spezifikation v1"))
                    Toggle(language.text(".listing-Dateien behalten"), isOn: $store.options.keepListings)
                }
            }.formStyle(.grouped)
            HStack {
                Text(language.text("Zieldatei außerhalb des Quellordners speichern.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(language.text("Container erstellen …")) {
                    do {
                        let (titles, icons) = try LocalizationEditor.values(localized)
                        store.options.localizedTitles = titles; store.options.localizedIcons = icons
                        store.pack()
                    } catch { store.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(store.sourceFolder == nil)
            }.padding(24)
        }.disabled(store.busy)
    }
}
