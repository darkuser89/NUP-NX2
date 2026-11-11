import SwiftUI

struct LibraryGameRow: View {
    let entry: LibraryEntry
    @ObservedObject var metadata: LibraryMetadataStore
    var editCover: () -> Void
    @State private var cover: NSImage?
    @State private var generation: UUID?

    var body: some View {
        let item = metadata.items[entry.url]
        HStack(spacing: 11) {
            Button(action: editCover) {
                Group {
                    if let cover { Image(nsImage: cover).resizable().scaledToFit() }
                    else { Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.tint) }
                }
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
                .accessibilityLabel(item?.hasCover == true ? "Cover ändern" : "Cover hinzufügen")
                .help("Cover auswählen und direkt in dieser NUP speichern")
            VStack(alignment: .leading, spacing: 3) {
                Text(item?.title ?? entry.url.deletingPathExtension().lastPathComponent)
                    .fontWeight(.medium).lineLimit(1)
                Text(entry.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let notice = item?.notice {
                Image(systemName: "info.circle").foregroundStyle(.secondary).help(notice)
            }
        }
        .padding(.vertical, 5)
        .help(item?.title.map { $0 + "\n" + entry.relativePath } ?? entry.relativePath)
        .onAppear(perform: refreshCover)
        .onChange(of: metadata.revision) { refreshCover() }
    }

    private func refreshCover() {
        if generation != metadata.generation { cover = nil; generation = metadata.generation }
        if let image = metadata.cover(for: entry.url) { cover = image }
        else if cover == nil { metadata.ensureCover(for: entry) }
    }
}
