import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var metadata: LibraryMetadataStore
    @State private var search = ""
    @State private var selection = Set<URL>()
    @State private var visible: [LibraryEntry] = []

    private struct Query: Equatable {
        var snapshot: UUID?
        var text: String
        var metadataRevision: Int
    }

    init(store: WorkspaceStore) {
        self.store = store
        self.metadata = store.libraryMetadata
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            if let library = store.library {
                HStack {
                    Text(L10n.text("\(String(describing: visible.count)) von \(String(describing: library.entries.count)) NUP-Dateien"))
                        .font(.caption).foregroundStyle(.secondary)
                    if metadata.loading {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("Metadaten \(String(describing: metadata.completed))/\(String(describing: library.entries.count))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField(L10n.text("Spielname oder Pfad suchen"), text: $search)
                        .textFieldStyle(.roundedBorder).frame(width: 280)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Table(visible, selection: $selection) {
                    TableColumn(L10n.text("Spiel")) { entry in
                        LibraryGameRow(entry: entry, metadata: metadata) { store.requestLibraryCover(entry.url) }
                    }.width(min: 260, ideal: 400)
                    TableColumn(L10n.text("Pfad")) { entry in
                        Text(entry.relativePath).lineLimit(1).foregroundStyle(.secondary)
                            .help(entry.url.path)
                    }.width(min: 150, ideal: 330)
                    TableColumn(L10n.text("Größe")) { entry in
                        Text(entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                            .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(100)
                }.padding(.horizontal, 16)
                    .contextMenu(forSelectionType: URL.self) { selected in
                        Button(L10n.text("Öffnen")) { open(selected) }.disabled(selected.count != 1 || store.busy)
                        Button(L10n.text("Cover hinzufügen / ändern …")) { editCover(selected) }.disabled(selected.count != 1 || store.busy)
                        Button(L10n.text("Diagnostizieren / reparieren …")) {
                            if let url = selected.first { store.diagnose(url) }
                        }.disabled(selected.count != 1 || store.busy)
                    } primaryAction: { selected in
                        open(selected)
                    }
                if !library.warnings.isEmpty {
                    DisclosureGroup(L10n.text("\(String(describing: library.warnings.count)) Hinweise zur Ordnersuche")) {
                        ScrollView { Text(library.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                            .frame(maxHeight: 90)
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                }
                if visible.isEmpty {
                    Text(search.isEmpty ? L10n.text("Keine NUP-Dateien gefunden.") : L10n.text("Keine passenden NUP-Dateien."))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 56, weight: .light)).foregroundStyle(.tint)
                    Text(L10n.text("Deine NUP-Sammlung")).font(.title2)
                    Text(store.libraryUnavailableMessage ?? (store.busy ? L10n.text("Der gespeicherte Ordner wird eingelesen …") : L10n.text("Ordner auswählen und alle NUP-Dateien einschließlich Unterordnern anzeigen.")))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.rememberedLibraryFolder != nil && !store.busy {
                        Button(L10n.text("Erneut versuchen"), action: store.refreshLibrary)
                    }
                    Button(L10n.text("Ordner auswählen …"), action: store.chooseLibrary).buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            }
        }
        .disabled(store.busy)
        .task(id: Query(snapshot: store.library?.id, text: search, metadataRevision: search.isEmpty ? 0 : metadata.revision)) {
            let snapshot = store.library
            let query = search, items = metadata.items
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let rows = await Task.detached(priority: .userInitiated) { snapshot?.matching(query, metadata: items) ?? [] }.value
            guard !Task.isCancelled else { return }
            visible = rows
            selection.formIntersection(Set(rows.map(\.url)))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.text("NUP-Bibliothek"), systemImage: "folder").font(.title2.bold())
                Spacer()
                if store.library != nil {
                    Button(L10n.text("Öffnen")) { open(selection) }.disabled(selection.count != 1)
                    Button(L10n.text("Cover …")) { editCover(selection) }.disabled(selection.count != 1)
                    Button(L10n.text("Neu einlesen"), action: store.refreshLibrary)
                }
                Button(L10n.text("Ordner auswählen …"), action: store.chooseLibrary).buttonStyle(.borderedProminent)
            }
            if let folder = store.library?.folder ?? store.rememberedLibraryFolder {
                Text(folder.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Text(L10n.text("Spielnamen und Cover werden lokal aus den Metadaten nachgeladen. Die Spieldaten werden nicht entpackt."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L10n.text("Spezifikation v1")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ selected: Set<URL>) {
        if selected.count == 1, let url = selected.first { store.open(url) }
    }

    private func editCover(_ selected: Set<URL>) {
        if selected.count == 1, let url = selected.first { store.requestLibraryCover(url) }
    }
}
