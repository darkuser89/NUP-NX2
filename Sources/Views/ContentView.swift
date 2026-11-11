import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var targeted = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $store.section) {
                    Section("Arbeitsbereich") {
                        ForEach(WorkspaceSection.allCases) { section in
                            Label(section.rawValue, systemImage: section.symbol).tag(section)
                        }
                    }
                    if !store.recent.isEmpty {
                        Section("Zuletzt geöffnet") {
                            ForEach(store.recent, id: \.self) { path in
                                Button { store.open(URL(fileURLWithPath: path)) } label: {
                                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.zipper")
                                        .lineLimit(1).help(path)
                                }.buttonStyle(.plain).disabled(store.busy)
                            }
                        }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 5) {
                    Text("NUP Studio").font(.headline)
                    Text("Native auf Apple Silicon").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if store.section == .pack { PackView(store: store) }
                    else if store.section == .library { LibraryView(store: store) }
                    else if let archive = store.archive { ArchiveView(store: store, archive: archive).id(archive.snapshotID) }
                    else { WelcomeView(store: store) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar(store: store)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.openPanel) { Label("Öffnen", systemImage: "folder") }.disabled(store.busy)
                Button(action: store.chooseLibrary) { Label("NUP-Ordner", systemImage: "folder.badge.plus") }.disabled(store.busy)
                if store.archive != nil && store.section == .archive {
                    Button { store.verify(deep: true) } label: { Label("Prüfen", systemImage: "checkmark.shield") }
                        .disabled(store.busy)
                    Button { store.extract() } label: { Label("Entpacken", systemImage: "square.and.arrow.down") }
                        .disabled(store.busy)
                }
            }
        }
        .overlay {
            if targeted && store.canReceiveFiles && store.libraryCoverDraft == nil {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.1))
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc.fill").font(.system(size: 40))
                        Text("NUP-Datei hier öffnen").font(.title2.weight(.semibold))
                        Text(store.section == .pack ? "Oder einen Dump-Quellordner ablegen" : "Oder einen Ordner als NUP-Bibliothek laden")
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: store.receiveDrop)
        .alert("Vorgang fehlgeschlagen", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(item: $store.libraryCoverDraft) { draft in
            LibraryCoverEditor(store: store, draft: draft)
        }
    }
}

private struct StatusBar: View {
    @ObservedObject var store: WorkspaceStore
    @State private var showActivity = false
    var body: some View {
        HStack(spacing: 12) {
            if store.busy { ProgressView(value: store.fraction).frame(width: 100) }
            else { Image(systemName: store.fraction == 1 ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(.secondary) }
            Text(store.status).font(.caption).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            if store.busy { Button("Abbrechen", action: store.cancel).controlSize(.small) }
            else if store.lastOutput != nil { Button("Im Finder", action: store.reveal).controlSize(.small) }
            Button { showActivity.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless).help("Sitzungsprotokoll")
                .popover(isPresented: $showActivity) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Diese Sitzung").font(.headline)
                        if store.activity.isEmpty { Text("Noch keine Vorgänge.").foregroundStyle(.secondary) }
                        ForEach(Array(store.activity.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.caption).textSelection(.enabled)
                        }
                    }.padding(20).frame(width: 420)
                }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}

private struct WelcomeView: View {
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill").font(.system(size: 68, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text("Deine Pakete. Ein Ort.").font(.system(size: 30, weight: .semibold))
                Text("NUP-Container öffnen, prüfen und entpacken.\nOder einen neuen Container aus einem Dump-Ordner erstellen.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            HStack(spacing: 12) {
                Button("NUP öffnen …", action: store.openPanel).buttonStyle(.borderedProminent)
                Button("NUP-Ordner auswählen …", action: store.chooseLibrary).buttonStyle(.bordered)
                Button("Container erstellen") { store.section = .pack }.buttonStyle(.bordered)
            }.controlSize(.large).disabled(store.busy)
            Text("NUP-Datei oder NUP-Ordner aus dem Finder ins Fenster ziehen")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Label("Zstandard", systemImage: "arrow.down.right.and.arrow.up.left")
                Label("SHA-256", systemImage: "checkmark.shield")
                Label("Lokal", systemImage: "internaldrive")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 24)
        }.padding(40)
    }
}
