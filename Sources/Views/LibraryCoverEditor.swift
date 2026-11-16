import SwiftUI
import UniformTypeIdentifiers

struct LibraryCoverEditor: View {
    @ObservedObject var store: WorkspaceStore
    let draft: LibraryCoverDraft
    @State private var packageIndex: Int
    @State private var chosen: LibraryCoverImage?
    @State private var preview: NSImage?
    @State private var imageLoading = false
    @State private var choosingImage = false
    @State private var imageError: String?

    init(store: WorkspaceStore, draft: LibraryCoverDraft) {
        self.store = store
        self.draft = draft
        _packageIndex = State(initialValue: draft.packageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("Cover vormerken")).font(.title2.bold())
            Text(draft.archive.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack(alignment: .top, spacing: 22) {
                Group {
                    if let preview { Image(nsImage: preview).resizable().scaledToFit() }
                    else { Image(systemName: "photo.badge.plus").font(.system(size: 48)).foregroundStyle(.secondary) }
                }.frame(width: 150, height: 150).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 12) {
                    Picker(L10n.text("Paket"), selection: $packageIndex) {
                        ForEach(draft.archive.packages) { package in
                            Text("\(package.id + 1) · \(package.kindName) · \(package.versionString)").tag(package.id)
                        }
                    }
                    LabeledContent(L10n.text("Metadaten-Format"), value: L10n.text("Spezifikation v1"))
                    Button(L10n.text("Bild auswählen …")) { choosingImage = true }
                    Text(L10n.text("PNG oder JPEG · maximal 16 MiB")).font(.caption).foregroundStyle(.secondary)
                    if imageLoading { ProgressView().controlSize(.small) }
                }.disabled(store.busy || imageLoading)
            }
            Text(L10n.text("Das Cover wird im gemeinsamen Entwurf vorgemerkt. Erst Übernehmen speichert Cover, Metadaten und Dateiänderungen gemeinsam in der NUP."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = imageError ?? store.libraryCoverError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if store.busy { ProgressView(value: store.fraction).frame(width: 100) }
                Spacer()
                Button(L10n.text("Abbrechen")) {
                    if store.busy { store.cancel() }
                    else { store.libraryCoverDraft = nil }
                }.disabled(imageLoading)
                Button(L10n.text("Cover vormerken")) {
                    guard let chosen else { return }
                    store.saveLibraryCover(draft, package: packageIndex, cover: chosen.data)
                }.buttonStyle(.borderedProminent).disabled(chosen == nil || store.busy || imageLoading)
            }
        }
        .padding(24).frame(width: 610)
        .interactiveDismissDisabled(store.busy || imageLoading)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { loadImage(url) }
            case .failure(let error): imageError = error.localizedDescription
            }
        }
    }

    private func loadImage(_ url: URL) {
        imageLoading = true; imageError = nil
        let access = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                imageLoading = false
            }
            do {
                let image = try await Task.detached(priority: .userInitiated) { try LibraryCoverService.loadImage(url) }.value
                chosen = image; preview = NSImage(data: image.thumbnail)
            } catch { imageError = error.localizedDescription }
        }
    }
}
