import SwiftUI

struct ArchiveEditBar: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WorkspaceStore
    @State private var confirmDiscard = false
    var body: some View {
        if let draft = store.editDraft {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.archive.url.lastPathComponent).font(.caption).lineLimit(1)
                    if let error = draft.validationError { Text(error).font(.caption).foregroundStyle(.red) }
                    else { Text(draft.hasChanges ? draft.summary.text(in: language) : language.text("Keine vorgemerkten Änderungen"))
                        .font(.caption).foregroundStyle(draft.hasChanges ? .primary : .secondary).lineLimit(2) }
                }
                Spacer(minLength: 12)
                Button(language.text("Speichern unter …"), action: store.saveDraftAs)
                    .help(language.text("Erstellt eine vollständige neue NUP einschließlich der Spieldaten. Übernehmen bearbeitet die Originaldatei direkt.")).disabled(store.busy || draft.validationError != nil)
                Button(language.text("Verwerfen")) { confirmDiscard = true }.disabled(!draft.hasChanges || store.busy)
                Button(language.text("Übernehmen")) { store.applyEdits() }.buttonStyle(.borderedProminent).disabled(!store.canApplyEdits)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .confirmationDialog(language.text("Vorgemerkte Änderungen verwerfen?"), isPresented: $confirmDiscard) {
                    Button(language.text("Verwerfen"), role: .destructive, action: store.discardEdits)
                } message: { Text(language.text("Nur der ungespeicherte Entwurf wird zurückgesetzt. Die NUP bleibt unverändert.")) }
        }
    }
}
