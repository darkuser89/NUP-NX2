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
    var updatedLibraryArchive: NUPArchive? = nil
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var section: WorkspaceSection? = .archive
    @Published var archive: NUPArchive?
    @Published var library: LibrarySnapshot?
    let libraryMetadata: LibraryMetadataStore
    @Published var libraryCoverDraft: LibraryCoverDraft?
    @Published var libraryCoverError: String?
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

    var canReceiveFiles: Bool { !busy || restoringLibrary }

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
        if busy && restoringLibrary {
            pendingOpenURL = url
            context?.cancel()
            return
        }
        guard !busy else { return }
        if DumpDiscovery.isDirectory(url) { scanLibrary(url); return }
        section = .archive
        perform("Container öffnen") { context in
            let archive = try NUPArchive(url: url, context: context)
            return JobResult(message: "\(archive.packages.count) Pakete · Struktur und TOC-Hash geprüft", archive: archive)
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
        guard !busy, let source = sourceFolder,
              let target = FilePanels.save(name: source.lastPathComponent + ".nup", title: "NUP-Container erstellen") else { return }
        var settings = options
        settings.profile = .specification
        perform("Container erstellen") { context in
            try NUPWriter.pack(source: source, destination: target, options: settings, context: context)
            return JobResult(message: "Container erstellt; Struktur geprüft.", archive: try NUPArchive(url: target), reveal: target)
        }
    }
    func verify(deep: Bool) {
        guard !busy, let archive else { return }
        perform(deep ? "Dateien per SHA-256 prüfen" : "Struktur prüfen") { context in
            try archive.verify(deep: deep, context: context)
            return JobResult(message: deep ? "Vollständig geprüft: Struktur, TOC und alle \(archive.files.count) Datei-Hashes stimmen." : "Struktur, TOC-Hash und Paket-UUID geprüft. Dateiinhalte wurden nicht gehasht.")
        }
    }
    func addFiles(directory: Int) {
        guard !busy, let archive,
              let location = archive.fileLocation(node: directory, package: packageIndex) else { return }
        let urls = FilePanels.filesToAdd(target: location.path)
        guard !urls.isEmpty else { return }
        editFiles(directory: directory, adding: urls)
    }
    func editFiles(directory: Int, adding: [URL] = [], removing: Set<Int> = []) {
        guard !busy, let archive, !adding.isEmpty || !removing.isEmpty else { return }
        let index = packageIndex
        perform(adding.isEmpty ? "Dateien entfernen" : "Dateien hinzufügen") { context in
            let updated = try archive.editFiles(package: index, directory: directory,
                                                adding: adding, removing: removing, context: context)
            let message = "\(adding.count) hinzugefügt · \(removing.count) entfernt · vorhandene Dateien nicht neu komprimiert."
            return JobResult(message: message, archive: updated, reveal: updated.url)
        }
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
    func save(changes: MetadataEdit, replacingOriginal: Bool = false) {
        guard !busy, let archive else { return }
        let index = packageIndex
        let selectedProfile = profile
        let target: URL
        if replacingOriginal { target = archive.url }
        else {
            guard let chosen = FilePanels.save(name: archive.url.deletingPathExtension().lastPathComponent + "-bearbeitet.nup", title: "Bearbeiteten Container speichern") else { return }
            target = chosen
        }
        perform(replacingOriginal ? "Metadaten aktualisieren" : "Metadaten speichern") { context in
            try archive.saveMetadata(package: index, changes: changes, profile: selectedProfile,
                                     destination: target, replacingOriginal: replacingOriginal, context: context)
            let message = replacingOriginal ? "Metadaten direkt aktualisiert; Struktur geprüft." : "Metadaten als neue Datei gespeichert; Struktur geprüft."
            return JobResult(message: message, archive: try NUPArchive(url: target), reveal: target)
        }
    }
    func requestLibraryCover(_ url: URL) {
        guard !busy else { return }
        libraryCoverError = nil
        perform("Cover-Metadaten laden") { context in
            let current = try NUPArchive(url: url, context: context)
            let index = current.packages.first(where: { $0.kind == 0 })?.id ?? 0
            return JobResult(message: "Bild für das ausgewählte Paket auswählen.",
                coverDraft: LibraryCoverDraft(archive: current, packageIndex: index))
        }
    }

    func saveLibraryCover(_ draft: LibraryCoverDraft, package: Int, cover: Data) {
        guard !busy else { return }
        libraryCoverError = nil
        perform("Cover direkt speichern", reportFailure: { [weak self] in self?.libraryCoverError = $0 }) { context in
            let updated = try LibraryCoverService.save(cover, in: draft.archive, package: package, profile: .specification, context: context)
            return JobResult(message: "Cover direkt in der NUP gespeichert · Spielinhalte nicht kopiert.", updatedLibraryArchive: updated)
        }
    }

    func cancel() { context?.cancel(); status = "Wird abgebrochen …" }
    func reveal() { if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) } }

    private func perform(_ title: String, reportFailure: ((String) -> Void)? = nil,
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
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let result = try operation(job)
                    // Prepare the first immutable tree off the main thread; later view updates reuse it.
                    if let opened = result.archive { _ = opened.browserNodes(package: 0) }
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
                if let updated = result.updatedLibraryArchive {
                    libraryCoverDraft = nil; libraryCoverError = nil
                    library = library?.updatingFile(updated)
                    libraryMetadata.update(updated)
                    if archive?.url == updated.url { archive = updated }
                }
                if let opened = result.archive {
                    let sameFile = archive?.url.standardizedFileURL == opened.url.standardizedFileURL
                    archive = opened
                    library = library?.updatingFile(opened)
                    packageIndex = sameFile ? min(packageIndex, opened.packages.count - 1) : 0
                    section = .archive
                    libraryMetadata.update(opened)
                    recent.removeAll { $0 == opened.url.path }
                    recent.insert(opened.url.path, at: 0)
                    recent = Array(recent.prefix(8))
                    defaults.set(recent, forKey: "recentNUPFiles")
                }
                if let url = result.reveal { lastOutput = url }
                status = result.message; fraction = 1
                activity.insert(result.message, at: 0)
            } catch is CancellationError {
                status = "Abgebrochen. Temporäre Ausgaben wurden entfernt."
                activity.insert(status, at: 0)
            } catch {
                if let reportFailure { reportFailure(error.localizedDescription) }
                else { self.error = error.localizedDescription }
                status = "Vorgang fehlgeschlagen"
                activity.insert(error.localizedDescription, at: 0)
            }
            activity = Array(activity.prefix(20))
            busy = false; context = nil; jobID = nil
            restoringLibrary = false
            if let url = pendingOpenURL {
                pendingOpenURL = nil
                open(url)
            }
        }
    }
}
