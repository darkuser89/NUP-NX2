import Foundation

extension WorkspaceStore {
    func stageCover(from source: Int, to targets: [Int], onlyMissing: Bool = false) {
        guard !busy, var draft = editDraft, draft.packages.indices.contains(source),
              let icon = draft.packages[source].icon, !icon.isEmpty else { return }
        var count = 0
        for target in Set(targets) where target != source && draft.packages.indices.contains(target) {
            let current = draft.packages[target].icon
            guard current != icon, !onlyMissing || current == nil else { continue }
            draft.packages[target].icon = icon
            count += 1
        }
        guard count > 0 else { return }
        editDraft = draft
        status = count == 1 ? L10n.text("Cover für ein Paket vorgemerkt.") : L10n.text("Cover für \(String(describing: count)) Pakete vorgemerkt.")
    }

    func stageMissingApplicationText(from source: Int, to target: Int) {
        guard !busy, var draft = editDraft, source != target,
              draft.packages.indices.contains(source), draft.packages.indices.contains(target) else { return }
        let origin = draft.packages[source]
        guard draft.packages[target].fillMissing(name: origin.name, publisher: origin.publisher) else { return }
        editDraft = draft
        status = L10n.text("Titel und Publisher aus Paket \(String(describing: source + 1)) ergänzt.")
    }

    func importApplicationData(package: Int, file: URL? = nil) {
        guard !busy, let draft = editDraft, draft.packages.indices.contains(package) else { return }
        perform(L10n.text("Anwendungsdaten lesen")) { context in
            let control: ApplicationControl
            let source: String
            if let file {
                control = try ApplicationControl.read(from: file)
                source = file.lastPathComponent
            } else {
                (control, source) = try ApplicationControl.read(from: draft.archive, package: package, context: context)
            }
            try context.check()
            var updated = draft
            let changed = updated.packages[package].fillMissing(name: control.name, publisher: control.publisher,
                version: control.displayVersion, titles: control.titles)
            return JobResult(message: changed ? L10n.text("\(String(describing: source)) · Fehlende Anwendungsdaten vorgemerkt.") :
                L10n.text("\(String(describing: source)) gelesen · Keine fehlenden Anwendungsdaten zum Ergänzen."),
                editDraft: changed ? updated : nil)
        }
    }
}
