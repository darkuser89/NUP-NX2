import SwiftUI

struct MetadataView: View {
    @ObservedObject var store: WorkspaceStore
    let package: NUPPackage
    @State private var name = ""
    @State private var publisher = ""
    @State private var version = ""
    @State private var icon: Data?
    @State private var removeIcon = false
    @State private var localized: [LocalizedEntry] = []
    @State private var decodeError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Metadaten-Format", value: "Spezifikation v1")
            }
            Section("Anwendungsdaten") {
                TextField("Titel", text: $name)
                TextField("Publisher", text: $publisher)
                TextField("Angezeigte Version", text: $version)
                HStack {
                    Text("Icon")
                    Spacer()
                    if !removeIcon, let data = icon ?? package.metadata[store.profile.type(3)], let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    Button("Auswählen …") {
                        if let url = FilePanels.image() {
                            do { icon = try FilePanels.imageData(url); removeIcon = false } catch { store.error = error.localizedDescription }
                        }
                    }
                    Button("Entfernen") { icon = nil; removeIcon = true }
                }
                Text("Leere Textfelder entfernen die jeweilige Angabe. Paketidentität und Dateiinhalte bleiben beim Speichern erhalten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sprachen") { LocalizationEditor(entries: $localized) }
            Section("Paketidentität") {
                LabeledContent("Titel-ID", value: package.titleIDString)
                LabeledContent("Numerische Version", value: String(package.version))
                if let build = package.metadata[store.profile.type(7)], build.count == 32 {
                    LabeledContent("Build-ID") { Text(build.hex).font(.caption.monospaced()).textSelection(.enabled) }
                }
                LabeledContent("Quelle", value: package.text(8, profile: store.profile))
            }
            if let decodeError { Text(decodeError).foregroundStyle(.red).font(.caption) }
            Text("„Änderungen übernehmen“ schreibt nur Metadaten und Verwaltungsdaten direkt in die NUP. Ein kleines Wiederherstellungsprotokoll wird nach erfolgreichem Speichern entfernt.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Speichern unter …") { save(replacingOriginal: false) }
                Button("Änderungen übernehmen") { save(replacingOriginal: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
            }.disabled(decodeError != nil)
        }.formStyle(.grouped).disabled(store.busy).onAppear(perform: load)
    }
    private func save(replacingOriginal: Bool) {
        do {
            let (titles, icons) = try LocalizationEditor.values(localized)
            store.save(changes: MetadataEdit(name: name, publisher: publisher, displayVersion: version,
                                            icon: icon, removeIcon: removeIcon, localizedTitles: titles, localizedIcons: icons),
                       replacingOriginal: replacingOriginal)
        } catch { store.error = error.localizedDescription }
    }
    private func load() {
        name = package.text(5, profile: store.profile)
        publisher = package.text(6, profile: store.profile)
        version = package.text(4, profile: store.profile)
        do {
            let titles = try package.metadata[store.profile.type(9)].map(MetadataCodec.localized) ?? [:]
            let icons = try package.metadata[store.profile.type(10)].map(MetadataCodec.localized) ?? [:]
            localized = try Set(titles.keys).union(icons.keys).sorted().map { tag in
                let title: String
                if let data = titles[tag] {
                    guard let text = String(data: data, encoding: .utf8) else { throw NUPError("Sprachtitel ist kein gültiges UTF-8.") }
                    title = text
                } else { title = "" }
                return LocalizedEntry(language: tag, title: title, icon: icons[tag])
            }
        } catch { decodeError = "Sprachdaten entsprechen nicht Spezifikation v1: \(error.localizedDescription)" }
    }
}
