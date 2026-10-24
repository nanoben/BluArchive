import Foundation

/// Chooses an explicit PAR2 block size (`par2 create -s<n>`) per set from data volume and file count.
///
/// Every source file occupies whole blocks, so the block size trades three things against each other:
/// - large blocks pad each small photo up to a full block (measured: 1 MiB on 909 MB / 1,283 JPGs gave
///   200 MB of PAR2 data vs. 156 MB at 512 KiB, with no speed gain),
/// - small blocks raise the source/recovery block count, and create time grows with
///   data size × recovery block count,
/// - the PAR2 format allows at most 32,768 source blocks per set.
/// The planner picks the smallest power-of-two block size whose block count stays below a budget of
/// max(3,000, 1.5 × file count), so many-small-file folders get about 1–2 blocks per file.
enum Par2Planner {
    struct Plan: Sendable {
        let fileCount: Int
        let totalBytes: Int64
        let blockSize: Int
        let sourceBlocks: Int
        let recoveryBlocks: Int
    }

    enum PlanError: LocalizedError {
        case tooManyFiles(Int)

        var errorDescription: String? {
            switch self {
            case .tooManyFiles(let n):
                return "\(n) files exceed the PAR2 limit of \(Par2Planner.maxSourceBlocks) source blocks per set."
            }
        }
    }

    static let maxSourceBlocks = 32_000
    static let minBlockSize = 64 * 1024
    static let maxBlockSize = 256 * 1024 * 1024

    /// Returns nil when there is nothing par2 can protect (no non-empty files).
    static func plan(fileSizes: [Int64], redundancyPercent: Int) throws -> Plan? {
        let sizes = fileSizes.filter { $0 > 0 }
        guard !sizes.isEmpty else { return nil }
        let budget = min(maxSourceBlocks, max(3_000, sizes.count * 3 / 2))

        var blockSize = minBlockSize
        while true {
            let bs = Int64(blockSize)
            let blocks = sizes.reduce(0) { $0 + Int(($1 + bs - 1) / bs) }
            if blocks <= budget || (blockSize >= maxBlockSize && blocks <= maxSourceBlocks) {
                return Plan(
                    fileCount: sizes.count,
                    totalBytes: sizes.reduce(0, +),
                    blockSize: blockSize,
                    sourceBlocks: blocks,
                    recoveryBlocks: max(1, Int((Double(blocks) * Double(redundancyPercent) / 100).rounded(.up)))
                )
            }
            guard blockSize < maxBlockSize else { throw PlanError.tooManyFiles(sizes.count) }
            blockSize *= 2
        }
    }

    struct SourceFile: Sendable {
        let path: String
        let size: Int64
    }

    /// Non-empty regular files under `itemPath` (or the item itself), recursively, without Finder metadata.
    ///
    /// This list is handed to par2 as `@filelist` instead of letting `par2 -R` scan the folder: on
    /// exFAT, macOS stores every xattr (incl. the `com.apple.provenance` it adds to each newly written
    /// file) as a `._name` AppleDouble file, which `par2 -R` would protect too, while `hdiutil makehybrid`
    /// leaves those sidecars off the ISO, so the PAR2 sets would never verify on the disc.
    /// `itemPath` must start with the exact string passed to par2 as -B (par2 compares bytes).
    static func sourceFiles(underPath itemPath: String) throws -> [SourceFile] {
        let attrs = try FileManager.default.attributesOfItem(atPath: itemPath)
        if attrs[.type] as? FileAttributeType == .typeRegular {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let name = (itemPath as NSString).lastPathComponent
            return size > 0 && !ChecksumManifest.isVolatileMetadata(name) ? [SourceFile(path: itemPath, size: size)] : []
        }
        guard attrs[.type] as? FileAttributeType == .typeDirectory else { return [] }
        var files: [SourceFile] = []
        try FileWalker.walk(root: itemPath) { entry in
            guard !entry.isVolatileMetadata else { return false }
            if entry.type == .typeRegular, entry.size > 0 {
                files.append(SourceFile(path: itemPath + "/" + entry.relativePath, size: entry.size))
            }
            return true
        }
        return files
    }

    static func formatBlockSize(_ bytes: Int) -> String {
        bytes >= 1024 * 1024 ? "\(bytes / (1024 * 1024)) MiB" : "\(bytes / 1024) KiB"
    }
}
