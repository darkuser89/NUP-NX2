import XCTest
@testable import NUPStudio

final class AppLanguageTests: XCTestCase {
    func testSystemLanguageUsesFirstPreferenceAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["de-AT"]), .de)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["ro-MD"]), .ro)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["en-GB"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: ["fr-CA", "de-DE"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferred: []), .en)
        for choice in [AppLanguage.de, .ro, .en] {
            XCTAssertEqual(choice.resolved(preferred: ["fr-FR"]), choice)
        }
    }

    func testBundledTranslationsIncludeLabelsAndInterpolatedMessages() {
        let expected: [(AppLanguage, String, String)] = [
            (.de, "Bibliothek", "Datei 1/2: Ä.rfs"),
            (.ro, "Bibliotecă", "Fișierul 1/2: Ä.rfs"),
            (.en, "Library", "File 1/2: Ä.rfs")
        ]
        for (language, library, progress) in expected {
            let bundle = L10n.resources(for: language)
            let locale = Locale(identifier: language.rawValue)
            XCTAssertEqual(bundle.bundleURL.lastPathComponent, "\(language.rawValue).lproj")
            XCTAssertEqual(String(localized: "Bibliothek", bundle: bundle, locale: locale), library)
            let name = "Ä.rfs"
            XCTAssertEqual(String(localized: "Datei \(String(describing: 1))/\(String(describing: 2)): \(name)",
                                  bundle: bundle, locale: locale), progress)
        }
    }
}
