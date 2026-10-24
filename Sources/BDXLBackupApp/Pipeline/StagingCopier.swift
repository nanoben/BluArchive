import Foundation
import Darwin

/// Copies the source tree into staging, data only.
///
/// `ditto` (even with `--noextattr`) copied existing AppleDouble files (`._x`) as ordinary files and
/// let the exFAT driver add a further sidecar for each of them (`._._x`) plus folder sidecars:
/// one real archive grew from 15,062 to 26,871 files. This copier writes only file contents plus
/// timestamps/permissions, and leaves Finder metadata (`.DS_Store`, `._*`) out of the new archive.
/// The source is only ever read.
enum StagingCopier {
    struct Result: Sendable {
        var files = 0
        var bytes: Int64 = 0
        var directories = 0
        var symlinks = 0
        var skippedMetadata = 0
    }

    static func copy(
        from source: URL,
        to destination: URL,
        onProgress: (Result) -> Void = { _ in }
    ) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceRoot = source.path
        let destinationRoot = destination.path
        var result = Result()
        /// Folder dates are applied last: adding children would otherwise reset them.
        var directoryDates: [(String, [FileAttributeKey: Any])] = []
        var lastReport = Date()

        try FileWalker.walk(root: sourceRoot) { entry in
            if entry.isVolatileMetadata {
                result.skippedMetadata += 1
                return false
            }
            let from = sourceRoot + "/" + entry.relativePath
            let to = destinationRoot + "/" + entry.relativePath
            switch entry.type {
            case .typeSymbolicLink?:
                try fm.createSymbolicLink(atPath: to, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: from))
                result.symlinks += 1
            case .typeDirectory?:
                try fm.createDirectory(atPath: to, withIntermediateDirectories: false)
                directoryDates.append((to, dateAttributes(entry.attributes, includePermissions: false)))
                result.directories += 1
            case .typeRegular?:
                guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_EXCL)) == 0 else {
                    throw copyError("Copy failed (\(String(cString: strerror(errno)))): \(from)")
                }
                try fm.setAttributes(dateAttributes(entry.attributes, includePermissions: true), ofItemAtPath: to)
                result.files += 1
                result.bytes += entry.size
                if Date().timeIntervalSince(lastReport) >= 2 {
                    onProgress(result)
                    lastReport = Date()
                }
            default:
                throw copyError("Unsupported item type (\(entry.type?.rawValue ?? "unknown")): \(from)")
            }
            return true
        }

        for (dir, attrs) in directoryDates.reversed() {
            try? fm.setAttributes(attrs, ofItemAtPath: dir)
        }
        onProgress(result)
        return result
    }

    /// Folder permissions are not copied: a read-only staging folder would block its own cleanup.
    private static func dateAttributes(_ attrs: [FileAttributeKey: Any], includePermissions: Bool) -> [FileAttributeKey: Any] {
        let keys: [FileAttributeKey] = includePermissions
            ? [.modificationDate, .creationDate, .posixPermissions]
            : [.modificationDate, .creationDate]
        var out: [FileAttributeKey: Any] = [:]
        for key in keys {
            if let value = attrs[key] {
                out[key] = value
            }
        }
        return out
    }

    private static func copyError(_ message: String) -> NSError {
        NSError(domain: "BDXLBackup", code: 13, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
