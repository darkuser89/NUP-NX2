import SwiftUI

struct AppSettingsView: View {
    @Environment(\.appLanguage) private var language
    @Binding var choice: AppLanguage

    var body: some View {
        Form {
            Picker(language.text("Sprache der App"), selection: $choice) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.name(in: language)).tag(option)
                }
            }
            LabeledContent(language.text("Aktive Sprache"), value: language.name(in: language))
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 135)
    }
}
