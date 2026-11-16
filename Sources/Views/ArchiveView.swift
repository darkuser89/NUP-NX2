import SwiftUI

struct ArchiveView: View {
    @ObservedObject var store: WorkspaceStore
    let archive: NUPArchive
    @State private var tab = 0
    @State private var search = ""
    @State private var nodes: [BrowserNode] = []
    @State private var selection = Set<Int>()
    @State private var confirmRemoval = false
    @State private var pendingRemoval = Set<Int>()
    @State private var pendingNewRemoval = Set<Int>()

    private struct Query: Equatable {
        let archive: UUID
        let package: Int
        let text: String
        let files: UUID?
        let selection: UUID?
    }

    private var package: NUPPackage { archive.packages[min(store.packageIndex, archive.packages.count - 1)] }
    private var destination: ArchiveFileLocation {
        if selection.count == 1, let id = selection.first,
           let pending = store.editDraft?.additions.first(where: { $0.nodeID == id }),
           let location = archive.fileLocation(node: pending.directory, package: package.id) { return location }
        if selection.count == 1, let id = selection.first,
           let location = archive.fileLocation(node: id, package: package.id) { return location }
        let id = package.romfs ?? package.exefs ?? package.root
        return archive.fileLocation(node: id, package: package.id) ?? ArchiveFileLocation(directory: package.root, path: "/")
    }
    private var selectedFiles: Set<Int> {
        Set(selection.filter { $0 >= archive.directories.count }.map { $0 - archive.directories.count })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            HStack {
                Picker(L10n.text("Ansicht"), selection: $tab) {
                    Text(L10n.text("Inhalte")).tag(0)
                    Text(L10n.text("Metadaten")).tag(1)
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                if tab == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.text("Dateien suchen"), text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                    }.padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).frame(width: 220)
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            if tab == 0 { fileBrowser }
            else {
                MetadataView(store: store, package: package)
                    .id("\(archive.url.path):\(package.id):\(store.profile.rawValue)")
            }
        }
        .task(id: Query(archive: archive.snapshotID, package: package.id, text: search, files: store.editDraft?.fileRevision, selection: store.fileSelection?.id)) {
            let index = package.id, query = search, snapshot = archive, draft = store.editDraft
            if let focus = store.fileSelection, focus.snapshot == archive.snapshotID, focus.package == index {
                tab = 0; selection = focus.nodes
                nodes = focus.nodes.sorted().map { node in
                    let file = snapshot.files[node - snapshot.directories.count]
                    let parent = snapshot.fileLocation(node: node, package: index)!.path
                    return BrowserNode(id: node, name: (parent == "/" ? "" : parent) + "/" + file.name,
                        size: file.size, storedSize: file.storedSize, codec: file.codec)
                }
                return
            }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let filtered = await Task.detached(priority: .userInitiated) {
                draft?.nodes(package: index, query: query) ?? BrowserTreeSearch.matching(snapshot.browserNodes(package: index), query: query)
            }.value
            guard !Task.isCancelled else { return }
            nodes = filtered
        }
        .onChange(of: store.packageIndex) { _, _ in
            if let focus = store.fileSelection, focus.package == store.packageIndex, focus.snapshot == archive.snapshotID {
                selection = focus.nodes
            } else { selection.removeAll(); store.fileSelection = nil }
        }
        .onChange(of: archive.snapshotID) { _, _ in selection.removeAll() }
        .confirmationDialog(L10n.text("\(String(describing: pendingRemoval.count + pendingNewRemoval.count)) Datei(en) zum Entfernen vormerken?"), isPresented: $confirmRemoval) {
            Button(L10n.text("Entfernen vormerken"), role: .destructive) {
                if !pendingRemoval.isEmpty { store.editFiles(directory: package.root, removing: pendingRemoval) }
                store.removeStagedFiles(pendingNewRemoval)
            }
        } message: {
            Text(L10n.text("Erst Übernehmen entfernt vorhandene Dateien aus dem Paket. Vorgemerkte neue Dateien werden nur aus dem Entwurf genommen. Bisherige Datenblöcke können in der NUP verbleiben; die NUP wird nicht verkleinert."))
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.library != nil {
                Button { store.section = .library } label: { Label(L10n.text("Zur Bibliothek"), systemImage: "folder") }
                    .buttonStyle(.borderless).font(.caption)
            }
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let data = store.editDraft?.packages[package.id].icon, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "shippingbox.fill").resizable().scaledToFit().padding(12).foregroundStyle(.tint) }
                }.frame(width: 64, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 13)).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    let name = store.editDraft?.packages[package.id].name ?? package.text(5, profile: store.profile)
                    Text(name.isEmpty ? archive.url.deletingPathExtension().lastPathComponent : name)
                        .font(.system(size: 25, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                    Text(archive.url.lastPathComponent).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(L10n.text("\(String(describing: archive.packages.count)) Pakete · \(String(describing: archive.files.count)) Dateien · \(String(describing: ByteCountFormatter.string(fromByteCount: Int64(clamping: archive.fileSize), countStyle: .file)))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button(L10n.text("Struktur prüfen")) { store.verify(deep: false) }
                    Button(L10n.text("Vollständig mit SHA-256 prüfen")) { store.verify(deep: true) }
                    if let report = store.lastInspection, report.url == archive.url {
                        Button(L10n.text("Letztes Prüfergebnis anzeigen")) { store.repairReport = report }
                    }
                    Divider()
                    Button(L10n.text("Paket entpacken …")) { store.extract() }
                    Button(L10n.text("Nur ExeFS entpacken …")) { store.extract(subtree: "exefs") }.disabled(package.exefs == nil)
                    Button(L10n.text("Nur RomFS entpacken …")) { store.extract(subtree: "romfs") }.disabled(package.romfs == nil)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.busy)
            }
            HStack(spacing: 24) {
                Picker(L10n.text("Paket"), selection: $store.packageIndex) {
                    ForEach(archive.packages) { package in
                        Text("\(package.id + 1) · \(package.kindName) · \(package.versionString)").tag(package.id)
                    }
                }.frame(maxWidth: 300).disabled(store.busy)
                LabeledContent(L10n.text("Titel-ID")) { Text(package.titleIDString).monospaced().textSelection(.enabled) }.font(.caption)
                if package.flags & 1 != 0 { Text(L10n.text("Standalone-Update")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if store.fileSelection != nil {
                    Button(L10n.text("Alle Dateien zeigen")) { store.fileSelection = nil; selection.removeAll(); search = "" }
                    Text(L10n.text("Prüfbefunde ausgewählt")).font(.caption).foregroundStyle(.orange)
                    if let report = store.lastInspection { Button(L10n.text("Prüfergebnis")) { store.repairReport = report } }
                }
                Button { store.addFiles(directory: destination.directory) } label: {
                    Label(L10n.text("Dateien hinzufügen …"), systemImage: "plus")
                }
                Button {
                    pendingRemoval = selectedFiles.subtracting(store.editDraft?.removals ?? [])
                    pendingNewRemoval = Set(selection.filter { $0 < 0 })
                    confirmRemoval = true
                } label: {
                    Label(L10n.text("Dateien entfernen …"), systemImage: "trash")
                }.disabled(selectedFiles.subtracting(store.editDraft?.removals ?? []).isEmpty && !selection.contains(where: { $0 < 0 }))
                if !selectedFiles.intersection(store.editDraft?.removals ?? []).isEmpty {
                    Button(L10n.text("Entfernen zurücknehmen")) { store.restoreStagedFiles(selectedFiles) }
                }
                Spacer()
                Text(L10n.text("Ziel: \(String(describing: destination.path))")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(L10n.text("Ordner in der Liste auswählen, um das Ziel für neue Dateien festzulegen."))
            }.padding(.horizontal, 24).padding(.bottom, 12).disabled(store.busy)
            Table(nodes, children: \.children, selection: $selection) {
                TableColumn(L10n.text("Name")) { node in
                    HStack(spacing: 8) {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(node.name).lineLimit(1)
                            .strikethrough(node.id >= archive.directories.count && store.editDraft?.removals.contains(node.id - archive.directories.count) == true)
                        if node.id < 0 { Image(systemName: "plus.circle.fill").foregroundStyle(.green).help(L10n.text("Hinzufügen vorgemerkt")) }
                        else if node.id >= archive.directories.count && store.editDraft?.removals.contains(node.id - archive.directories.count) == true {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.orange).help(L10n.text("Entfernen vorgemerkt"))
                        }
                    }.padding(.vertical, 3)
                }.width(min: 180, ideal: 360)
                TableColumn(L10n.text("Größe")) { node in
                    Text(size(node.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(90)
                TableColumn(L10n.text("Gespeichert")) { node in
                    Text(size(node.storedSize)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(100)
                TableColumn(L10n.text("Codec")) { node in
                    Text(node.id < 0 ? L10n.text("Neu") : (node.codec.map { $0 == 0 ? "RAW" : "ZSTD" } ?? "—"))
                        .font(.system(size: 10, design: .monospaced))
                }.width(54)
            }.padding(.horizontal, 16)
                .disabled(store.busy)
            if nodes.isEmpty {
                Text(search.isEmpty ? L10n.text("Dieses Paket ist leer.") : L10n.text("Keine passenden Dateien."))
                    .foregroundStyle(.secondary).padding()
            }
            Text(L10n.text("Dateiänderungen werden vorgemerkt. Erst Übernehmen speichert sie gemeinsam mit den Metadaten; vorhandene Dateien werden nicht neu komprimiert."))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func size(_ size: UInt64?) -> String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    }
}
