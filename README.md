# BluArchive (macOS)

Native SwiftUI macOS app that runs the same workflow as `bluray.sh`:

**TAR → PAR2 → SHA256 manifest → UDF/ISO (`hdiutil makehybrid`) → optional burn (`hdiutil burn`) → optional verify**

## Requirements

- macOS 12.3+
- Xcode or Swift toolchain (`swift`)
- **par2** (e.g. `brew install par2`)
- Blu-ray writer supported by macOS

SwiftPM platform declarations are coarse (`.macOS(.v12)`), but this app's effective minimum is macOS 12.3+.

## Build CLI binary

```bash
cd BDXLBackupApp
swift build -c release
```

Run the binary (opens GUI):

```bash
open .build/arm64-apple-macosx/release/BDXLBackupApp
# or: swift run -c release
```

## Build `.app` bundle

```bash
chmod +x scripts/create_app_bundle.sh
./scripts/create_app_bundle.sh
```

Output: `build/BluArchive.app`

Open with **right-click → Open** the first time if Gatekeeper prompts.

## Usage

1. **Choose** source folder and output folder.
2. Pick **media profile** (25 / 50 / 100 / 128 GB class) — sizes are **safe payload** limits, not marketing capacity.
3. Set **TAR first** (recommended for reliability) and **PAR2** toggle.
4. If PAR2 is enabled, adjust **PAR2 redundancy** (default 12%). With TAR off, the source is copied to staging and PAR2 creates one set per top-level source item (`par2 create -R -B <disc root>`), stored with a per-file `SHA256SUMS.txt` and a `README.txt` in `_BluArchive/` on the disc. Empty items (no non-empty files) get no PAR2 set but are covered by the SHA-256 manifest. The staging copy is data-only (contents, dates, file permissions) and leaves Finder metadata (`.DS_Store`, `._*` AppleDouble sidecars) out of the archive. Each PAR2 set gets its file list as `@filelist` (built by BluArchive, recursive, sidecars excluded; `par2 -R` would also pick up the `._*` files macOS writes on exFAT for every new file, which `hdiutil makehybrid` leaves off the ISO) and an explicit block size (`-s`): the smallest power of two from 64 KiB that keeps the set within max(3,000, 1.5 × file count) source blocks. The log and status line show set *n of m*, file count, block size, source/recovery blocks, par2 progress and elapsed time, with a heartbeat every minute.
5. Optionally **burn**; pick drive or enter **BSD device** (e.g. `disk4`).
6. Choose **verify** mode. TAR on: **quick** checks the staging TAR checksum, **deep** also checks the burned media checksum (no `hdiutil verify` gate). TAR off: **quick** checks every file's SHA-256 in staging and inside the read-only mounted ISO plus `par2 verify` of every set in the ISO; **deep** also runs both checks on the burned disc. The log ends with a per-level summary; levels not checked are reported as NOT VERIFIED.
7. **Export diagnostics** saves settings + full log.

## Runbook / test matrix

| Step | Check |
|------|--------|
| Preflight | Missing `par2` → clear error in log |
| Small dataset | ISO-only (burn off), quick verify |
| Capacity guard | Source larger than profile safe GiB → rejected before TAR |
| Burn | External writer, slowest speed; then run quick/deep verify mode |
| Cancel | Cancel during copy/TAR/PAR2 → child gets SIGTERM (SIGKILL after 20 s), run ends as Cancelled, no ISO/burn |

## Notes

- Staging directory: `<output>/_bdxl_work` (removed after success unless **Keep staging** is on).
- ISO path: `<output>/<volume label>.iso`
- This app **orchestrates** system tools; it is not a custom disc encoding engine.

## License

Use and modify for personal archival workflows.
