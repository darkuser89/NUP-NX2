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
        .background(SettingsWindowTitle(title: language.text("NUP Studio-Einstellungen")))
    }
}

private struct SettingsWindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) { view.title = title }

    final class TitleView: NSView {
        var title: String? { didSet { updateTitle() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateTitle()
        }

        private func updateTitle() {
            if let title, window?.title != title { window?.title = title }
        }
    }
}
