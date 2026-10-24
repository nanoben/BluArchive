import Foundation
import Combine

/// Orchestrates TAR → PAR2 → SHA256 manifest → ISO → `hdiutil burn` (matches `bluray.sh`).
@MainActor
final class BackupPipeline: ObservableObject {
    private let runner = ProcessRunner()

    func cancel() {
        runner.cancel()
    }

    func run(settings: BackupJobSettings, state: BackupState) async {
        state.isRunning = true
        state.lastErrorMessage = nil
        state.stage = .preflight
        state.progress = 0

        defer {
            state.isRunning = false
            if state.stage != .complete && state.stage != .failed {
                state.stage = .failed
            }
        }

        do {
            try Task.checkCancellation()
            try await preflight(settings: settings, state: state)
            let paths = try await runTarPar2ShaIso(settings: settings, state: state)

            if settings.burnAfterISO {
                try Task.checkCancellation()
                state.stage = .burn
                state.progress = 0.82
                state.appendLog("Burning ISO…")
                try await burnISO(
                    isoURL: paths.isoURL,
                    settings: settings,
                    state: state
                )
            } else {
                state.appendLog("Skipping burn (generate ISO only).")
            }

            var verificationSummary: [String] = []
            if settings.verifyMode != .none {
                try Task.checkCancellation()
                state.stage = .verify
                state.progress = 0.92
                if let discRoot = paths.discRootURL {
                    verificationSummary = try await verifyNonTarArtifacts(
                        settings: settings,
                        state: state,
                        discRoot: discRoot,
                        isoURL: paths.isoURL,
                        expectedPar2Sets: paths.par2SetCount
                    )
                } else {
                    try await verifyArtifacts(
                        settings: settings,
                        state: state,
                        workURL: paths.workURL,
                        tarBaseName: paths.tarBaseName
                    )
                }
            } else if !settings.tarFirstEnabled {
                verificationSummary = [
                    "Staging: NOT VERIFIED (Verify = None)",
                    "ISO image: NOT VERIFIED (Verify = None)",
                    "Burned disc: NOT VERIFIED (Verify = None)"
                ]
            }
            if !verificationSummary.isEmpty {
                state.appendLog("Verification summary:")
                verificationSummary.forEach { state.appendLog("  • \($0)") }
            }

            if !settings.keepStagingFiles {
                try? FileManager.default.removeItem(at: paths.workURL)
                state.appendLog("Removed staging directory: \(paths.workURL.path)")
            } else {
                state.appendLog("Keeping staging directory: \(paths.workURL.path)")
            }

            state.stage = .complete
            state.progress = 1.0
            state.appendLog("Done.")
        } catch is CancellationError {
            state.stage = .failed
            state.lastErrorMessage = "Cancelled."
            state.appendLog("Cancelled.")
        } catch {
            state.stage = .failed
            state.lastErrorMessage = error.localizedDescription
            state.appendLog("ERROR: \(error.localizedDescription)")
        }
    }

    private struct JobPaths {
        let workURL: URL
        let tarURL: URL?
        let isoURL: URL
        let tarBaseName: String
        let manifestURL: URL?
        let discRootURL: URL?
        let par2SetCount: Int
    }

    /// Disc-root folder (non-TAR mode) holding the SHA-256 manifest, PAR2 sets and a README.
    static let archiveMetaFolderName = "_BluArchive"
    static let discManifestName = "SHA256SUMS.txt"

    private func preflight(settings: BackupJobSettings, state: BackupState) async throws {
        guard let source = settings.sourceFolder else {
            throw NSError(domain: "BDXLBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "No source folder selected."])
        }
        guard let output = settings.outputFolder else {
            throw NSError(domain: "BDXLBackup", code: 2, userInfo: [NSLocalizedDescriptionKey: "No output folder selected."])
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "BDXLBackup", code: 3, userInfo: [NSLocalizedDescriptionKey: "Source is not a directory."])
        }
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "BDXLBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Output is not a directory."])
        }

        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let outputPath = output.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath != outputPath, !outputPath.hasPrefix(sourcePath + "/") else {
            throw NSError(
                domain: "BDXLBackup",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Output folder must be outside the source folder (originals are never written to)."]
            )
        }
        guard !sourcePath.hasPrefix(outputPath + "/_bdxl_work") else {
            throw NSError(
                domain: "BDXLBackup",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Source folder lies inside the staging folder (_bdxl_work), which is deleted on each run."]
            )
        }
        if !settings.tarFirstEnabled,
           FileManager.default.fileExists(atPath: source.appendingPathComponent(Self.archiveMetaFolderName).path) {
            throw NSError(
                domain: "BDXLBackup",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Source already contains a top-level '\(Self.archiveMetaFolderName)' item; it is reserved for checksums and PAR2 files on the disc."]
            )
        }

        if settings.par2Enabled {
            if let par2 = await ToolResolver.par2Executable() {
                state.appendLog("Found par2 at: \(par2)")
            } else {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "par2 not found. Install with: brew install par2"]
                )
            }
        }

        let freeBytes = try freeSpaceBytes(at: output)
        let sourceBytes = try await estimatedFolderSizeBytes(at: source)
        /// Heuristic multiplier based on TAR/PAR toggles.
        let projectedFactor: Double
        if settings.tarFirstEnabled && settings.par2Enabled {
            projectedFactor = 1.35
        } else if settings.tarFirstEnabled {
            projectedFactor = 1.15
        } else {
            /// Non-TAR: full staging copy + ISO + PAR2 sets.
            projectedFactor = 2.05 + (settings.par2Enabled ? Double(settings.par2RedundancyPercent) / 100 : 0)
        }
        let projectedBytes = Int64(Double(sourceBytes) * projectedFactor) + 512 * 1024 * 1024
        guard projectedBytes < freeBytes else {
            throw NSError(
                domain: "BDXLBackup",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Insufficient free disk space at output. Need ~\(formatBytes(projectedBytes)) free; have ~\(formatBytes(freeBytes))."
                ]
            )
        }

        let safeGiB = settings.profile.safeMaxPayloadGiB
        let maxBytes = Int64(safeGiB * 1024 * 1024 * 1024)
        /// Non-TAR discs carry the PAR2 sets next to the files, so count them against the media limit.
        let payloadBytes = settings.tarFirstEnabled || !settings.par2Enabled
            ? sourceBytes
            : Int64(Double(sourceBytes) * (1 + Double(settings.par2RedundancyPercent) / 100))
        guard payloadBytes <= maxBytes else {
            throw NSError(
                domain: "BDXLBackup",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Source is larger than safe limit for \(settings.profile.rawValue) (~\(safeGiB) GiB payload). Reduce data or choose larger media."
                ]
            )
        }

        if settings.burnAfterISO {
            let (_, drOut) = try await runner.runCollecting(
                launchPath: ToolResolver.drutilExecutable(),
                arguments: ["status"]
            )
            state.appendLog("drutil status:\n\(drOut.prefix(2000))")
        }

        state.appendLog("Preflight OK (source ~\(formatBytes(sourceBytes)), max ~\(safeGiB) GiB for profile).")
        state.progress = 0.05
    }

    private func runTarPar2ShaIso(settings: BackupJobSettings, state: BackupState) async throws -> JobPaths {
        guard let source = settings.sourceFolder, let output = settings.outputFolder else {
            throw NSError(domain: "BDXLBackup", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing paths."])
        }

        let basename = source.lastPathComponent
        let workURL = output.appendingPathComponent("_bdxl_work", isDirectory: true)
        if FileManager.default.fileExists(atPath: workURL.path) {
            try FileManager.default.removeItem(at: workURL)
        }
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)

        let parent = source.deletingLastPathComponent()
        let tarURL = workURL.appendingPathComponent("\(basename).tar")
        let par2Base = workURL.appendingPathComponent("\(basename).par2").path
        let manifestURL = workURL.appendingPathComponent("\(basename)_sha256.txt")
        let isoURL = output.appendingPathComponent("\(settings.volumeLabel).iso")

        if FileManager.default.fileExists(atPath: isoURL.path) {
            try FileManager.default.removeItem(at: isoURL)
        }

        var effectiveTarURL: URL?
        var isoSourceURL: URL
        /// Non-TAR only: staged copy of the source that becomes the disc root (originals + `_BluArchive/`).
        var discRootURL: URL?
        var par2SetCount = 0

        if settings.tarFirstEnabled {
            // TAR
            state.stage = .tar
            state.progress = 0.1
            state.appendLog("Creating TAR: \(tarURL.path)")
            let tarArgs = ["-cf", tarURL.path, "-C", parent.path, basename]
            let tarCode = try await runner.runStreaming(
                launchPath: ToolResolver.tarExecutable(),
                arguments: tarArgs,
                onLine: { state.appendLog($0) }
            )
            try throwIfBadExit(tarCode, cmd: "tar \(tarArgs.joined(separator: " "))")
            effectiveTarURL = tarURL
            isoSourceURL = workURL
        } else {
            state.appendLog("Skipping TAR stage (TAR first disabled).")
            // hdiutil makehybrid takes a single source folder, so the PAR2 sets and checksums can only
            // reach the disc if they sit next to the files. Stage a copy; the originals are only read.
            state.stage = .copy
            state.progress = 0.1
            let discRoot = workURL.appendingPathComponent("disc", isDirectory: true)
            state.appendLog("Copying source into staging (originals are read-only): \(discRoot.path)")
            let dittoArgs = ["--norsrc", "--noextattr", "--noqtn", "--noacl", source.path, discRoot.path]
            let dittoCode = try await runner.runStreaming(
                launchPath: ToolResolver.dittoExecutable(),
                arguments: dittoArgs,
                onLine: { state.appendLog($0) }
            )
            try throwIfBadExit(dittoCode, cmd: "ditto \(dittoArgs.joined(separator: " "))")
            try FileManager.default.createDirectory(
                at: discRoot.appendingPathComponent(Self.archiveMetaFolderName, isDirectory: true),
                withIntermediateDirectories: true
            )
            discRootURL = discRoot
            isoSourceURL = discRoot
        }

        // PAR2
        if settings.par2Enabled, let tarForPar = effectiveTarURL {
            state.stage = .par2
            state.progress = 0.35
            guard let par2 = await ToolResolver.par2Executable() else {
                throw NSError(domain: "BDXLBackup", code: 9, userInfo: [NSLocalizedDescriptionKey: "par2 disappeared from PATH."])
            }
            let redundancy = max(1, min(32, settings.par2RedundancyPercent))
            let par2Args = ["create", "-r\(redundancy)", par2Base, tarForPar.path]
            state.appendLog("PAR2 create with \(redundancy)% redundancy…")
            let par2Code = try await runner.runStreaming(
                launchPath: par2,
                arguments: par2Args,
                onLine: { state.appendLog($0) }
            )
            try throwIfBadExit(par2Code, cmd: "par2 \(par2Args.joined(separator: " "))")
        } else if settings.par2Enabled, let discRoot = discRootURL {
            state.stage = .par2
            state.progress = 0.35
            guard let par2 = await ToolResolver.par2Executable() else {
                throw NSError(domain: "BDXLBackup", code: 9, userInfo: [NSLocalizedDescriptionKey: "par2 disappeared from PATH."])
            }
            let redundancy = max(1, min(32, settings.par2RedundancyPercent))
            let par2OutputDir = discRoot
                .appendingPathComponent(Self.archiveMetaFolderName, isDirectory: true)
                .appendingPathComponent("par2", isDirectory: true)
            try FileManager.default.createDirectory(at: par2OutputDir, withIntermediateDirectories: true)

            let items = try topLevelItemsForPar2(in: discRoot)
            if items.isEmpty {
                state.appendLog("PAR2 non-TAR mode: no eligible top-level items found; skipping PAR2 files.")
            } else {
                state.appendLog("PAR2 non-TAR mode: \(items.count) top-level item(s), \(redundancy)% redundancy.")
            }

            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                // par2 rejects folders that hold no data ("You must specify a list of files"); such items
                // are still on the disc and covered by the SHA-256 manifest.
                guard containsNonEmptyRegularFile(item) else {
                    state.appendLog("PAR2 skip for '\(item.lastPathComponent)': no non-empty files (covered by SHA-256 manifest only).")
                    continue
                }
                let baseName = par2BaseName(for: item, index: index)
                let par2BasePath = par2OutputDir.appendingPathComponent(baseName).path
                // -R: recurse into folders. -B: store paths relative to the disc root, e.g. "1928/x.jpg",
                // so the set verifies against the original folder structure on the disc.
                let args = ["create", "-q", "-R", "-r\(redundancy)", "-B\(discRoot.path)", par2BasePath, item.path]
                state.appendLog("PAR2 create for '\(item.lastPathComponent)'…")
                let code = try await runner.runStreaming(
                    launchPath: par2,
                    arguments: args,
                    onLine: { state.appendLog($0) }
                )
                try throwIfBadExit(code, cmd: "par2 \(args.joined(separator: " "))")
                par2SetCount += 1
            }
            state.appendLog("PAR2 non-TAR mode: \(par2SetCount) set(s) written to \(Self.archiveMetaFolderName)/par2 on the disc.")
        } else {
            state.appendLog("Skipping PAR2 stage (disabled).")
        }

        // SHA256 manifest (single-line hash file for the TAR)
        var effectiveManifestURL: URL?
        state.stage = .sha256
        state.progress = 0.55
        if let tarForSha = effectiveTarURL {
            state.appendLog("Writing SHA256 manifest…")
            let (shaCode, shaOut) = try await runner.runCollecting(
                launchPath: ToolResolver.shasumExecutable(),
                arguments: ["-a", "256", tarForSha.lastPathComponent],
                currentDirectory: workURL
            )
            try throwIfBadExit(shaCode, cmd: "shasum")
            try shaOut.write(to: manifestURL, atomically: true, encoding: .utf8)
            effectiveManifestURL = manifestURL
        } else if let discRoot = discRootURL {
            state.appendLog("Writing per-file SHA-256 manifest from the ORIGINAL files…")
            let log = Self.logger(for: state)
            let entries = try await Self.offMain {
                try ChecksumManifest.build(root: source, onProgress: { log("  hashed \($0) original files…") })
            }
            let metaDir = discRoot.appendingPathComponent(Self.archiveMetaFolderName, isDirectory: true)
            let discManifestURL = metaDir.appendingPathComponent(Self.discManifestName)
            try ChecksumManifest.write(entries, to: discManifestURL)
            try discReadme(settings: settings, sourceName: basename, par2SetCount: par2SetCount)
                .write(to: metaDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            state.appendLog("SHA-256 manifest: \(entries.count) file(s) → \(Self.archiveMetaFolderName)/\(Self.discManifestName)")
            effectiveManifestURL = discManifestURL
        }

        // ISO
        state.stage = .iso
        state.progress = 0.65
        state.appendLog("Building hybrid UDF/ISO → \(isoURL.path)")
        let isoArgs = [
            "makehybrid",
            "-udf",
            "-iso",
            "-joliet",
            "-default-volume-name",
            settings.volumeLabel,
            "-o",
            isoURL.path,
            isoSourceURL.path
        ]
        let isoCode = try await runner.runStreaming(
            launchPath: ToolResolver.hdiutilExecutable(),
            arguments: isoArgs,
            onLine: { state.appendLog($0) }
        )
        try throwIfBadExit(isoCode, cmd: "hdiutil makehybrid")

        return JobPaths(
            workURL: workURL,
            tarURL: effectiveTarURL,
            isoURL: isoURL,
            tarBaseName: basename,
            manifestURL: effectiveManifestURL,
            discRootURL: discRootURL,
            par2SetCount: par2SetCount
        )
    }

    private func burnISO(isoURL: URL, settings: BackupJobSettings, state: BackupState) async throws {
        var args: [String] = ["burn"]
        if let dev = settings.targetDeviceBSDName?.trimmingCharacters(in: .whitespacesAndNewlines), !dev.isEmpty {
            args.append(contentsOf: ["-device", dev])
        }
        if let speed = settings.burnSpeedX, speed > 0 {
            args.append(contentsOf: ["-speed", "\(speed)"])
        }
        /// `hdiutil burn` options vary by macOS release; post-burn verification is handled
        /// by `verifyArtifacts` to avoid relying on unsupported burn-time flags.
        args.append(isoURL.path)

        state.appendLog("hdiutil \(args.joined(separator: " "))")
        var burnOutput: [String] = []
        let code = try await runner.runStreaming(
            launchPath: ToolResolver.hdiutilExecutable(),
            arguments: args,
            onLine: { line in
                burnOutput.append(line)
                state.appendLog(line)
            }
        )
        if code != 0 {
            let tail = burnOutput.suffix(80).joined(separator: "\n")
            let details = tail.isEmpty ? "No output captured from hdiutil." : tail
            throw NSError(
                domain: "BDXLBackup",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "hdiutil burn failed (\(code)):\n\(details)"]
            )
        }
    }

    private func verifyArtifacts(
        settings: BackupJobSettings,
        state: BackupState,
        workURL: URL,
        tarBaseName: String
    ) async throws {
        let manifestURL = workURL.appendingPathComponent("\(tarBaseName)_sha256.txt")

        if (settings.verifyMode == .quick || settings.verifyMode == .deep) && settings.tarFirstEnabled {
            state.appendLog("Quick verify: checksum TAR against manifest…")
            let (c1, o1) = try await runner.runCollecting(
                launchPath: ToolResolver.shasumExecutable(),
                arguments: ["-a", "256", "-c", manifestURL.path],
                currentDirectory: workURL
            )
            if c1 != 0 {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 30,
                    userInfo: [NSLocalizedDescriptionKey: "SHA256 verify failed:\n\(o1)"]
                )
            }
            state.appendLog("SHA256 verify OK for TAR.")
        } else if settings.verifyMode == .quick || settings.verifyMode == .deep {
            state.appendLog("Skipping TAR checksum verify (TAR first disabled).")
        }

        if settings.verifyMode == .deep {
            state.appendLog("Deep verify: checksum-based mode with burned media check.")
            state.appendLog("Skipping 'hdiutil verify' due to Monterey ioctl false-fail behavior.")

            if settings.tarFirstEnabled {
                let tarURL = workURL.appendingPathComponent("\(tarBaseName).tar")
                guard FileManager.default.fileExists(atPath: tarURL.path) else {
                    return
                }
                state.appendLog("Deep verify: checksum TAR again after ISO build…")
                let (c3, o3) = try await runner.runCollecting(
                    launchPath: ToolResolver.shasumExecutable(),
                    arguments: ["-a", "256", "-c", manifestURL.path],
                    currentDirectory: workURL
                )
                if c3 != 0 {
                    throw NSError(
                        domain: "BDXLBackup",
                        code: 32,
                        userInfo: [NSLocalizedDescriptionKey: "Post-ISO TAR checksum failed:\n\(o3)"]
                    )
                }

                if settings.burnAfterISO {
                    try await verifyBurnedMediaChecksums(
                        settings: settings,
                        state: state,
                        tarBaseName: tarBaseName
                    )
                } else {
                    state.appendLog("Deep verify: burned media check skipped (burn disabled).")
                }
            } else if settings.burnAfterISO {
                state.appendLog("Deep verify: burned media TAR checksum skipped (TAR first disabled).")
            }
        }
    }

    private func verifyBurnedMediaChecksums(
        settings: BackupJobSettings,
        state: BackupState,
        tarBaseName: String
    ) async throws {
        let mountURL = try await locateBurnedMediaMountPoint(settings: settings, state: state)
        let manifestName = "\(tarBaseName)_sha256.txt"
        let manifestOnDisc = mountURL.appendingPathComponent(manifestName)

        guard FileManager.default.fileExists(atPath: manifestOnDisc.path) else {
            throw NSError(
                domain: "BDXLBackup",
                code: 33,
                userInfo: [NSLocalizedDescriptionKey: "Deep verify failed: manifest not found on burned media at \(manifestOnDisc.path)"]
            )
        }

        state.appendLog("Deep verify: checksum TAR on burned media (\(mountURL.path))…")
        let (code, out) = try await runner.runCollecting(
            launchPath: ToolResolver.shasumExecutable(),
            arguments: ["-a", "256", "-c", manifestOnDisc.path],
            currentDirectory: mountURL
        )
        if code != 0 {
            throw NSError(
                domain: "BDXLBackup",
                code: 34,
                userInfo: [NSLocalizedDescriptionKey: "Burned media checksum failed:\n\(out)"]
            )
        }
        state.appendLog("Deep verify OK for burned media checksum.")
    }

    private func locateBurnedMediaMountPoint(
        settings: BackupJobSettings,
        state: BackupState
    ) async throws -> URL {
        if let mounted = findMountedVolumeURL(expectedVolumeLabel: settings.volumeLabel) {
            return mounted
        }

        if let raw = settings.targetDeviceBSDName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let node = raw.replacingOccurrences(of: "/dev/", with: "")
            state.appendLog("Deep verify: mounting burned media from \(node)…")
            let (mountCode, mountOut) = try await runner.runCollecting(
                launchPath: ToolResolver.diskutilExecutable(),
                arguments: ["mountDisk", node]
            )
            if mountCode != 0 {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 35,
                    userInfo: [NSLocalizedDescriptionKey: "Could not mount burned media:\n\(mountOut)"]
                )
            }
            if let mounted = findMountedVolumeURL(expectedVolumeLabel: settings.volumeLabel) {
                return mounted
            }
        }

        throw NSError(
            domain: "BDXLBackup",
            code: 36,
            userInfo: [NSLocalizedDescriptionKey: "Deep verify failed: burned media mount point not found for volume label '\(settings.volumeLabel)'."]
        )
    }

    private func findMountedVolumeURL(expectedVolumeLabel: String) -> URL? {
        let volumesRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: volumesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let exact = entries.first { $0.lastPathComponent == expectedVolumeLabel }
        if let exact { return exact }

        return entries.first { $0.lastPathComponent.hasPrefix(expectedVolumeLabel) }
    }

    /// Non-TAR verification. Each level is reported separately; any failed check throws, and levels
    /// that were not checked are reported as NOT VERIFIED rather than silently passing.
    private func verifyNonTarArtifacts(
        settings: BackupJobSettings,
        state: BackupState,
        discRoot: URL,
        isoURL: URL,
        expectedPar2Sets: Int
    ) async throws -> [String] {
        var summary: [String] = []

        state.appendLog("Verify [staging]: SHA-256 of staged copy against the original-file manifest…")
        let stagedCount = try await checkManifest(root: discRoot, level: "staging", state: state)
        summary.append("Staging copy matches originals: PASSED (\(stagedCount) files, SHA-256)")

        state.appendLog("Verify [ISO]: mounting ISO read-only…")
        let mountPoint = try await attachISOReadOnly(isoURL)
        do {
            state.appendLog("Verify [ISO]: SHA-256 of every file inside the ISO…")
            let isoCount = try await checkManifest(root: mountPoint, level: "ISO", state: state)
            summary.append("ISO image contents: PASSED (\(isoCount) files, SHA-256)")
            if settings.par2Enabled {
                let sets = try await verifyPar2Sets(root: mountPoint, expected: expectedPar2Sets, level: "ISO", state: state)
                summary.append("ISO PAR2 sets: PASSED (\(sets) set(s), par2 verify)")
            }
        } catch {
            await detachImage(mountPoint)
            throw error
        }
        await detachImage(mountPoint)

        if settings.verifyMode == .deep && settings.burnAfterISO {
            let discMount = try await locateBurnedMediaMountPoint(settings: settings, state: state)
            let (_, info) = try await runner.runCollecting(
                launchPath: ToolResolver.diskutilExecutable(),
                arguments: ["info", discMount.path]
            )
            if !info.localizedCaseInsensitiveContains("optical") {
                state.appendLog("WARNING: \(discMount.path) does not report as optical media; make sure this is the burned disc.")
            }
            state.appendLog("Verify [burned disc]: SHA-256 of every file on \(discMount.path)…")
            let discCount = try await checkManifest(root: discMount, level: "burned disc", state: state)
            summary.append("Burned disc contents: PASSED (\(discCount) files, SHA-256)")
            if settings.par2Enabled {
                let sets = try await verifyPar2Sets(root: discMount, expected: expectedPar2Sets, level: "burned disc", state: state)
                summary.append("Burned disc PAR2 sets: PASSED (\(sets) set(s), par2 verify)")
            }
        } else if settings.burnAfterISO {
            summary.append("Burned disc: NOT VERIFIED (choose Deep verify to check the disc)")
        } else {
            summary.append("Burned disc: NOT VERIFIED (burn disabled — ISO only)")
        }
        return summary
    }

    /// Checks `<root>/_BluArchive/SHA256SUMS.txt` against the files under `root`; returns the file count.
    private func checkManifest(root: URL, level: String, state: BackupState) async throws -> Int {
        let manifest = root
            .appendingPathComponent(Self.archiveMetaFolderName, isDirectory: true)
            .appendingPathComponent(Self.discManifestName)
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw NSError(
                domain: "BDXLBackup",
                code: 37,
                userInfo: [NSLocalizedDescriptionKey: "Verify [\(level)] failed: checksum manifest missing at \(manifest.path)"]
            )
        }
        let log = Self.logger(for: state)
        let result = try await Self.offMain {
            try ChecksumManifest.verify(manifest: manifest, root: root, onProgress: { log("  checked \($0) files…") })
        }
        guard result.passed else {
            let shown = result.failures.prefix(25).joined(separator: "\n")
            let more = result.failures.count > 25 ? "\n… and \(result.failures.count - 25) more" : ""
            throw NSError(
                domain: "BDXLBackup",
                code: 38,
                userInfo: [NSLocalizedDescriptionKey: "Verify [\(level)] failed: \(result.failures.count) of \(result.checkedCount) file(s) differ:\n\(shown)\(more)"]
            )
        }
        state.appendLog("Verify [\(level)]: SHA-256 OK for \(result.checkedCount) file(s).")
        return result.checkedCount
    }

    /// Runs `par2 verify` for every set under `<root>/_BluArchive/par2`; returns the number of sets checked.
    private func verifyPar2Sets(root: URL, expected: Int, level: String, state: BackupState) async throws -> Int {
        guard let par2 = await ToolResolver.par2Executable() else {
            throw NSError(domain: "BDXLBackup", code: 9, userInfo: [NSLocalizedDescriptionKey: "par2 disappeared from PATH."])
        }
        let par2Dir = root
            .appendingPathComponent(Self.archiveMetaFolderName, isDirectory: true)
            .appendingPathComponent("par2", isDirectory: true)
        let sets = ((try? FileManager.default.contentsOfDirectory(at: par2Dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "par2" && !$0.lastPathComponent.contains(".vol") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard sets.count == expected else {
            throw NSError(
                domain: "BDXLBackup",
                code: 39,
                userInfo: [NSLocalizedDescriptionKey: "Verify [\(level)] failed: expected \(expected) PAR2 set(s), found \(sets.count) in \(par2Dir.path)"]
            )
        }
        for set in sets {
            try Task.checkCancellation()
            let args = ["verify", "-q", "-B\(root.path)", set.path]
            let (code, out) = try await runner.runCollecting(launchPath: par2, arguments: args)
            if code != 0 {
                throw NSError(
                    domain: "BDXLBackup",
                    code: 40,
                    userInfo: [NSLocalizedDescriptionKey: "Verify [\(level)] failed: par2 verify \(set.lastPathComponent) exited \(code):\n\(out.suffix(2000))"]
                )
            }
        }
        state.appendLog("Verify [\(level)]: par2 verify OK for \(sets.count) set(s).")
        return sets.count
    }

    /// Mounts the ISO read-only at a private mount point (not under /Volumes, so it cannot be
    /// mistaken for the burned disc).
    private func attachISOReadOnly(_ isoURL: URL) async throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("BluArchive-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let (code, out) = try await runner.runCollecting(
            launchPath: ToolResolver.hdiutilExecutable(),
            arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path, isoURL.path]
        )
        if code != 0 {
            try? FileManager.default.removeItem(at: mountPoint)
            throw NSError(
                domain: "BDXLBackup",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "Verify [ISO] failed: could not mount ISO:\n\(out)"]
            )
        }
        return mountPoint
    }

    private func detachImage(_ mountPoint: URL) async {
        let hdiutil = ToolResolver.hdiutilExecutable()
        if let (code, _) = try? await runner.runCollecting(launchPath: hdiutil, arguments: ["detach", mountPoint.path]), code == 0 {
        } else {
            _ = try? await runner.runCollecting(launchPath: hdiutil, arguments: ["detach", "-force", mountPoint.path])
        }
        // Only remove the mount point once it is an empty, unmounted directory.
        if (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: mountPoint)
        }
    }

    private func containsNonEmptyRegularFile(_ item: URL) -> Bool {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
            return (v.fileSize ?? 0) > 0
        }
        guard let e = FileManager.default.enumerator(at: item, includingPropertiesForKeys: keys) else {
            return false
        }
        while let url = e.nextObject() as? URL {
            if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, (v.fileSize ?? 0) > 0 {
                return true
            }
        }
        return false
    }

    private func discReadme(settings: BackupJobSettings, sourceName: String, par2SetCount: Int) -> String {
        let label = settings.volumeLabel
        let created = ISO8601DateFormatter().string(from: Date())
        let par2Section = settings.par2Enabled
            ? """
            par2/ — \(par2SetCount) PAR2 recovery set(s), one per top-level item, \(settings.par2RedundancyPercent)% redundancy.
              File names inside each set are relative to the disc root (e.g. "1928/photo.jpg"), so pass -B:
                par2 verify -B "/Volumes/\(label)" "/Volumes/\(label)/_BluArchive/par2/001_<name>.par2"
              To repair: copy the damaged item AND _BluArchive/par2 to a writable disk, keeping the layout, then run
                par2 repair -B "<copy root>" "<copy root>/_BluArchive/par2/<set>.par2"
              Items that are empty or contain only 0-byte files have no PAR2 set (SHA-256 still covers them).
            """
            : "PAR2 was disabled for this disc."
        return """
        BluArchive disc — \(label)
        Source folder: \(sourceName)
        Created: \(created)

        The disc root holds the original folder structure unchanged. This folder adds:

        SHA256SUMS.txt — SHA-256 of every original file (paths relative to the disc root). Check with:
          cd "/Volumes/\(label)" && shasum -a 256 -c _BluArchive/SHA256SUMS.txt

        \(par2Section)

        """
    }

    nonisolated private static func logger(for state: BackupState) -> @Sendable (String) -> Void {
        { message in Task { @MainActor in state.appendLog(message) } }
    }

    /// Runs blocking file work (hashing) off the main actor; cancellation of the pipeline task propagates.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: work)
            return try await group.next()!
        }
    }

    private func topLevelItemsForPar2(in source: URL) throws -> [URL] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let filtered = entries.filter { entry in
            let name = entry.lastPathComponent
            if name.hasPrefix(".") { return false }
            if name == ".DS_Store" { return false }
            if name == Self.archiveMetaFolderName { return false }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else {
                return false
            }
            return true
        }
        return filtered.sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private func par2BaseName(for item: URL, index: Int) -> String {
        let raw = item.lastPathComponent
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitizedScalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(sanitizedScalars)
        let fallback = sanitized.isEmpty ? "item" : sanitized
        return String(format: "%03d_%@.par2", index + 1, fallback)
    }

    private func throwIfBadExit(_ code: Int32, cmd: String) throws {
        if code != 0 {
            throw NSError(
                domain: "BDXLBackup",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Command failed (\(code)): \(cmd)"]
            )
        }
    }

    private func freeSpaceBytes(at folder: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
        guard let free = attrs[.systemFreeSize] as? NSNumber else {
            throw NSError(domain: "BDXLBackup", code: 50, userInfo: [NSLocalizedDescriptionKey: "Could not read free space for output volume."])
        }
        return free.int64Value
    }

    private func estimatedFolderSizeBytes(at folder: URL) async throws -> Int64 {
        let (code, out) = try await runner.runCollecting(
            launchPath: ToolResolver.duExecutable(),
            arguments: ["-sk", folder.path]
        )
        guard code == 0 else {
            throw NSError(domain: "BDXLBackup", code: 51, userInfo: [NSLocalizedDescriptionKey: "du failed:\n\(out)"])
        }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0.isWhitespace })
        guard let kb = parts.first, let n = Int64(kb) else {
            throw NSError(domain: "BDXLBackup", code: 52, userInfo: [NSLocalizedDescriptionKey: "Could not parse du output: \(out)"])
        }
        return n * 1024
    }

    private func formatBytes(_ b: Int64) -> String {
        let mb = Double(b) / (1024 * 1024)
        if mb > 1000 {
            return String(format: "%.2f GiB", mb / 1024)
        }
        return String(format: "%.1f MiB", mb)
    }
}
