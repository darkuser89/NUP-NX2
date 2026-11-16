import SwiftUI

struct AppSettingsView: View {
    @AppStorage(AppLanguage.preferenceKey) private var choice: AppLanguage = .system

    var body: some View {
        Form {
            Picker(L10n.text("Sprache der App"), selection: $choice) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.name).tag(language)
                }
            }
            LabeledContent(L10n.text("Aktive Sprache"), value: L10n.language.name)
            if choice.resolved(preferred: Locale.preferredLanguages) != L10n.language {
                Text(L10n.text("Starte NUP Studio neu, um die gewählte Sprache zu verwenden."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 165)
        .environment(\.locale, L10n.locale)
    }
}
