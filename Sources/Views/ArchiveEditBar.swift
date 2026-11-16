import SwiftUI

struct ArchiveEditBar: View {
    @ObservedObject var store: WorkspaceStore
    @State private var confirmDiscard = false
    var body: some View {
        if let draft = store.editDraft {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.archive.url.lastPathComponent).font(.caption).lineLimit(1)
                    if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.red) }
                    else { Text(draft.hasChanges ? draft.summary : L10n.text("Keine vorgemerkten Änderungen"))
                        .font(.caption).foregroundStyle(draft.hasChanges ? .primary : .secondary).lineLimit(2) }
                }
                Spacer(minLength: 12)
                Button(L10n.text("Speichern unter …"), action: store.saveDraftAs)
                    .help(L10n.text("Erstellt eine vollständige neue NUP einschließlich der Spieldaten. Übernehmen bearbeitet die Originaldatei direkt.")).disabled(store.busy || draft.validationError != nil)
                Button(L10n.text("Verwerfen")) { confirmDiscard = true }.disabled(!draft.hasChanges || store.busy)
                Button(L10n.text("Übernehmen")) { store.applyEdits() }.buttonStyle(.borderedProminent).disabled(!store.canApplyEdits)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .confirmationDialog(L10n.text("Vorgemerkte Änderungen verwerfen?"), isPresented: $confirmDiscard) {
                    Button(L10n.text("Verwerfen"), role: .destructive, action: store.discardEdits)
                } message: { Text(L10n.text("Nur der ungespeicherte Entwurf wird zurückgesetzt. Die NUP bleibt unverändert.")) }
        }
    }
}
