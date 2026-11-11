import Foundation

enum LibraryScanner {
    /// Enumerates filenames and cached filesystem attributes. Never opens NUP contents.
    static func scan(_ folder: URL, context: JobContext = JobContext()) throws -> LibrarySnapshot {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        try require(rootValues.isDirectory == true && rootValues.isSymbolicLink != true,
                    "Bitte einen regulären Ordner auswählen.")
        var warnings: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { url, error in
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }) else { throw NUPError("Der Ordner konnte nicht gelesen werden.") }
        var entries: [LibraryEntry] = []
        var checked = 0
        for case let url as URL in enumerator {
            try context.check()
            checked += 1
            if checked % 128 == 0 {
                try context.report(0, "\(entries.count) NUPs gefunden · \(checked) Einträge durchsucht")
            }
            // FileManager does not follow symlink directories; skip symlink files too.
            guard url.pathExtension.lowercased() == "nup" else { continue }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                // The enumerator may canonicalize /var to /private/var. Use its depth,
                // rather than subtracting string prefixes with different spellings.
                let path = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                entries.append(LibraryEntry(url: url, relativePath: path,
                    size: values.fileSize.map(Int64.init), modified: values.contentModificationDate,
                    searchKey: LibrarySnapshot.searchKey(path)))
            } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        try context.check()
        entries.sort {
            let order = $0.relativePath.localizedStandardCompare($1.relativePath)
            return order == .orderedSame ? $0.relativePath < $1.relativePath : order == .orderedAscending
        }
        try context.check()
        return LibrarySnapshot(folder: root, entries: entries, warnings: warnings)
    }
}
