import AppKit
import XCTest
@testable import NUPStudio

final class AppLanguageTests: XCTestCase {
    @MainActor func testNativeMenusSwitchLanguageAndKeepShortcuts() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let command = NSEvent.ModifierFlags.command
        let settingsItems = menu.items.flatMap { $0.submenu?.items ?? [] }
            .filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == command }
        XCTAssertEqual(settingsItems.count, 1)
        let settings = try XCTUnwrap(settingsItems.first)
        let open = try XCTUnwrap(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == command })
        let settingsAction = settings.action
        let openAction = open.action
        defer { NativeMenuLocalization.localize(NSApp, in: L10n.language) }

        let expected: [(AppLanguage, [String], String)] = [
            (.de, ["Ablage", "Bearbeiten", "Darstellung", "Fenster", "Hilfe"], "Einstellungen …"),
            (.ro, ["Fișier", "Editare", "Vizualizare", "Fereastră", "Ajutor"], "Configurări…"),
            (.en, ["File", "Edit", "View", "Window", "Help"], "Settings…")
        ]
        for (language, titles, settingsTitle) in expected {
            NativeMenuLocalization.localize(NSApp, in: language)
            for title in titles {
                XCTAssertTrue(menu.items.contains { $0.title == title }, title)
            }
            XCTAssertEqual(settings.title, settingsTitle)
            XCTAssertEqual(settings.action, settingsAction)
            XCTAssertEqual(settings.keyEquivalent, ",")
            XCTAssertEqual(open.action, openAction)
            XCTAssertEqual(open.keyEquivalent, "o")
        }
    }

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
