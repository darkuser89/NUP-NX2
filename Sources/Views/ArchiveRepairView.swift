import SwiftUI

struct ArchiveRepairView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    let report: ArchiveRepairReport
    @State private var selection: Set<ArchiveRepairTarget>
    @State private var validatedSelection: Set<ArchiveRepairTarget>?
    @State private var selectionError: String?

    init(store: WorkspaceStore, report: ArchiveRepairReport) {
        self.store = store; self.report = report
        _selection = State(initialValue: report.repairTargets)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(language.text("NUP prüfen und reparieren"), systemImage: "checkmark.shield").font(.title2.bold())
            Text(report.url.lastPathComponent).font(.headline).textSelection(.enabled)
            Text(report.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if let check = report.fileCheck, check.failed > 0 {
                        ArchiveFileFailuresView(store: store, report: report, check: check)
                        Divider()
                    }
                    if let error = report.originalError {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    ForEach(report.romfs) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            repairToggle(language.text("Paket \(String(describing: finding.package + 1)) · /romfs wieder verbinden"), target: .romfs(finding.id))
                            field(language.text("Direkte Einträge"), before: "0", after: String(finding.count))
                            Text(language.text("Vorhandene Kindknotenplätze \(String(describing: finding.first))–\(String(describing: finding.first + finding.count - 1)) sind eindeutig diesem leeren RomFS zugeordnet. TOC-SHA-256 und vollständiger Dateibaum wurden geprüft."))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(finding.names.joined(separator: ", ") + (finding.count > finding.names.count ? language.text(", …") : ""))
                                .font(.caption.monospaced()).textSelection(.enabled)
                            Text(language.text("Nur die Eintragszahl wird korrigiert; Dateien und Unterordner werden wieder erreichbar."))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(report.packages) { finding in
                        VStack(alignment: .leading, spacing: 8) {
                            if finding.changed { repairToggle(language.text("Paket \(String(describing: finding.id + 1)) · Paketangaben korrigieren"), target: .package(finding.id)) }
                            else { Text(language.text("Paket \(String(describing: finding.id + 1)) · Keine Änderung")).font(.headline) }
                            field(language.text("Titel-ID"), before: finding.before.title, after: finding.proposed.title)
                            field(language.text("Paketart"), before: finding.before.kindName(in: language),
                                  after: finding.proposed.kindName(in: language))
                            field(language.text("Interne NCM-Version"), before: finding.before.versionText, after: finding.proposed.versionText)
                            field(language.text("Standalone-Update"), before: finding.before.flags & 1 == 0 ? language.text("Nein") : language.text("Ja"),
                                  after: finding.proposed.flags & 1 == 0 ? language.text("Nein") : language.text("Ja"))
                            ForEach(finding.evidence, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    if report.repairTargets.contains(.uuid) { repairToggle(language.text("Abweichende Container-UUID korrigieren"), target: .uuid) }
                    if !report.repairTargets.isEmpty {
                        Text(language.text("Zugehörige Prüfsummen und die UUID werden passend zur Auswahl aktualisiert. Abhängige Strukturfehler müssen gemeinsam ausgewählt werden."))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(language.text("Alle Korrekturen auswählen")) { selection = report.repairTargets }
                            Button(language.text("Keine Korrektur auswählen")) { selection.removeAll() }
                        }.disabled(store.busy || !report.canRepair)
                    }
                    ForEach(report.warnings, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    ForEach(report.blockers, id: \.self) { Label($0, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
                    if report.blockers.isEmpty && !report.canRepair {
                        Label(language.text("Keine sicher korrigierbaren Abweichungen gefunden."), systemImage: "checkmark.circle")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 240, maxHeight: 500)
            Text(language.text("Die Prüfung verändert nichts und liest den gespeicherten Stand. „Auswahl reparieren“ schreibt nur ausgewählte, belegte Korrekturen direkt in dieselbe NUP; kein erneutes Packen. Defekte Dateiinhalte und ihre Hashes werden nicht umgeschrieben. Ein Rücknahmeprotokoll schützt die Reparatur."))
                .font(.caption).foregroundStyle(.secondary)
            if store.hasPendingEdits { Text(language.text("Dein Entwurf bleibt erhalten. Vor einer Reparatur Änderungen erst übernehmen oder verwerfen und erneut prüfen.")).font(.caption).foregroundStyle(.orange) }
            if let selectionError { Text(selectionError).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = store.repairError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if store.busy {
                    ProgressView(value: store.fraction).frame(width: 100)
                    Text(store.status.text(in: language)).font(.caption)
                    Spacer()
                    Button(language.text("Abbrechen"), action: store.cancel)
                } else {
                    Button(language.text("Schließen")) { store.repairReport = nil; store.repairError = nil }.keyboardShortcut(.cancelAction)
                    Button(report.deepInspection ? language.text("Erneut vollständig prüfen") : language.text("Vollständig prüfen")) { store.inspect(report.url, deep: true) }
                    Spacer()
                    Button(language.text("Auswahl reparieren (\(String(describing: selection.count)))")) { store.repair(report, selection: selection) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!report.canRepair || selection.isEmpty || validatedSelection != selection || store.hasPendingEdits)
                }
            }
        }.padding(24).frame(width: 850).interactiveDismissDisabled(store.busy)
            .task(id: selection) {
                validatedSelection = nil; selectionError = nil
                guard report.canRepair, !selection.isEmpty else { return }
                let selected = selection, snapshot = report
                do {
                    _ = try await Task.detached(priority: .userInitiated) { try snapshot.selectedLayout(selected) }.value
                    guard !Task.isCancelled else { return }
                    validatedSelection = selected
                } catch {
                    guard !Task.isCancelled else { return }
                    selectionError = error.localizedDescription
                }
            }
    }

    @ViewBuilder private var summary: some View {
        if let check = report.fileCheck {
            Label(language.text("\(String(describing: check.checked)) von \(String(describing: report.source?.files.count ?? 0)) Dateien geprüft · \(String(describing: check.failed)) Dateifehler"),
                  systemImage: check.failed == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline).foregroundStyle(check.failed == 0 ? Color.green : Color.orange)
        } else {
            Text(report.deepInspection ? language.text("Dateiinhalte konnten wegen der Strukturfehler nicht geprüft werden.") : language.text("Struktur und Paketbelege geprüft. Noch keine vollständige Prüfung der Dateiinhalte."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func repairToggle(_ title: String, target: ArchiveRepairTarget) -> some View {
        let automaticUUID = target == .uuid && selection.contains { if case .package = $0 { return true }; return false }
        return Toggle(title + (automaticUUID ? language.text(" (automatisch)") : ""), isOn: Binding(
            get: { automaticUUID || selection.contains(target) },
            set: { if $0 { selection.insert(target) } else { selection.remove(target) } }
        )).toggleStyle(.checkbox).font(.headline).disabled(store.busy || !report.canRepair || automaticUUID)
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
