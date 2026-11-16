import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, ro, en

    static let preferenceKey = "appLanguage"
    var id: Self { self }

    func resolved(preferred: [String]) -> Self {
        guard self == .system else { return self }
        guard let identifier = preferred.first,
              let code = Locale(identifier: identifier).language.languageCode?.identifier,
              let language = Self(rawValue: code), language != .system else { return .en }
        return language
    }

    var name: String {
        switch self {
        case .system: L10n.text("Systemsprache")
        case .de: "Deutsch"
        case .ro: "Română"
        case .en: "English"
        }
    }
}

enum L10n {
    static let language = (AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "")
        ?? .system).resolved(preferred: Locale.preferredLanguages)
    static let locale = Locale(identifier: language.rawValue)
    private static let bundle = resources(for: language)

    static func resources(for language: AppLanguage) -> Bundle {
        for code in [language.rawValue, "en"] {
            if let url = Bundle.main.url(forResource: code, withExtension: "lproj"), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return .main
    }

    static func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle, locale: locale)
    }
}
