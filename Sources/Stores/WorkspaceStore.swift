import SwiftUI
import AppKit

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case archive = "Container"
    case library = "Bibliothek"
    case pack = "Erstellen"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .archive: return "shippingbox"
        case .library: return "folder"
        case .pack: return "shippingbox.and.arrow.backward"
        }
    }
}

struct JobResult: Sendable {
    var message: String
    var archive: NUPArchive? = nil
    var reveal: URL? = nil
    var library: LibrarySnapshot? = nil
    var coverDraft: LibraryCoverDraft? = nil
    var repairReport: ArchiveRepairReport? = nil
    var repaired = false
    var editDraft: ArchiveEditDraft? = nil
    var preferLibrary = false
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var section: WorkspaceSection? = .archive
    @Published var archive: NUPArchive?
    @Published var editDraft: ArchiveEditDraft?
    @Published var pendingNavigation: EditorNavigation?
    var afterApply: EditorNavigation?
    @Published var library: LibrarySnapshot?
    let libraryMetadata: LibraryMetadataStore
    @Published var libraryCoverDraft: LibraryCoverDraft?
    @Published var libraryCoverError: String?
    @Published var repairReport: ArchiveRepairReport?
    @Published var repairError: String?
    @Published var fileSelection: ArchiveFileSelection?
    @Published var lastInspection: ArchiveRepairReport?
    @Published private(set) var rememberedLibraryFolder: URL?
    @Published private(set) var libraryUnavailableMessage: String?
    @Published var packageIndex = 0
    let profile = MetadataProfile.specification
    @Published var busy = false
    @Published var fraction = 0.0
    @Published var status = "Bereit"
    @Published var error: String?
    @Published var lastOutput: URL?
    @Published var recent: [String]
    @Published var sourceFolder: URL?
    @Published var options = PackOptions()
    @Published var activity: [String] = []
    var context: JobContext?
    private var jobID: UUID?
    private let defaults: UserDefaults
    private var attemptedLibraryRestore = false
    private var restoringLibrary = false
    private var pendingOpenURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryMetadata = LibraryMetadataStore(defaults: defaults)
        recent = defaults.stringArray(forKey: "recentNUPFiles") ?? []
        if let path = defaults.string(forKey: "libraryFolderPath"), path.hasPrefix("/"), !path.contains("\0") {
            rememberedLibraryFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    func restoreLibraryIfNeeded() {
        guard !attemptedLibraryRestore else { return }
        attemptedLibraryRestore = true
        guard !busy, archive == nil, library == nil, let folder = rememberedLibraryFolder else { return }
        scanLibrary(folder, restoring: true)
    }

    func openPanel() {
        guard !busy, let url = FilePanels.archive() else { return }
        open(url)
    }

    var canReceiveFiles: Bool { pendingNavigation == nil && repairReport == nil && (!busy || restoringLibrary) }

    @discardableResult
    func receiveFileURLs(_ urls: [URL]) -> Bool {
        guard canReceiveFiles, libraryCoverDraft == nil else { return false }
        do {
            let url = try FileDropReader.validate(urls)
            if !busy && section == .pack && DumpDiscovery.isDirectory(url) {
                sourceFolder = url
                status = "Dump-Quellordner ausgewählt: \(url.lastPathComponent)"
            } else {
                open(url)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Finder events also arrive during startup, jobs and modal previews. Keep
    /// the latest valid request instead of dropping it through the drag/drop guard.
    @discardableResult
    func receiveExternalFileURLs(_ urls: [URL]) -> Bool {
        do {
            let url = try FileDropReader.validate(urls)
            if libraryCoverDraft != nil || repairReport != nil || pendingNavigation != nil {
                pendingOpenURL = url
            } else { open(url) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func drainPendingOpenIfPossible() {
        guard !busy, libraryCoverDraft == nil, repairReport == nil, pendingNavigation == nil,
              let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        open(url)
    }

    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canReceiveFiles, libraryCoverDraft == nil else { return false }
        guard providers.count == 1 else {
            error = "Bitte eine NUP-Datei oder einen Ordner auf einmal ablegen."
            return false
        }
        Task {
            do { receiveFileURLs([try await FileDropReader.url(from: providers[0])]) }
            catch { self.error = error.localizedDescription }
        }
        return true
    }

    func open(_ url: URL) {
        // An explicit Finder open takes precedence over the automatic startup scan.
        if busy {
            pendingOpenURL = url
            if restoringLibrary { context?.cancel() }
            return
        }
        if DumpDiscovery.isDirectory(url) { scanLibrary(url); return }
        if deferNavigation(.open(url)) { return }
        section = .archive
        perform("Container öffnen") { context in
            do {
                let archive = try NUPArchive(url: url, context: context)
                return JobResult(message: "\(archive.packages.count) Pakete · Struktur und TOC-Hash geprüft", archive: archive)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let report = try ArchiveDiagnosis.inspect(url, originalError: error.localizedDescription, context: context)
                return JobResult(message: "Öffnen fehlgeschlagen · Diagnose liegt vor · Datei unverändert.", repairReport: report)
            }
        }
    }
    func diagnosePanel() {
        guard !busy, let url = FilePanels.archive() else { return }
        diagnose(url)
    }
    func diagnose(_ url: URL) {
        guard !busy else { return }
        if deferNavigation(.diagnose(url)) { return }
        repairError = nil
        perform("NUP diagnostizieren") { context in
            let report = try ArchiveDiagnosis.inspect(url, context: context)
            return JobResult(message: "Diagnose abgeschlossen · Datei unverändert.", repairReport: report)
        }
    }
    func repair(_ report: ArchiveRepairReport, selection: Set<ArchiveRepairTarget>? = nil) {
        guard !busy, repairReport?.id == report.id, report.canRepair else { return }
        guard !hasPendingEdits else {
            repairError = "Bitte den Entwurf zuerst übernehmen oder verwerfen und danach erneut prüfen."
            return
        }
        repairError = nil
        perform("NUP direkt reparieren", reportFailure: { [weak self] in self?.repairError = $0 }) { context in
            let archive = try ArchiveRepair.apply(report, selection: selection, context: context)
            return JobResult(message: "Ausgewählte Korrekturen gespeichert · Struktur, TOC-Hash und UUID geprüft. Dateiinhalte unverändert; gemeldete Inhaltsfehler bleiben bestehen.",
                             archive: archive, reveal: archive.url, repaired: true)
        }
    }
    func chooseLibrary() {
        guard !busy else { return }
        Task {
            guard let url = await FilePanels.folder(title: "Ordner mit NUP-Dateien auswählen") else { return }
            scanLibrary(url)
        }
    }
    func refreshLibrary() {
        guard let folder = library?.folder ?? rememberedLibraryFolder else { chooseLibrary(); return }
        scanLibrary(folder)
    }
    func scanLibrary(_ url: URL, restoring: Bool = false) {
        guard !busy else { return }
        libraryMetadata.cancel()
        restoringLibrary = restoring
        libraryUnavailableMessage = nil
        section = .library
        let reportFailure: ((String) -> Void)? = restoring ? { [weak self] _ in
            self?.libraryUnavailableMessage = "Der gespeicherte Ordner ist momentan nicht verfügbar. Datenträger verbinden und erneut versuchen oder einen anderen Ordner auswählen."
        } : nil
        perform("NUP-Ordner durchsuchen", reportFailure: reportFailure) { context in
            let snapshot = try LibraryScanner.scan(url, context: context)
            let message = "\(snapshot.entries.count) NUP-Dateien gefunden" +
                (snapshot.warnings.isEmpty ? "" : " · \(snapshot.warnings.count) Hinweise")
            return JobResult(message: message, library: snapshot)
        }
    }
    func chooseSource() {
        Task {
            if let url = await FilePanels.folder(title: "Dump-Quellordner auswählen") { sourceFolder = url }
        }
    }
    func pack() {
        guard !busy else { return }
        if deferNavigation(.create) { return }
        guard let source = sourceFolder,
              let target = FilePanels.save(name: source.lastPathComponent + ".nup", title: "NUP-Container erstellen") else { return }
        var settings = options
        settings.profile = .specification
        let capturedSettings = settings
        perform("Container erstellen") { context in
            try NUPWriter.pack(source: source, destination: target, options: capturedSettings, context: context)
            return JobResult(message: "Container erstellt; Struktur geprüft.", archive: try NUPArchive(url: target), reveal: target)
        }
    }
    func verify(deep: Bool) {
        guard !busy, let archive else { return }
        inspect(archive.url, deep: deep)
    }
    func inspect(_ url: URL, deep: Bool) {
        guard !busy else { return }
        repairError = nil
        perform(deep ? "Dateien per SHA-256 prüfen" : "Struktur prüfen") { context in
            let report = try ArchiveInspection.inspect(url, deep: deep, context: context)
            let message = report.fileCheck.map { "\($0.checked) Dateien geprüft · \($0.failed) Dateifehler · Ergebnis liegt vor." }
                ?? "Strukturdiagnose abgeschlossen · Ergebnis liegt vor. Dateiinhalte nicht vollständig geprüft."
            return JobResult(message: message, repairReport: report)
        }
    }

    func canSelectFailedFiles(_ report: ArchiveRepairReport) -> Bool {
        guard let archive, let source = report.source else { return false }
        return archive.url.standardizedFileURL == report.url.standardizedFileURL &&
            archive.revision == source.revision && archive.header == source.header && archive.toc == source.toc
    }
    func selectFailedFiles(_ report: ArchiveRepairReport, files: Set<Int>) {
        guard !busy, canSelectFailedFiles(report), let archive else { return }
        let failures = report.fileCheck?.failures.filter { files.contains($0.id) } ?? []
        guard !failures.isEmpty, Set(failures.map(\.id)) == files, Set(failures.map(\.package)).count == 1,
              let package = failures.first?.package else { return }
        do { try archive.revision.requireCurrent(at: archive.url) }
        catch { repairError = error.localizedDescription; return }
        packageIndex = package; section = .archive
        fileSelection = ArchiveFileSelection(snapshot: archive.snapshotID, package: package,
            nodes: Set(files.map { archive.directories.count + $0 }))
        repairReport = nil; repairError = nil
    }
    func addFiles(directory: Int) {
        guard !busy, let archive,
              let location = archive.fileLocation(node: directory, package: packageIndex) else { return }
        let urls = FilePanels.filesToAdd(target: location.path)
        guard !urls.isEmpty else { return }
        editFiles(directory: directory, adding: urls)
    }
    func editFiles(directory: Int, adding: [URL] = [], removing: Set<Int> = []) {
        guard !busy, var draft = editDraft, !adding.isEmpty || !removing.isEmpty else { return }
        do {
            try draft.stageFiles(package: packageIndex, directory: directory, urls: adding, removing: removing)
            editDraft = draft; status = draft.summary
        } catch { self.error = error.localizedDescription }
    }
    func extract(subtree: String? = nil) {
        guard !busy, let archive, archive.packages.indices.contains(packageIndex) else { return }
        let index = packageIndex
        let name = archive.url.deletingPathExtension().lastPathComponent + "-" + archive.packages[index].kindName + (subtree.map { "-" + $0 } ?? "")
        guard let target = FilePanels.save(name: name, title: "Paket entpacken", folder: true) else { return }
        perform("Paket entpacken") { context in
            try archive.extract(package: index, subtree: subtree, destination: target, context: context)
            return JobResult(message: "Paket entpackt und alle geschriebenen Dateien per SHA-256 geprüft.", reveal: target)
        }
    }
    // Kept as a form API: replacingOriginal now stages changes for the shared Apply action.
    func save(changes: MetadataEdit, replacingOriginal: Bool = false) {
        guard !busy, var draft = editDraft, draft.packages.indices.contains(packageIndex) else { return }
        var package = draft.packages[packageIndex]
        package.name = changes.name; package.publisher = changes.publisher; package.displayVersion = changes.displayVersion
        if changes.removeIcon { package.icon = nil } else if let icon = changes.icon { package.icon = icon }
        package.localized = Set(changes.localizedTitles.keys).union(changes.localizedIcons.keys).sorted().map {
            LocalizedEntry(language: $0, title: changes.localizedTitles[$0] ?? "", icon: changes.localizedIcons[$0])
        }
        draft.packages[packageIndex] = package; editDraft = draft; status = draft.summary
        if !replacingOriginal { saveDraftAs() }
    }
    func requestLibraryCover(_ url: URL) {
        guard !busy else { return }
        if archive?.url.standardizedFileURL != url.standardizedFileURL && deferNavigation(.cover(url)) { return }
        libraryCoverError = nil
        if let archive, archive.url.standardizedFileURL == url.standardizedFileURL {
            libraryCoverDraft = LibraryCoverDraft(archive: archive, packageIndex: archive.packages.first(where: { $0.kind == 0 })?.id ?? 0)
            return
        }
        let stayInLibrary = section == .library
        perform("Cover-Metadaten laden") { context in
            let current = try NUPArchive(url: url, context: context)
            let index = current.packages.first(where: { $0.kind == 0 })?.id ?? 0
            return JobResult(message: "Cover auswählen und vormerken; Übernehmen speichert den gesamten Entwurf.",
                archive: current, coverDraft: LibraryCoverDraft(archive: current, packageIndex: index), preferLibrary: stayInLibrary)
        }
    }
    func saveLibraryCover(_ coverDraft: LibraryCoverDraft, package: Int, cover: Data) {
        guard !busy, var draft = editDraft, draft.archive.snapshotID == coverDraft.archive.snapshotID,
              draft.packages.indices.contains(package) else { return }
        draft.packages[package].icon = cover
        editDraft = draft; libraryCoverDraft = nil; libraryCoverError = nil
        status = "Cover vorgemerkt · Mit Übernehmen gemeinsam speichern."
    }

    func cancel() { context?.cancel(); status = "Wird abgebrochen …" }
    func reveal() { if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) } }

    func perform(_ title: String, reportFailure: ((String) -> Void)? = nil,
                         operation: @escaping @Sendable (JobContext) throws -> JobResult) {
        guard !busy else { return }
        busy = true; fraction = 0; status = title
        let identifier = UUID()
        jobID = identifier
        let job = JobContext { [weak self] progress, message in
            Task { @MainActor [weak self] in
                guard let self, self.busy, self.jobID == identifier else { return }
                self.fraction = progress; self.status = message
            }
        }
        context = job
        Task {
            var completedNavigation: EditorNavigation?
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    var result = try operation(job)
                    // Prepare the first immutable tree off the main thread; later view updates reuse it.
                    if let opened = result.archive {
                        _ = opened.browserNodes(package: 0)
                        result.editDraft = ArchiveEditDraft(archive: opened)
                    }
                    return result
                }.value
                if let scanned = result.library {
                    library = scanned; section = .library
                    rememberedLibraryFolder = scanned.folder
                    libraryUnavailableMessage = nil
                    defaults.set(scanned.folder.path, forKey: "libraryFolderPath")
                    libraryMetadata.load(scanned)
                }
                if let draft = result.coverDraft { libraryCoverDraft = draft }
                if let report = result.repairReport { self.error = nil; repairError = nil; repairReport = report; lastInspection = report }
                if result.repaired { repairReport = nil; repairError = nil }
                if let opened = result.archive {
                    fileSelection = nil
                    lastInspection = nil
                    let sameFile = archive?.url.standardizedFileURL == opened.url.standardizedFileURL
                    archive = opened
                    editDraft = result.editDraft ?? ArchiveEditDraft(archive: opened)
                    library = library?.updatingFile(opened)
                    packageIndex = sameFile ? min(packageIndex, opened.packages.count - 1) : 0
                    section = .archive
                    libraryMetadata.update(opened)
                    recent.removeAll { $0 == opened.url.path }
                    recent.insert(opened.url.path, at: 0)
                    recent = Array(recent.prefix(8))
                    defaults.set(recent, forKey: "recentNUPFiles")
                }
                if result.preferLibrary { section = .library }
                if let url = result.reveal { lastOutput = url }
                status = result.message; fraction = 1
                activity.insert(result.message, at: 0)
                if let action = afterApply { afterApply = nil; completedNavigation = action }
            } catch let failure as ArchiveEditFailure {
                afterApply = nil
                if var draft = editDraft, (try? draft.rebase(on: failure.recovered)) != nil {
                    archive = failure.recovered; editDraft = draft
                }
                if failure.underlying is CancellationError { status = "Abgebrochen · Entwurf bleibt zum Bearbeiten erhalten." }
                else {
                    if let reportFailure { reportFailure(failure.localizedDescription) }
                    else { self.error = failure.localizedDescription }
                    status = "Speichern fehlgeschlagen · Entwurf bleibt erhalten."
                }
                activity.insert(status, at: 0)
            } catch is CancellationError {
                afterApply = nil
                status = "Abgebrochen. Temporäre Ausgaben wurden entfernt."
                activity.insert(status, at: 0)
            } catch {
                afterApply = nil
                if let reportFailure { reportFailure(error.localizedDescription) }
                else { self.error = error.localizedDescription }
                status = "Vorgang fehlgeschlagen"
                activity.insert(error.localizedDescription, at: 0)
            }
            activity = Array(activity.prefix(20))
            busy = false; context = nil; jobID = nil
            restoringLibrary = false
            if let action = completedNavigation { continueNavigation(action) }
            drainPendingOpenIfPossible()
        }
    }
}
