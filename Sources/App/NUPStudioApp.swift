import SwiftUI

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.en
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

@main
struct NUPStudioApp: App {
    @NSApplicationDelegateAdaptor(WorkspaceApplicationDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()
    @AppStorage(AppLanguage.preferenceKey) private var languageChoice: AppLanguage = .system

    var body: some Scene {
        let language = languageChoice.resolved(preferred: Locale.preferredLanguages)
        Window("NUP Studio", id: "main") {
            ContentView(store: store, applicationDelegate: appDelegate)
                .frame(minWidth: 980, minHeight: 680)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
                .task { store.restoreLibraryIfNeeded() }
                // SwiftUI owns URL delivery once its scene is running; cold
                // Launch Services requests can arrive at the delegate earlier.
                .onOpenURL { appDelegate.receive([$0]) }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(language.text("Einstellungen …")) }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button(language.text("NUP öffnen …"), action: store.openPanel)
                    .keyboardShortcut("o").disabled(store.busy)
                Button(language.text("NUP-Ordner auswählen …"), action: store.chooseLibrary)
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(store.busy)
                Button(language.text("Container erstellen …")) { store.section = .pack }
                    .keyboardShortcut("n").disabled(store.busy)
            }
            CommandGroup(replacing: .saveItem) {
                Button(language.text("Übernehmen")) { store.applyEdits() }.keyboardShortcut("s").disabled(!store.canApplyEdits)
                Button(language.text("Speichern unter …"), action: store.saveDraftAs).keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy || store.editDraft?.validationError != nil)
            }
            CommandGroup(after: .saveItem) {
                Button(language.text("Fenster schließen")) { store.requestWindowClose() }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .appTermination) {
                Button(language.text("NUP Studio beenden"), action: store.requestQuit).keyboardShortcut("q")
            }
            CommandMenu(language.text("Container")) {
                Button(language.text("NUP diagnostizieren / reparieren …"), action: store.diagnosePanel)
                    .keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.busy)
                Button(language.text("Vollständig prüfen")) { store.verify(deep: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy)
                Button(language.text("Paket entpacken …")) { store.extract() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.archive == nil || store.busy)
                Divider()
                Button(language.text("Abbrechen"), action: store.cancel).keyboardShortcut(".").disabled(!store.busy)
            }
        }
        Settings {
            AppSettingsView(choice: $languageChoice)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
        }
    }
}
