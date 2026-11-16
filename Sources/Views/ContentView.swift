import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    let applicationDelegate: WorkspaceApplicationDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var targeted = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $store.section) {
                    Section(language.text("Arbeitsbereich")) {
                        ForEach(WorkspaceSection.allCases) { section in
                            Label(section.title(in: language), systemImage: section.symbol).tag(section)
                        }
                    }
                    if !store.recent.isEmpty {
                        Section(language.text("Zuletzt geöffnet")) {
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
                    Text(language.text("Native auf Apple Silicon")).font(.caption).foregroundStyle(.secondary)
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
                ArchiveEditBar(store: store)
                StatusBar(store: store)
            }
        }
        .onAppear {
            let action = openWindow
            applicationDelegate.attach(store: store, showMainWindow: { action(id: "main") })
        }
        .onChange(of: store.libraryCoverDraft == nil) { _, _ in store.drainPendingOpenIfPossible() }
        .onChange(of: store.repairReport == nil) { _, _ in store.drainPendingOpenIfPossible() }
        .onChange(of: store.pendingNavigation == nil) { _, _ in store.drainPendingOpenIfPossible() }
        .toolbar {
            ToolbarItemGroup {
                Button(action: store.openPanel) { Label(language.text("Öffnen"), systemImage: "folder") }.disabled(store.busy)
                Button(action: store.chooseLibrary) { Label(language.text("NUP-Ordner"), systemImage: "folder.badge.plus") }.disabled(store.busy)
                Button {
                    if let archive = store.archive, store.section == .archive { store.inspect(archive.url, deep: false) }
                    else { store.diagnosePanel() }
                } label: { Label(language.text("Diagnose / Reparatur"), systemImage: "wrench.and.screwdriver") }.disabled(store.busy)
                if store.archive != nil && store.section == .archive {
                    Button { store.verify(deep: true) } label: { Label(language.text("Prüfen"), systemImage: "checkmark.shield") }
                        .disabled(store.busy)
                    Button { store.extract() } label: { Label(language.text("Entpacken"), systemImage: "square.and.arrow.down") }
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
                        Text(language.text("NUP-Datei hier öffnen")).font(.title2.weight(.semibold))
                        Text(store.section == .pack ? language.text("Oder einen Dump-Quellordner ablegen") : language.text("Oder einen Ordner als NUP-Bibliothek laden"))
                            .foregroundStyle(.secondary)
                    }
                    .padding(28)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .background(WorkspaceWindowGuard(store: store))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted, perform: store.receiveDrop)
        .alert(language.text("Vorgang fehlgeschlagen"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(language.text("OK")) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog(language.text("Nicht übernommene Änderungen"), isPresented: Binding(get: { store.pendingNavigation != nil }, set: { if !$0 { store.pendingNavigation = nil } }), titleVisibility: .visible) {
            Button(language.text("Übernehmen und fortfahren"), action: store.applyAndContinue).disabled(!store.canApplyEdits)
            Button(language.text("Verwerfen und fortfahren"), role: .destructive, action: store.discardAndContinue)
            Button(language.text("Abbrechen"), role: .cancel) { store.pendingNavigation = nil }
        } message: { Text(language.text("Metadaten und Dateiänderungen sind noch nicht gespeichert. Dein Entwurf bleibt bis zur Auswahl erhalten.")) }
        .sheet(item: $store.libraryCoverDraft) { draft in
            LibraryCoverEditor(store: store, draft: draft)
        }
        .sheet(item: $store.repairReport) { report in
            ArchiveRepairView(store: store, report: report).id(report.id)
        }
    }
}

private struct StatusBar: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    @State private var showActivity = false
    var body: some View {
        HStack(spacing: 12) {
            if store.busy { ProgressView(value: store.fraction).frame(width: 100) }
            else { Image(systemName: store.fraction == 1 ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(.secondary) }
            Text(store.status.text(in: language)).font(.caption).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 8)
            if store.busy { Button(language.text("Abbrechen"), action: store.cancel).controlSize(.small) }
            else if store.lastOutput != nil { Button(language.text("Im Finder"), action: store.reveal).controlSize(.small) }
            Button { showActivity.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                .buttonStyle(.borderless).help(language.text("Sitzungsprotokoll"))
                .popover(isPresented: $showActivity) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(language.text("Diese Sitzung")).font(.headline)
                        if store.activity.isEmpty { Text(language.text("Noch keine Vorgänge.")).foregroundStyle(.secondary) }
                        ForEach(Array(store.activity.enumerated()), id: \.offset) { _, message in
                            Text(message.text(in: language)).font(.caption).textSelection(.enabled)
                        }
                    }.padding(20).frame(width: 420)
                }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
}

private struct WelcomeView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.fill").font(.system(size: 68, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 10) {
                Text(language.text("Deine Pakete. Ein Ort.")).font(.system(size: 30, weight: .semibold))
                Text(language.text("NUP-Container öffnen, prüfen und entpacken.\nOder einen neuen Container aus einem Dump-Ordner erstellen."))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
            }
            HStack(spacing: 12) {
                Button(language.text("NUP öffnen …"), action: store.openPanel).buttonStyle(.borderedProminent)
                Button(language.text("NUP-Ordner auswählen …"), action: store.chooseLibrary).buttonStyle(.bordered)
                Button(language.text("Container erstellen")) { store.section = .pack }.buttonStyle(.bordered)
            }.controlSize(.large).disabled(store.busy)
            Text(language.text("NUP-Datei oder NUP-Ordner aus dem Finder ins Fenster ziehen"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Label(language.text("Zstandard"), systemImage: "arrow.down.right.and.arrow.up.left")
                Label(language.text("SHA-256"), systemImage: "checkmark.shield")
                Label(language.text("Lokal"), systemImage: "internaldrive")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 24)
        }.padding(40)
    }
}
