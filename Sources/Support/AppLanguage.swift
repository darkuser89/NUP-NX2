import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
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

    func name(in language: Self) -> String {
        switch self {
        case .system: language.text("Systemsprache")
        case .de: "Deutsch"
        case .ro: "Română"
        case .en: "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: L10n.resources(for: self), locale: locale)
    }
}

enum L10n {
    static var language: AppLanguage {
        let choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
        return choice.resolved(preferred: Locale.preferredLanguages)
    }

    private static let bundles = Dictionary(uniqueKeysWithValues: [AppLanguage.de, .ro, .en].compactMap { language -> (AppLanguage, Bundle)? in
        guard let url = Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return nil }
        return (language, bundle)
    })

    static func resources(for language: AppLanguage) -> Bundle {
        bundles[language] ?? bundles[.en] ?? .main
    }

    static func text(_ value: String.LocalizationValue) -> String {
        language.text(value)
    }
}

/// Keep the translation key and interpolation values until the message is shown.
enum AppMessage: Sendable {
    case localized(String.LocalizationValue)
    case verbatim(String)

    func text(in language: AppLanguage) -> String {
        switch self {
        case .localized(let value): language.text(value)
        case .verbatim(let value): value
        }
    }
}
