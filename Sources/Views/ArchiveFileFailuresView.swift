import SwiftUI

struct ArchiveFileFailuresView: View {
    @ObservedObject var store: WorkspaceStore
    let report: ArchiveRepairReport
    let check: ArchiveFileCheck
    @State private var selection = Set<Int>()

    private var singlePackage: Bool {
        Set(check.failures.filter { selection.contains($0.id) }.map(\.package)).count == 1
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.text("\(String(describing: check.failed)) Dateifehler"), systemImage: "exclamationmark.doc").font(.headline).foregroundStyle(.red)
            Text(L10n.text("Beschädigte Inhalte lassen sich ohne intakte Quelldatei nicht automatisch wiederherstellen. Wähle Befunde aus, um die Dateien in der Inhaltsliste zu markieren. Dabei wird nichts gelöscht."))
                .font(.caption).foregroundStyle(.secondary)
            Table(check.failures, selection: $selection) {
                TableColumn("") { failure in
                    Toggle(L10n.text("Paket \(String(describing: failure.package + 1)): \(String(describing: failure.path)) auswählen"), isOn: Binding(
                        get: { selection.contains(failure.id) },
                        set: { if $0 { selection.insert(failure.id) } else { selection.remove(failure.id) } }
                    )).labelsHidden().toggleStyle(.checkbox)
                }.width(24)
                TableColumn(L10n.text("Paket")) { failure in Text(String(failure.package + 1)) }.width(42)
                TableColumn(L10n.text("Pfad")) { failure in Text(failure.path).lineLimit(2).help(failure.path) }.width(min: 180, ideal: 250)
                TableColumn(L10n.text("Fehler")) { failure in Text(failure.message).lineLimit(3).help(failure.message) }
            }.frame(height: 210)
            HStack {
                Button(L10n.text("Alle auswählen")) { selection = Set(check.failures.map(\.id)) }
                Button(L10n.text("Keine")) { selection.removeAll() }
                Spacer()
                Button(L10n.text("In Dateiliste auswählen")) { store.selectFailedFiles(report, files: selection) }
                    .disabled(selection.isEmpty || !singlePackage || !store.canSelectFailedFiles(report))
            }.disabled(store.busy)
            if !selection.isEmpty && !singlePackage {
                Text(L10n.text("Für die Inhaltsliste bitte Dateien eines Pakets auswählen.")).font(.caption).foregroundStyle(.secondary)
            }
            if !store.canSelectFailedFiles(report) {
                Text(L10n.text("Die Inhaltsliste ist nur für den unverändert geöffneten Container verfügbar. Die Befunde bleiben hier lesbar."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if check.failed > check.failures.count {
                Text(L10n.text("Alle Dateien wurden geprüft. Angezeigt werden die ersten \(String(describing: check.failures.count)) Dateifehler."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
