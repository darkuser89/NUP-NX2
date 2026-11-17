import AppKit

/// SwiftUI's standard menu captions follow the macOS language. Rename the
/// existing AppKit items so their native actions and validation stay connected.
@MainActor final class NativeMenuLocalization: NSObject {
    private var language = AppLanguage.en
    private var refreshScheduled = false
    private var isRefreshing = false

    override init() {
        super.init()
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
    }

    func update(_ language: AppLanguage) {
        self.language = language
        scheduleRefresh()
    }

    @objc private func menuChanged(_ notification: Notification) {
        guard !isRefreshing, let mainMenu = NSApp?.mainMenu, let menu = notification.object as? NSMenu,
              menu === mainMenu || menu.supermenu === mainMenu else { return }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        // SwiftUI can rebuild the menu in the same update as a language change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.isRefreshing = true
            Self.localize(NSApp, in: self.language)
            self.isRefreshing = false
        }
    }

    static func localize(_ app: NSApplication, in language: AppLanguage) {
        guard let menu = app.mainMenu else { return }
        let command = NSEvent.ModifierFlags.command
        let items = menu.items

        for (index, item) in items.enumerated() {
            guard let submenu = item.submenu else { continue }
            if submenu === app.windowsMenu {
                rename(item, to: language.text("Fenster"))
            } else if submenu === app.helpMenu {
                rename(item, to: language.text("Hilfe"))
            } else if submenu.items.contains(where: { $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == command }) {
                rename(item, to: language.text("Ablage"))
            } else if submenu.items.contains(where: { $0.action == #selector(NSText.copy(_:)) }) {
                rename(item, to: language.text("Bearbeiten"))
                // SwiftUI puts the standard View menu between Edit and our
                // Container commands, even if View has no items in this window.
                if index + 2 < items.count, items[index + 2].title == language.text("Container") {
                    rename(items[index + 1], to: language.text("Darstellung"))
                }
            }

            for entry in submenu.items {
                if let services = app.servicesMenu, entry.submenu === services {
                    rename(entry, to: language.text("Dienste"))
                } else if entry.keyEquivalent == "," && entry.keyEquivalentModifierMask == command {
                    rename(entry, to: language.text("Einstellungen …"))
                } else if let title = title(for: entry.action, in: language) {
                    rename(entry, to: title)
                }
            }
        }
    }

    private static func title(for action: Selector?, in language: AppLanguage) -> String? {
        guard let action else { return nil }
        switch NSStringFromSelector(action) {
        case "orderFrontStandardAboutPanel:": return language.text("Über NUP Studio")
        case "hide:": return language.text("NUP Studio ausblenden")
        case "hideOtherApplications:": return language.text("Andere ausblenden")
        case "unhideAllApplications:": return language.text("Alle einblenden")
        case "undo:": return language.text("Widerrufen")
        case "redo:": return language.text("Wiederholen")
        case "cut:": return language.text("Ausschneiden")
        case "copy:": return language.text("Kopieren")
        case "paste:": return language.text("Einsetzen")
        case "delete:": return language.text("Löschen")
        case "selectAll:": return language.text("Alles auswählen")
        case "startDictation:": return language.text("Diktat starten …")
        case "orderFrontCharacterPalette:": return language.text("Emoji & Symbole")
        case "toggleSidebar:": return language.text("Seitenleiste ein-/ausblenden")
        case "performMiniaturize:": return language.text("Im Dock ablegen")
        case "performZoom:": return language.text("Zoomen")
        case "arrangeInFront:": return language.text("Alle nach vorne bringen")
        case "showHelp:": return language.text("NUP Studio-Hilfe")
        default: return nil
        }
    }

    private static func rename(_ item: NSMenuItem, to title: String) {
        if item.title != title { item.title = title }
        if let submenu = item.submenu, submenu.title != title { submenu.title = title }
    }
}
