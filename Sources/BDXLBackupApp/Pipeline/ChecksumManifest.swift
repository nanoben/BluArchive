import Foundation
import CryptoKit

/// Per-file SHA-256 manifest in `shasum -a 256` format ("<hex>  <relative path>"),
/// so it can be checked on any Mac with `shasum -a 256 -c SHA256SUMS.txt` from the disc root.
enum ChecksumManifest {
    struct Entry: Sendable {
        let relativePath: String
        let sha256: String
    }

    struct VerifyResult: Sendable {
        let checkedCount: Int
        let failures: [String]

        var passed: Bool { failures.isEmpty }
    }

    /// Finder/exFAT metadata that macOS may rewrite at any time; not part of the archived payload.
    static func isVolatileMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Hashes every regular file below `root` (read-only access). Symlinks are not followed.
    static func build(
        root: URL,
        excludingTopLevel excluded: Set<String> = [],
        onProgress: (Int) -> Void = { _ in }
    ) throws -> [Entry] {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else {
            throw NSError(domain: "BDXLBackup", code: 60, userInfo: [NSLocalizedDescriptionKey: "Cannot enumerate \(rootPath)"])
        }

        var entries: [Entry] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let rel = relativePath(of: url, under: rootPath)
            if enumerator.level == 1, excluded.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, !isVolatileMetadata(url.lastPathComponent) else { continue }
            entries.append(Entry(relativePath: rel, sha256: try sha256Hex(of: url)))
            if entries.count % 500 == 0 { onProgress(entries.count) }
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    static func write(_ entries: [Entry], to url: URL) throws {
        let body = entries.map { line(for: $0) }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Re-hashes every file listed in `manifest`, resolving paths against `root`.
    static func verify(manifest: URL, root: URL, onProgress: (Int) -> Void = { _ in }) throws -> VerifyResult {
        let text = try String(contentsOf: manifest, encoding: .utf8)
        var checked = 0
        var failures: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            try Task.checkCancellation()
            guard let entry = parse(String(rawLine)) else {
                failures.append("Unreadable manifest line: \(rawLine)")
                continue
            }
            let fileURL = root.appendingPathComponent(entry.relativePath)
            do {
                let actual = try sha256Hex(of: fileURL)
                if actual != entry.sha256 {
                    failures.append("MISMATCH: \(entry.relativePath)")
                }
            } catch {
                failures.append("MISSING/UNREADABLE: \(entry.relativePath)")
            }
            checked += 1
            if checked % 500 == 0 { onProgress(checked) }
        }
        return VerifyResult(checkedCount: checked, failures: failures)
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(of url: URL, under rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// shasum/GNU convention: names containing a backslash or newline are escaped and the line gets a leading "\".
    private static func line(for entry: Entry) -> String {
        let name = entry.relativePath
        if name.contains("\\") || name.contains("\n") {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
            return "\\\(entry.sha256)  \(escaped)"
        }
        return "\(entry.sha256)  \(name)"
    }

    private static func parse(_ line: String) -> Entry? {
        var body = Substring(line)
        let escaped = body.hasPrefix("\\")
        if escaped { body = body.dropFirst() }
        guard body.count > 66 else { return nil }
        let hash = String(body.prefix(64))
        let sep = body.dropFirst(64).prefix(2)
        guard sep == "  " || sep == " *" else { return nil }
        var name = String(body.dropFirst(66))
        if escaped {
            var unescaped = ""
            var chars = name.makeIterator()
            while let c = chars.next() {
                if c == "\\", let next = chars.next() {
                    unescaped.append(next == "n" ? "\n" : next)
                } else {
                    unescaped.append(c)
                }
            }
            name = unescaped
        }
        return Entry(relativePath: name, sha256: hash.lowercased())
    }
}
