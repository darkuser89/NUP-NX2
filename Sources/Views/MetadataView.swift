import SwiftUI

struct MetadataView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    let package: NUPPackage

    var body: some View {
        if let draft = store.editDraft?.packages[package.id] {
            Form {
                Section {
                    LabeledContent(language.text("Metadaten-Format"), value: language.text("Spezifikation v1"))
                    Text(language.text("Änderungen werden vorgemerkt und erst mit Übernehmen gespeichert."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(language.text("Anwendungsdaten")) {
                    TextField(language.text("Titel"), text: binding(\.name, draft.name))
                    TextField(language.text("Publisher"), text: binding(\.publisher, draft.publisher))
                    TextField(language.text("Angezeigte Version"), text: binding(\.displayVersion, draft.displayVersion))
                    HStack {
                        Text(language.text("Cover"))
                        Spacer()
                        if let data = draft.icon, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        Button(language.text("Auswählen …")) {
                            if let url = FilePanels.image() {
                                do { binding(\.icon, draft.icon).wrappedValue = try FilePanels.imageData(url) }
                                catch { store.error = error.localizedDescription }
                            }
                        }
                        Button(language.text("Entfernen")) { binding(\.icon, draft.icon).wrappedValue = nil }.disabled(draft.icon == nil)
                        if let packages = store.editDraft?.packages, packages.count > 1 {
                            coverMenu(packages)
                        }
                    }
                    LabeledContent(language.text("Anwendungsdaten ergänzen")) {
                        applicationDataMenu(store.editDraft?.packages ?? [])
                    }
                    Text(language.text("Leere Textfelder entfernen die jeweilige Angabe. Die Paketidentität bleibt geschützt."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(language.text("Sprachen")) {
                    if let notice = draft.decodingNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    LocalizationEditor(entries: binding(\.localized, draft.localized))
                }
                Section(language.text("Weitere Metadaten")) {
                    TextField(language.text("Quelle"), text: binding(\.source, draft.source))
                    TextField(language.text("Build-ID (64 Hex-Zeichen)"), text: binding(\.buildID, draft.buildID))
                        .font(.body.monospaced())
                }
                Section(language.text("Paketidentität")) {
                    LabeledContent(language.text("Titel-ID"), value: package.titleIDString)
                    LabeledContent(language.text("Paketart"), value: package.kindName(in: language))
                    LabeledContent(language.text("Interne Version"), value: String(package.version))
                }
                if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).disabled(store.busy)
        }
    }

    private func packageLabel(_ draft: ArchivePackageDraft) -> String {
        language.text("Paket \(String(describing: draft.original.id + 1)) · \(String(describing: draft.original.kindName(in: language))) · \(String(describing: draft.original.versionString))")
    }

    private func coverMenu(_ packages: [ArchivePackageDraft]) -> some View {
        let others = packages.filter { $0.original.id != package.id }
        let sources = others.filter { $0.icon?.isEmpty == false }
        let hasCover = packages[package.id].icon?.isEmpty == false
        return Menu(language.text("Cover kopieren")) {
            Menu(language.text("Aus Paket übernehmen")) {
                ForEach(sources, id: \.original.id) { source in
                    Button(packageLabel(source)) { store.stageCover(from: source.original.id, to: [package.id]) }
                }
            }.disabled(sources.isEmpty)
            Menu(language.text("An Paket weitergeben")) {
                ForEach(others, id: \.original.id) { target in
                    Button(packageLabel(target)) { store.stageCover(from: package.id, to: [target.original.id]) }
                }
            }.disabled(!hasCover)
            Button(language.text("An alle Pakete ohne Cover weitergeben")) {
                store.stageCover(from: package.id, to: others.map(\.original.id), onlyMissing: true)
            }.disabled(!hasCover || !others.contains(where: { $0.icon == nil }))
        }.disabled(sources.isEmpty && !hasCover)
    }

    private func applicationDataMenu(_ packages: [ArchivePackageDraft]) -> some View {
        let sources = packages.filter { $0.original.id != package.id && (!$0.name.isEmpty || !$0.publisher.isEmpty) }
        return Menu(language.text("Aus Quelle lesen")) {
            Button(language.text("Aus diesem Paket lesen")) { store.importApplicationData(package: package.id) }
            Button(language.text("NACP-Datei auswählen …")) {
                if let url = FilePanels.applicationControl() { store.importApplicationData(package: package.id, file: url) }
            }
            if !sources.isEmpty {
                Menu(language.text("Titel und Publisher aus anderem Paket")) {
                    ForEach(sources, id: \.original.id) { source in
                        Button(packageLabel(source)) { store.stageMissingApplicationText(from: source.original.id, to: package.id) }
                    }
                }
            }
        }.help(language.text("Ergänzt leere Felder und fehlende Sprachtitel im Entwurf."))
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ArchivePackageDraft, Value>, _ fallback: Value) -> Binding<Value> {
        let source = store.editDraft?.archive.snapshotID
        return Binding(get: {
            guard let draft = store.editDraft, draft.archive.snapshotID == source, draft.packages.indices.contains(package.id) else { return fallback }
            return draft.packages[package.id][keyPath: keyPath]
        }, set: { value in
            guard !store.busy, store.editDraft?.archive.snapshotID == source,
                  store.editDraft?.packages.indices.contains(package.id) == true else { return }
            store.editDraft?.packages[package.id][keyPath: keyPath] = value
        })
    }
}
