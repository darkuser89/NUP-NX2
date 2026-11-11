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

    private struct Query: Equatable {
        let archive: UUID
        let package: Int
        let text: String
    }

    private var package: NUPPackage { archive.packages[min(store.packageIndex, archive.packages.count - 1)] }
    private var destination: ArchiveFileLocation {
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
                Picker("Ansicht", selection: $tab) {
                    Text("Inhalte").tag(0)
                    Text("Metadaten").tag(1)
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                if tab == 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Dateien suchen", text: $search).textFieldStyle(.plain)
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
        .task(id: Query(archive: archive.snapshotID, package: package.id, text: search)) {
            let index = package.id, query = search, snapshot = archive
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(140)) }
            guard !Task.isCancelled else { return }
            let filtered = await Task.detached(priority: .userInitiated) {
                BrowserTreeSearch.matching(snapshot.browserNodes(package: index), query: query)
            }.value
            guard !Task.isCancelled else { return }
            nodes = filtered
        }
        .onChange(of: store.packageIndex) { _, _ in selection.removeAll() }
        .onChange(of: archive.snapshotID) { _, _ in selection.removeAll() }
        .confirmationDialog("\(pendingRemoval.count) Datei(en) aus der NUP entfernen?", isPresented: $confirmRemoval) {
            Button("Dateien entfernen", role: .destructive) {
                store.editFiles(directory: package.root, removing: pendingRemoval)
            }
        } message: {
            let names = pendingRemoval.sorted().prefix(5).map { String(archive.files[$0].name.prefix(100)) }.joined(separator: "\n")
            Text("\(names)\n\nDie Dateien werden aus dem Paket entfernt. Ihre bisherigen Datenblöcke können in der NUP verbleiben; die Dateigröße wird dabei nicht verkleinert.")
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.library != nil {
                Button { store.section = .library } label: { Label("Zur Bibliothek", systemImage: "folder") }
                    .buttonStyle(.borderless).font(.caption)
            }
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let data = package.metadata[store.profile.type(3)], let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else { Image(systemName: "shippingbox.fill").resizable().scaledToFit().padding(12).foregroundStyle(.tint) }
                }.frame(width: 64, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 13)).clipShape(RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    let name = package.text(5, profile: store.profile)
                    Text(name.isEmpty ? archive.url.deletingPathExtension().lastPathComponent : name)
                        .font(.system(size: 25, weight: .semibold)).lineLimit(1).textSelection(.enabled)
                    Text(archive.url.lastPathComponent).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("\(archive.packages.count) Pakete · \(archive.files.count) Dateien · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: archive.fileSize), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Struktur prüfen") { store.verify(deep: false) }
                    Button("Vollständig mit SHA-256 prüfen") { store.verify(deep: true) }
                    Divider()
                    Button("Paket entpacken …") { store.extract() }
                    Button("Nur ExeFS entpacken …") { store.extract(subtree: "exefs") }.disabled(package.exefs == nil)
                    Button("Nur RomFS entpacken …") { store.extract(subtree: "romfs") }.disabled(package.romfs == nil)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24).disabled(store.busy)
            }
            HStack(spacing: 24) {
                Picker("Paket", selection: $store.packageIndex) {
                    ForEach(archive.packages) { package in
                        Text("\(package.id + 1) · \(package.kindName) · \(package.versionString)").tag(package.id)
                    }
                }.frame(maxWidth: 300).disabled(store.busy)
                LabeledContent("Titel-ID") { Text(package.titleIDString).monospaced().textSelection(.enabled) }.font(.caption)
                if package.flags & 1 != 0 { Text("Standalone-Update").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var fileBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.addFiles(directory: destination.directory) } label: {
                    Label("Dateien hinzufügen …", systemImage: "plus")
                }
                Button { pendingRemoval = selectedFiles; confirmRemoval = true } label: {
                    Label("Dateien entfernen …", systemImage: "trash")
                }.disabled(selectedFiles.isEmpty)
                Spacer()
                Text("Ziel: \(destination.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Ordner in der Liste auswählen, um das Ziel für neue Dateien festzulegen.")
            }.padding(.horizontal, 24).padding(.bottom, 12).disabled(store.busy)
            Table(nodes, children: \.children, selection: $selection) {
                TableColumn("Name") { node in
                    HStack(spacing: 8) {
                        Image(systemName: node.isDirectory ? "folder.fill" : "doc")
                            .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                            .frame(width: 18)
                        Text(node.name).lineLimit(1)
                    }.padding(.vertical, 3)
                }.width(min: 180, ideal: 360)
                TableColumn("Größe") { node in
                    Text(size(node.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(90)
                TableColumn("Gespeichert") { node in
                    Text(size(node.storedSize)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                }.width(100)
                TableColumn("Codec") { node in
                    Text(node.codec.map { $0 == 0 ? "RAW" : "ZSTD" } ?? "—")
                        .font(.system(size: 10, design: .monospaced))
                }.width(54)
            }.padding(.horizontal, 16)
                .disabled(store.busy)
            if nodes.isEmpty {
                Text(search.isEmpty ? "Dieses Paket ist leer." : "Keine passenden Dateien.")
                    .foregroundStyle(.secondary).padding()
            }
            Text("Ordner auswählen, um dort Dateien hinzuzufügen. Vorhandene Dateien werden nicht neu komprimiert.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func size(_ size: UInt64?) -> String {
        size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    }
}
