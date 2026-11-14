import AppKit
import Combine

@MainActor
final class LibraryMetadataStore: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var completed = 0
    @Published private(set) var loading = false
    private(set) var items: [URL: LibraryItemMetadata] = [:]
    private(set) var generation = UUID()
    private let covers = NSCache<NSURL, NSImage>()
    private let loader = LibraryMetadataLoader()
    private var snapshot: LibrarySnapshot?
    private var task: Task<Void, Never>?
    private var context = JobContext()
    private var artworkRequests = Set<URL>()
    private var entryRevisions: [URL: UUID] = [:]

    init(defaults: UserDefaults) {
        // Old profile preferences must never affect the specification-only app.
        defaults.removeObject(forKey: "libraryMetadataPolicy")
        covers.totalCostLimit = 32 * 1024 * 1024
        covers.countLimit = 512
    }

    func cancel() {
        context.cancel()
        task?.cancel()
        loading = false
    }

    func load(_ snapshot: LibrarySnapshot) {
        cancel()
        self.snapshot = snapshot
        generation = UUID()
        let identifier = generation
        context = JobContext()
        let job = context
        items.removeAll(keepingCapacity: true)
        covers.removeAllObjects()
        artworkRequests.removeAll()
        entryRevisions.removeAll()
        completed = 0; loading = !snapshot.entries.isEmpty; revision += 1
        task = Task { [weak self, loader] in
            var processed = 0, unpublished = false
            let clock = ContinuousClock()
            var lastPublication = clock.now
            for entry in snapshot.entries {
                guard !Task.isCancelled else { break }
                let entryRevision = self?.entryRevisions[entry.url]
                let result: LibraryMetadataResult
                do { result = try await loader.read(entry, context: job) }
                catch is CancellationError { break }
                catch { result = LibraryMetadataResult(item: LibraryItemMetadata(notice: "Metadaten nicht lesbar: \(error.localizedDescription)")) }
                guard !Task.isCancelled, let self, self.generation == identifier else { break }
                if self.entryRevisions[entry.url] == entryRevision {
                    self.apply(result, to: entry.url, publish: false)
                    unpublished = true
                }
                processed += 1
                let now = clock.now
                // Show the first result immediately, then coalesce fast reads.
                if processed == 1 || processed % 16 == 0 || lastPublication.duration(to: now) >= .milliseconds(100) {
                    self.completed = processed
                    if unpublished { self.revision += 1; unpublished = false }
                    lastPublication = now
                }
            }
            if let self, self.generation == identifier {
                self.completed = processed
                if unpublished { self.revision += 1 }
                self.loading = false
            }
        }
    }

    func cover(for url: URL) -> NSImage? { covers.object(forKey: url as NSURL) }

    func ensureCover(for entry: LibraryEntry) {
        guard items[entry.url]?.hasCover == true, cover(for: entry.url) == nil,
              artworkRequests.insert(entry.url).inserted else { return }
        let identifier = generation, job = context, entryRevision = entryRevisions[entry.url]
        Task { [weak self, loader] in
            let result = try? await loader.read(entry, context: job)
            guard let self, self.generation == identifier else { return }
            self.artworkRequests.remove(entry.url)
            if let result, self.entryRevisions[entry.url] == entryRevision { self.apply(result, to: entry.url) }
        }
    }

    func update(_ archive: NUPArchive) {
        guard snapshot?.entries.contains(where: { $0.url == archive.url }) == true else { return }
        // Keep edits fresh without rebuilding the whole catalog or decoding images on the main thread.
        let identifier = generation, token = UUID(), url = archive.url, packages = archive.packages
        entryRevisions[url] = token
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                autoreleasepool { LibraryMetadataReader.metadata(from: packages) }
            }.value
            guard let self, self.generation == identifier, self.entryRevisions[url] == token else { return }
            self.apply(result, to: url)
        }
    }

    private func apply(_ result: LibraryMetadataResult, to url: URL, publish: Bool = true) {
        items[url] = result.item
        covers.removeObject(forKey: url as NSURL)
        if let data = result.thumbnail, let image = NSImage(data: data) {
            covers.setObject(image, forKey: url as NSURL, cost: 128 * 128 * 4)
        }
        if publish { revision += 1 }
    }
}
