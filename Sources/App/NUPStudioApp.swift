import SwiftUI

@main
struct NUPStudioApp: App {
    @StateObject private var store = WorkspaceStore()

    var body: some Scene {
        Window("NUP Studio", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
                .task { store.restoreLibraryIfNeeded() }
                .onOpenURL { store.receiveFileURLs([$0]) }
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
            CommandMenu("Container") {
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
