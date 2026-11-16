import AppKit

@MainActor final class WorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?
    private var showMainWindow: (() -> Void)?
    private var pendingURLs: [URL]?

    func attach(store: WorkspaceStore, showMainWindow: @escaping () -> Void) {
        self.showMainWindow = showMainWindow
        self.store = store
        deliverPendingURLs()
    }

    // Native Launch Services delivery is available before the SwiftUI view
    // appears. Retain the request until its shared workspace has been attached.
    func application(_ application: NSApplication, open urls: [URL]) { receive(urls) }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        receive(urls)
        sender.reply(toOpenOrPrint: .success)
    }
    func receive(_ urls: [URL]) {
        pendingURLs = urls
        deliverPendingURLs()
    }
    private func deliverPendingURLs() {
        guard let store, let urls = pendingURLs else { return }
        pendingURLs = nil
        // Reopen a previously closed main window as well as raising a live one.
        showMainWindow?()
        _ = store.receiveExternalFileURLs(urls)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow?() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.busy { store.status = L10n.text("Bitte den laufenden Vorgang abschließen oder abbrechen."); return .terminateCancel }
        return store.deferNavigation(.quit) ? .terminateCancel : .terminateNow
    }
}
