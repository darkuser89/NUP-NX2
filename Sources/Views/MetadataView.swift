import SwiftUI

struct MetadataView: View {
    @ObservedObject var store: WorkspaceStore
    let package: NUPPackage

    var body: some View {
        if let draft = store.editDraft?.packages[package.id] {
            Form {
                Section {
                    LabeledContent("Metadaten-Format", value: "Spezifikation v1")
                    Text("Änderungen werden vorgemerkt und erst mit Übernehmen gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Anwendungsdaten") {
                    TextField("Titel", text: binding(\.name, draft.name))
                    TextField("Publisher", text: binding(\.publisher, draft.publisher))
                    TextField("Angezeigte Version", text: binding(\.displayVersion, draft.displayVersion))
                    HStack {
                        Text("Cover")
                        Spacer()
                        if let data = draft.icon, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                        }
                        Button("Auswählen …") {
                            if let url = FilePanels.image() {
                                do { binding(\.icon, draft.icon).wrappedValue = try FilePanels.imageData(url) }
                                catch { store.error = error.localizedDescription }
                            }
                        }
                        Button("Entfernen") { binding(\.icon, draft.icon).wrappedValue = nil }.disabled(draft.icon == nil)
                        if let packages = store.editDraft?.packages, packages.count > 1 {
                            coverMenu(packages)
                        }
                    }
                    LabeledContent("Anwendungsdaten ergänzen") {
                        applicationDataMenu(store.editDraft?.packages ?? [])
                    }
                    Text("Leere Textfelder entfernen die jeweilige Angabe. Die Paketidentität bleibt geschützt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sprachen") {
                    if let notice = draft.decodingNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    LocalizationEditor(entries: binding(\.localized, draft.localized))
                }
                Section("Weitere Metadaten") {
                    TextField("Quelle", text: binding(\.source, draft.source))
                    TextField("Build-ID (64 Hex-Zeichen)", text: binding(\.buildID, draft.buildID))
                        .font(.body.monospaced())
                }
                Section("Paketidentität") {
                    LabeledContent("Titel-ID", value: package.titleIDString)
                    LabeledContent("Paketart", value: package.kindName)
                    LabeledContent("Interne Version", value: String(package.version))
                }
                if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).textFieldStyle(.roundedBorder).disabled(store.busy)
        }
    }

    private func packageLabel(_ draft: ArchivePackageDraft) -> String {
        "Paket \(draft.original.id + 1) · \(draft.original.kindName) · \(draft.original.versionString)"
    }

    private func coverMenu(_ packages: [ArchivePackageDraft]) -> some View {
        let others = packages.filter { $0.original.id != package.id }
        let sources = others.filter { $0.icon?.isEmpty == false }
        let hasCover = packages[package.id].icon?.isEmpty == false
        return Menu("Cover kopieren") {
            Menu("Aus Paket übernehmen") {
                ForEach(sources, id: \.original.id) { source in
                    Button(packageLabel(source)) { store.stageCover(from: source.original.id, to: [package.id]) }
                }
            }.disabled(sources.isEmpty)
            Menu("An Paket weitergeben") {
                ForEach(others, id: \.original.id) { target in
                    Button(packageLabel(target)) { store.stageCover(from: package.id, to: [target.original.id]) }
                }
            }.disabled(!hasCover)
            Button("An alle Pakete ohne Cover weitergeben") {
                store.stageCover(from: package.id, to: others.map(\.original.id), onlyMissing: true)
            }.disabled(!hasCover || !others.contains(where: { $0.icon == nil }))
        }.disabled(sources.isEmpty && !hasCover)
    }

    private func applicationDataMenu(_ packages: [ArchivePackageDraft]) -> some View {
        let sources = packages.filter { $0.original.id != package.id && (!$0.name.isEmpty || !$0.publisher.isEmpty) }
        return Menu("Aus Quelle lesen") {
            Button("Aus diesem Paket lesen") { store.importApplicationData(package: package.id) }
            Button("NACP-Datei auswählen …") {
                if let url = FilePanels.applicationControl() { store.importApplicationData(package: package.id, file: url) }
            }
            if !sources.isEmpty {
                Menu("Titel und Publisher aus anderem Paket") {
                    ForEach(sources, id: \.original.id) { source in
                        Button(packageLabel(source)) { store.stageMissingApplicationText(from: source.original.id, to: package.id) }
                    }
                }
            }
        }.help("Ergänzt leere Felder und fehlende Sprachtitel im Entwurf.")
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
