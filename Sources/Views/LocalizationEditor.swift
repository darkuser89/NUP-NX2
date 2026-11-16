import SwiftUI

struct LocalizationEditor: View {
    @Binding var entries: [LocalizedEntry]
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach($entries) { $entry in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Sprachkürzel")).font(.caption.weight(.semibold))
                            TextField(L10n.text("z. B. de"), text: $entry.language)
                                .labelsHidden()
                                .accessibilityLabel(L10n.text("Sprachkürzel"))
                            Text(L10n.text("de · en · ja · en-us")).font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 150)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.text("Lokalisierter Spielname")).font(.caption.weight(.semibold))
                            TextField(L10n.text("Spielname in dieser Sprache"), text: $entry.title)
                                .labelsHidden()
                                .accessibilityLabel(L10n.text("Lokalisierter Spielname"))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .multilineTextAlignment(.leading)

                    HStack(spacing: 10) {
                        if let data = entry.icon, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(L10n.text("Cover für diese Sprache"))
                        }
                        Button {
                            if let url = FilePanels.image() {
                                do { entry.icon = try FilePanels.imageData(url) }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            Label(L10n.text("Sprach-Cover auswählen …"), systemImage: "photo")
                        }
                        if entry.icon != nil {
                            Button(L10n.text("Cover entfernen")) { entry.icon = nil }
                        }
                        Spacer(minLength: 12)
                        Button { entries.removeAll { $0.id == entry.id } } label: {
                            Label(L10n.text("Sprache entfernen"), systemImage: "minus.circle")
                        }
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            Button { entries.append(LocalizedEntry()) } label: { Label(L10n.text("Sprache hinzufügen"), systemImage: "plus") }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    static func values(_ entries: [LocalizedEntry]) throws -> ([String: String], [String: Data]) {
        var titles: [String: String] = [:]
        var icons: [String: Data] = [:]
        var seen = Set<String>()
        for entry in entries {
            let tag = entry.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try require(!tag.isEmpty && seen.insert(tag).inserted, L10n.text("Sprachkürzel dürfen nicht leer oder doppelt sein."))
            if !entry.title.isEmpty { titles[tag] = entry.title }
            if let data = entry.icon { icons[tag] = data }
        }
        return (titles, icons)
    }
}
