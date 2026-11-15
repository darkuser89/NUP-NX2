import SwiftUI

@main
struct NUPStudioApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        Window("NUP Studio", id: "main") {
            ContentView(store: store, applicationDelegate: appDelegate)
                .frame(minWidth: 980, minHeight: 680)
                .task { store.restoreLibraryIfNeeded() }
                // SwiftUI owns URL delivery once its scene is running; cold
                // Launch Services requests can arrive at the delegate earlier.
                .onOpenURL { appDelegate.receive([$0]) }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("NUP öffnen …", action: store.openPanel)
                    .keyboardShortcut("o").disabled(store.busy)
                Button("NUP-Ordner auswählen …", action: store.chooseLibrary)
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.busy)
                Button("Container erstellen …") { store.section = .pack }
                    .keyboardShortcut("n").disabled(store.busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Übernehmen") { store.applyEdits() }.keyboardShortcut("s").disabled(!store.canApplyEdits)
                Button("Speichern unter …", action: store.saveDraftAs).keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy || store.editDraft?.validationError != nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Fenster schließen") { store.requestWindowClose() }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .appTermination) {
                Button("NUP Studio beenden", action: store.requestQuit).keyboardShortcut("q")
            }
            CommandMenu("Container") {
                Button("NUP diagnostizieren / reparieren …", action: store.diagnosePanel)
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.busy)
                Button("Vollständig prüfen") { store.verify(deep: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy)
                Button("Paket entpacken …") { store.extract() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy)
                Divider()
                Button("Abbrechen", action: store.cancel).keyboardShortcut(".").disabled(!store.busy)
            }
        }
    }
}
