import SwiftUI

struct ArchiveRepairView: View {
    @ObservedObject var store: WorkspaceStore
    let report: ArchiveRepairReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("NUP-Diagnose und Reparatur", systemImage: "wrench.and.screwdriver").font(.title2.bold())
            Text(report.url.lastPathComponent).font(.headline).textSelection(.enabled)
            Text(report.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = report.originalError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(report.romfs) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Paket \(finding.package + 1) · /romfs wieder verbinden", systemImage: "folder.badge.gearshape").font(.headline)
                            field("Direkte Einträge", before: "0", after: String(finding.count))
                            Text("Vorhandene Kindknotenplätze \(finding.first)–\(finding.first + finding.count - 1) sind eindeutig diesem leeren RomFS zugeordnet. TOC-SHA-256 und vollständiger Dateibaum wurden geprüft.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(finding.names.joined(separator: ", ") + (finding.count > finding.names.count ? ", …" : ""))
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Text("Nur die Eintragszahl wird korrigiert; Dateien und Unterordner werden wieder erreichbar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(report.packages) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Paket \(finding.id + 1) · \(finding.changed ? "Korrektur vorgeschlagen" : "Keine Änderung")").font(.headline)
                            field("Titel-ID", before: finding.before.title, after: finding.proposed.title)
                            field("Paketart", before: finding.before.kindName, after: finding.proposed.kindName)
                            field("Interne NCM-Version", before: finding.before.versionText, after: finding.proposed.versionText)
                            field("Standalone-Update", before: finding.before.flags & 1 == 0 ? "Nein" : "Ja",
                                  after: finding.proposed.flags & 1 == 0 ? "Nein" : "Ja")
                            ForEach(finding.evidence, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if report.uuidChanged { Label("Container-UUID wird aus den Paketangaben neu berechnet.", systemImage: "arrow.triangle.2.circlepath") }
                    ForEach(report.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    ForEach(report.blockers, id: \.self) { Label($0, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
                    if report.blockers.isEmpty && !report.canRepair {
                        Label("Keine sicher korrigierbaren Abweichungen gefunden.", systemImage: "checkmark.circle")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 200, maxHeight: 420)
            Text("Die Vorschau schreibt nichts. „Direkt reparieren“ korrigiert belegte Paketangaben, eindeutig zugeordnete RomFS-Eintragszahlen und zugehörige Prüfsummen in derselben Datei. Spieldaten und angezeigte Versionsnamen bleiben erhalten; kein erneutes Packen. Ein kleines Rücknahmeprotokoll schützt den Schreibvorgang. Ein erfolgreicher Spielstart wird damit nicht bestätigt.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.repairError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if store.busy {
                    ProgressView(value: store.fraction).frame(width: 100)
                    Text(store.status).font(.caption)
                    Spacer()
                    Button("Abbrechen", action: store.cancel)
                } else {
                    Button("Schließen") { store.repairReport = nil; store.repairError = nil }.keyboardShortcut(.cancelAction)
                    Button("Neu diagnostizieren") { store.diagnose(report.url) }
                    Spacer()
                    Button("Direkt reparieren") { store.repair(report) }
                        .buttonStyle(.borderedProminent).disabled(!report.canRepair)
                }
            }
        }.padding(24).frame(width: 720).interactiveDismissDisabled(store.busy)
    }

    private func field(_ label: String, before: String, after: String) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 170, alignment: .leading)
            Text(before).monospaced().textSelection(.enabled)
            if before != after {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(after).monospaced().foregroundStyle(.tint).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }.font(.callout)
    }
}
