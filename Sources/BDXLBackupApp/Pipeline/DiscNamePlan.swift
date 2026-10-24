import Foundation

/// Decides the name every source item gets on the disc, so that no name is altered when the disc is read.
///
/// Measured with `hdiutil makehybrid -udf -iso -joliet` on macOS:
/// - ":" is shown as "_" plus a "#XXXX" CRC suffix (`17:11:2007` → `17_11_2007#CC1B`). Finder writes
///   "/" typed in a name as ":", so folders like "17/11/2007" hit this.
/// - A name holding any character above U+00FF (e.g. "–") is limited to 127 UTF-16 units, otherwise
///   to 254; longer names are mangled the same way.
/// A changed name would not match the SHA-256 manifest or the PAR2 sets. Only the staged copy is
/// renamed (originals are untouched); every rename is listed in `_BluArchive/RENAMED.txt`.
/// `ProbeImage` then checks the planned names on a real image before any data is copied.
struct DiscNamePlan: Sendable {
    struct Rename: Sendable {
        let originalPath: String
        let discPath: String
    }

    /// Original relative path → new last component, only for renamed items.
    private(set) var renamedNames: [String: String] = [:]
    private(set) var renames: [Rename] = []
    /// Disc-relative paths of every planned item (for the name probe).
    private(set) var directories: [String] = []
    private(set) var files: [String] = []

    /// Maps a source-relative path to its disc-relative path.
    func discPath(for originalPath: String) -> String {
        guard !renamedNames.isEmpty else { return originalPath }
        var original = ""
        var disc = ""
        for component in originalPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            original = original.isEmpty ? component : original + "/" + component
            let name = renamedNames[original] ?? component
            disc = disc.isEmpty ? name : disc + "/" + name
        }
        return disc
    }

    /// Walks the source (read-only) with the same filter as `StagingCopier`.
    static func build(sourceRoot: String) throws -> DiscNamePlan {
        var plan = DiscNamePlan()
        let fm = FileManager.default
        /// Names already present or assigned per source folder, compared case- and normalization-insensitively.
        var taken: [String: Set<String>] = [:]
        func takenNames(inParent parent: String) throws -> Set<String> {
            if let names = taken[parent] { return names }
            let dir = parent.isEmpty ? sourceRoot : sourceRoot + "/" + parent
            let names = Set(try fm.contentsOfDirectory(atPath: dir).map(key))
            taken[parent] = names
            return names
        }

        try FileWalker.walk(root: sourceRoot) { entry in
            if entry.isVolatileMetadata { return false }
            let parent = (entry.relativePath as NSString).deletingLastPathComponent
            var name = safeName(entry.name)
            if name != entry.name {
                var names = try takenNames(inParent: parent)
                name = uniqueName(name, avoiding: names)
                names.insert(key(name))
                taken[parent] = names
                plan.renamedNames[entry.relativePath] = name
                let discParent = plan.discPath(for: parent)
                plan.renames.append(Rename(
                    originalPath: entry.relativePath,
                    discPath: discParent.isEmpty ? name : discParent + "/" + name
                ))
            }
            let disc = plan.discPath(for: entry.relativePath)
            switch entry.type {
            case .typeDirectory?: plan.directories.append(disc)
            case .typeRegular?, .typeSymbolicLink?: plan.files.append(disc)
            default: break
            }
            return true
        }
        return plan
    }

    /// Lists renames as "original<TAB>disc" lines (empty when nothing was renamed).
    func renameListText() -> String {
        guard !renames.isEmpty else { return "" }
        let header = "# Items renamed on this disc so their names survive on UDF media (original\tname on disc)\n"
        return header + renames.map { "\($0.originalPath)\t\($0.discPath)" }.joined(separator: "\n") + "\n"
    }

    static func safeName(_ name: String) -> String {
        var result = name.replacingOccurrences(of: ":", with: "-")
        let nfc = result.precomposedStringWithCanonicalMapping
        let limit = nfc.unicodeScalars.contains { $0.value > 0xFF } ? 127 : 254
        if nfc.utf16.count > limit {
            result = shortened(nfc, toUTF16Units: limit)
        }
        return result
    }

    /// Keeps the extension (up to 10 characters) and cuts the stem, marking the cut with "~".
    private static func shortened(_ name: String, toUTF16Units limit: Int) -> String {
        let ext = (name as NSString).pathExtension
        let keepExt = !ext.isEmpty && ext.utf16.count <= 10
        let suffix = "~" + (keepExt ? "." + ext : "")
        var stem = keepExt ? (name as NSString).deletingPathExtension : name
        // Room for a later " (n)" collision suffix as well.
        let budget = limit - suffix.utf16.count - 6
        while stem.utf16.count > budget {
            stem.removeLast()
        }
        return stem.trimmingCharacters(in: .whitespaces) + suffix
    }

    private static func uniqueName(_ name: String, avoiding names: Set<String>) -> String {
        guard names.contains(key(name)) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if !names.contains(key(candidate)) { return candidate }
            n += 1
        }
    }

    private static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}
