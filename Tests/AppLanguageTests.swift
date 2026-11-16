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
            XCTAssertEqual(bundle.bundleURL.lastPathComponent, "\(language.rawValue).lproj")
            XCTAssertEqual(language.text("Bibliothek"), library)
            let name = "Ä.rfs"
            let message = AppMessage.localized("Datei \(String(1))/\(String(2)): \(name)")
            XCTAssertEqual(message.text(in: language), progress)
        }
    }

    func testStoredStatusAndPackageTypeCanRenderInANewLanguage() {
        let status = AppMessage.localized("Bereit")
        let package = NUPPackage(id: 0)
        XCTAssertEqual(status.text(in: .de), "Bereit")
        XCTAssertEqual(status.text(in: .ro), "Gata")
        XCTAssertEqual(status.text(in: .en), "Ready")
        XCTAssertEqual(package.kindName(in: .de), "Basis")
        XCTAssertEqual(package.kindName(in: .ro), "Bază")
        XCTAssertEqual(package.kindName(in: .en), "Base")
    }
}
