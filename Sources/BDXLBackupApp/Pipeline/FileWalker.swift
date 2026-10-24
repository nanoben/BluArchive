import Foundation

/// Depth-first directory walk shared by the staging copy, the SHA-256 manifest and the PAR2 file lists.
///
/// - Relative paths are built only from directory-listing names and appended to the caller's root
///   string, never by stripping a prefix from an enumerator URL: Foundation may hand back the root in a
///   different Unicode normalization (NFC vs NFD, e.g. "å"), and then prefix matching (and par2's
///   byte-wise -B comparison) silently fails.
/// - Any unreadable folder or item throws, so a partial walk can never look like a complete archive.
/// - Symlinks are reported, not followed.
enum FileWalker {
    struct Entry {
        let relativePath: String
        let attributes: [FileAttributeKey: Any]

        var name: String { (relativePath as NSString).lastPathComponent }
        var type: FileAttributeType? { attributes[.type] as? FileAttributeType }
        var size: Int64 { (attributes[.size] as? NSNumber)?.int64Value ?? 0 }
        var isVolatileMetadata: Bool { ChecksumManifest.isVolatileMetadata(name) }
    }

    /// `visit` returns false to skip descending into a directory entry.
    static func walk(root: String, _ visit: (Entry) throws -> Bool) throws {
        let fm = FileManager.default
        func recurse(_ rel: String) throws {
            let dir = rel.isEmpty ? root : root + "/" + rel
            for name in try fm.contentsOfDirectory(atPath: dir).sorted() {
                try Task.checkCancellation()
                let childRel = rel.isEmpty ? name : rel + "/" + name
                let entry = Entry(relativePath: childRel, attributes: try fm.attributesOfItem(atPath: root + "/" + childRel))
                if try visit(entry), entry.type == .typeDirectory {
                    try recurse(childRel)
                }
            }
        }
        try recurse("")
    }
}
