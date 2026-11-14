import SwiftUI
import AppKit

enum EditorNavigation {
    case open(URL), diagnose(URL), cover(URL), create, close(Int), quit
}

extension WorkspaceStore {
    var hasPendingEdits: Bool { editDraft?.hasChanges == true }
    var canApplyEdits: Bool { hasPendingEdits && editDraft?.validationError == nil && !busy }

    func discardEdits() {
        guard !busy, let archive else { return }
        editDraft = ArchiveEditDraft(archive: archive); status = "Entwurf verworfen · NUP unverändert."
    }
    func restoreStagedFiles(_ indices: Set<Int>) { editDraft?.restoreFiles(indices) }
    func removeStagedFiles(_ nodes: Set<Int>) { editDraft?.removePending(nodes: nodes) }

    func applyEdits(destination: URL? = nil) {
        guard !busy, let draft = editDraft, draft.hasChanges || destination != nil else { return }
        if let error = draft.validationError { self.error = error; afterApply = nil; return }
        let stayInLibrary = destination == nil && section == .library
        perform(destination == nil ? "Änderungen übernehmen" : "Entwurf als neue NUP speichern") { context in
            let request = try draft.request()
            let updated: NUPArchive
            if let destination { updated = try draft.archive.saveEditsAs(request, destination: destination, context: context) }
            else { updated = try draft.archive.applyEdits(request, context: context) }
            return JobResult(message: destination == nil ? "Alle vorgemerkten Änderungen übernommen · Struktur geprüft." : "Entwurf als neue NUP gespeichert · Original unverändert.",
                             archive: updated, reveal: updated.url, preferLibrary: stayInLibrary)
        }
    }
    func requestWindowClose(_ window: NSWindow? = nil) {
        guard let window = window ?? NSApp.keyWindow else { return }
        if busy { status = "Bitte den laufenden Vorgang abschließen oder abbrechen."; return }
        if !deferNavigation(.close(window.windowNumber)) { window.performClose(nil) }
    }
    func requestQuit() {
        if busy { status = "Bitte den laufenden Vorgang abschließen oder abbrechen."; return }
        if !deferNavigation(.quit) { NSApp.terminate(nil) }
    }
    func saveDraftAs() {
        guard !busy, let archive, editDraft?.validationError == nil,
              let target = FilePanels.save(name: archive.url.deletingPathExtension().lastPathComponent + "-bearbeitet.nup", title: "Gesamten Entwurf als neue NUP speichern") else { return }
        applyEdits(destination: target)
    }

    @discardableResult func deferNavigation(_ action: EditorNavigation) -> Bool {
        guard hasPendingEdits else { return false }
        pendingNavigation = action; return true
    }
    func discardAndContinue() {
        guard !busy, let action = pendingNavigation else { return }
        pendingNavigation = nil; discardEdits(); continueNavigation(action)
    }
    func applyAndContinue() {
        guard canApplyEdits, let action = pendingNavigation else { return }
        pendingNavigation = nil; afterApply = action; applyEdits()
    }
    func continueNavigation(_ action: EditorNavigation) {
        switch action {
        case .open(let url): open(url)
        case .diagnose(let url): diagnose(url)
        case .cover(let url): requestLibraryCover(url)
        case .create: pack()
        case .close(let number): NSApp.windows.first { $0.windowNumber == number }?.performClose(nil)
        case .quit: NSApp.terminate(nil)
        }
    }
}
