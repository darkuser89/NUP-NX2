import Foundation

struct LocalizedEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    var language = ""
    var title = ""
    var icon: Data?
}

struct ArchivePackageDraft: Sendable {
    let original: NUPPackage
    var name: String
    var publisher: String
    var displayVersion: String
    var source: String
    var buildID: String
    var icon: Data?
    var localized: [LocalizedEntry] = []
    private let originalLocalized: [LocalizedEntry]
    let decodingNotice: String?

    init(_ package: NUPPackage) {
        original = package
        name = package.text(5, profile: .specification); publisher = package.text(6, profile: .specification)
        displayVersion = package.text(4, profile: .specification); source = package.text(8, profile: .specification)
        buildID = package.metadata[7].flatMap { $0.count == 32 ? $0.hex : nil } ?? ""
        icon = package.metadata[3]
        do {
            let titles = try package.metadata[9].map(MetadataCodec.localized) ?? [:]
            let icons = try package.metadata[10].map(MetadataCodec.localized) ?? [:]
            localized = try Set(titles.keys).union(icons.keys).sorted().map { tag in
                let title: String
                if let data = titles[tag] {
                    guard let text = String(data: data, encoding: .utf8) else { throw NUPError(L10n.text("Sprachtitel ist kein UTF-8.")) }
                    title = text
                } else { title = "" }
                return LocalizedEntry(language: tag, title: title, icon: icons[tag])
            }
            decodingNotice = nil
        } catch {
            decodingNotice = L10n.text("Vorhandene Sprachdaten sind nicht lesbar. Sie bleiben erhalten, solange du die Sprachliste nicht änderst.")
        }
        originalLocalized = localized
    }

    private var originalBuild: String { original.metadata[7].flatMap { $0.count == 32 ? $0.hex : nil } ?? "" }

    mutating func fillMissing(name: String, publisher: String, version: String = "", titles: [String: String] = [:]) -> Bool {
        var changed = false
        if self.name.isEmpty && !name.isEmpty { self.name = name; changed = true }
        if self.publisher.isEmpty && !publisher.isEmpty { self.publisher = publisher; changed = true }
        if displayVersion.isEmpty && !version.isEmpty { displayVersion = version; changed = true }
        // An opaque language list must survive importing unrelated text fields.
        if decodingNotice == nil {
            for (tag, title) in titles.sorted(by: { $0.key < $1.key }) {
                if let index = localized.firstIndex(where: {
                    $0.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == tag
                }) {
                    guard localized[index].title.isEmpty else { continue }
                    localized[index].title = title
                } else {
                    localized.append(LocalizedEntry(language: tag, title: title))
                }
                changed = true
            }
        }
        return changed
    }

    var hasChanges: Bool {
        name != original.text(5, profile: .specification) || publisher != original.text(6, profile: .specification) ||
        displayVersion != original.text(4, profile: .specification) || source != original.text(8, profile: .specification) ||
        buildID != originalBuild || icon != original.metadata[3] || localized != originalLocalized
    }
    var validationError: String? {
        if buildID != originalBuild && !buildID.isEmpty && (buildID.utf8.count != 64 || !buildID.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        })) { return L10n.text("Build-ID: 64 Hex-Zeichen eingeben oder das Feld leeren.") }
        if localized != originalLocalized {
            var tags = Set<String>()
            for entry in localized {
                let tag = entry.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let bytes = tag.data(using: .ascii), (1...255).contains(bytes.count), tags.insert(tag).inserted else {
                    return L10n.text("Sprachkürzel dürfen nicht leer, doppelt oder ungültig sein.")
                }
            }
        }
        return nil
    }
    func metadata() throws -> [UInt16: Data] {
        if let error = validationError { throw NUPError(error) }
        var result = original.metadata
        for (type, text) in [(UInt16(5), name), (6, publisher), (4, displayVersion), (8, source)] {
            if text != original.text(type, profile: .specification) { result[type] = text.isEmpty ? nil : Data(text.utf8) }
        }
        if icon != original.metadata[3] { result[3] = icon }
        if buildID != originalBuild {
            if buildID.isEmpty { result[7] = nil }
            else {
                let bytes = Array(buildID.utf8)
                result[7] = Data(stride(from: 0, to: bytes.count, by: 2).map { index in
                    UInt8(String(decoding: bytes[index..<(index + 2)], as: UTF8.self), radix: 16)!
                })
            }
        }
        if localized != originalLocalized {
            var titles: [String: Data] = [:], icons: [String: Data] = [:]
            for entry in localized {
                let tag = entry.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !entry.title.isEmpty { titles[tag] = Data(entry.title.utf8) }
                if let image = entry.icon { icons[tag] = image }
            }
            let oldTitles = try? original.metadata[9].map(MetadataCodec.localized) ?? [:]
            let oldIcons = try? original.metadata[10].map(MetadataCodec.localized) ?? [:]
            if titles != oldTitles { result[9] = titles.isEmpty ? nil : try MetadataCodec.localizedData(titles) }
            if icons != oldIcons { result[10] = icons.isEmpty ? nil : try MetadataCodec.localizedData(icons) }
        }
        return result
    }
}
