# BluArchive (fixed fork)

A native SwiftUI macOS app that archives a folder (family photos, documents) to Blu-ray or BDXL discs and puts checksums and PAR2 recovery data on the disc itself.

**Source folder → (TAR) → PAR2 → SHA-256 manifest → UDF/ISO → burn → verify**

This is a fork of [fireflydev/BluArchive](https://github.com/fireflydev/BluArchive), branch `BluArchiveMonterey`. It makes the **non-TAR mode** reliable. That mode produces browsable discs where every file is stored as-is, protected by PAR2 and checkable with standard tools. See [What this fork changes](#what-this-fork-changes).

> The prebuilt apps under `build/` in this repository come from the upstream project and **do not contain these fixes**. Build the app yourself (see [Build](#build)).

---

## Contents

- [Requirements](#requirements)
- [Build](#build)
- [Usage](#usage)
- [TAR on or off?](#tar-on-or-off)
- [What ends up on the disc](#what-ends-up-on-the-disc)
- [Verification](#verification)
- [Checking and repairing a disc later](#checking-and-repairing-a-disc-later)
- [Disc-safe file names](#disc-safe-file-names)
- [Disk space and where files are written](#disk-space-and-where-files-are-written)
- [Troubleshooting](#troubleshooting)
- [What this fork changes](#what-this-fork-changes)
- [Branches](#branches)
- [Testing](#testing)
- [Limitations](#limitations)

---

## Requirements

- macOS 12.3 or later, on Apple Silicon or Intel.
- A Swift toolchain: Xcode or the Command Line Tools (`xcode-select --install`).
- [par2cmdline](https://github.com/Parchive/par2cmdline): `brew install par2`. Tested with 1.4.0.
- A Blu-ray writer that macOS can burn to. You only need it for burning; the app can create the ISO without one.

## Build

```bash
git clone https://github.com/nanoben/BluArchive.git
cd BluArchive
git checkout fix/disc-safe-names
./scripts/create_app_bundle.sh
```

This builds a universal binary (arm64 + x86_64) and writes an ad hoc signed `build/BluArchive.app`.

The script reads these optional environment variables. Use them to put a new build next to an existing app instead of replacing it:

| Variable | Default | Example |
|---|---|---|
| `APP_NAME` | `BluArchive` | `"BluArchive Fixed 1.3"` |
| `OUT_DIR` | `<repo>/build` | `~/Applications` |
| `BUNDLE_ID` | `local.bdxl.BDXLBackupApp` | `local.bdxl.BluArchiveFixed` |
| `APP_VERSION` | `1.0` | `1.3` |
| `BUILD_NUMBER` | `1` | `4` |

```bash
APP_NAME="BluArchive Fixed 1.3" APP_VERSION=1.3 BUILD_NUMBER=4 ./scripts/create_app_bundle.sh
```

The app is not notarized. If Gatekeeper blocks it the first time, right-click the app and choose **Open**.

To run the app without building a bundle, use `swift run -c release`.

## Usage

1. **Source folder** is the folder to archive. The app only reads it; it never renames, moves or changes anything in it.
2. **Output folder** is where the work files and the ISO go. **Pick a disk with plenty of free space** (see [Disk space](#disk-space-and-where-files-are-written)). The app does not remember this choice. If you leave it empty, the app uses `~/Documents/BluArchive Staging` on the startup disk.
3. **Volume label** is the name of the disc.
4. **Media profile** is BD-R 25 GB, BD-R DL 50 GB, BDXL TL 100 GB or BDXL QL 128 GB. The sizes are safe payload limits, not the number printed on the box. The source plus the PAR2 data must fit, or the run stops before anything is written.
5. **TAR first**: when on, the disc holds one TAR file. When off, it holds the folder structure as-is. See [TAR on or off?](#tar-on-or-off).
6. **PAR2** and **redundancy** (default 12%) set how much recovery data to add.
7. **Burn**: pick the drive and speed (slower is safer), or turn burning off to produce only the ISO.
8. **Verify**: None, Quick or Deep. See [Verification](#verification).
9. Press **Start**. The log and status line show the current stage, PAR2 set *n of m*, percentages and elapsed time.
10. **Cancel** stops the running tool cleanly: it sends SIGTERM and only sends SIGKILL if the tool is still running after 20 s. A cancelled run never creates an ISO or burns a disc.
11. **Export diagnostics** saves the settings and the full log to a text file.

## TAR on or off?

| | TAR first **on** | TAR first **off** (recommended for photo archives) |
|---|---|---|
| On the disc | `<name>.tar`, PAR2 files, checksum | Original folders and files, plus `_BluArchive/` |
| Opening a single photo | Extract the TAR first | Open it directly in Finder or on any OS |
| PAR2 | One set for the TAR | One set per top-level item (for example, per year folder) |
| Checksums | One for the TAR | One per file (`SHA256SUMS.txt`) |
| Space needed in the output folder | About 2× the source | About 2.1× the source, plus PAR2 |

## What ends up on the disc

This is the layout with TAR off:

```
/Volumes/<label>/
├── 1975/ …                  your folders and files, structure unchanged
├── 1978/ …
└── _BluArchive/
    ├── README.txt           how to check and repair this disc
    ├── SHA256SUMS.txt       SHA-256 of every file (shasum format)
    ├── RENAMED.txt          only if names had to change (original → name on disc)
    └── par2/
        ├── 001_1975.par2
        ├── 001_1975.vol000+…par2
        └── …
```

The disc keeps file contents, modification dates and permissions. Finder metadata (`.DS_Store` and `._*` AppleDouble files) is left out.

The source folder must not contain a top-level item named `_BluArchive`, because that name is reserved for the disc.

## Verification

With TAR off, every check runs **before burning**, so a bad ISO is never burned.

| Mode | Checks |
|---|---|
| **None** | Nothing. |
| **Quick** | 1. Staging copy: compares the SHA-256 of every file against the manifest made from the **originals**.<br>2. ISO, mounted read-only: SHA-256 of every file, plus `par2 verify` of every set. |
| **Deep** | Everything in Quick. Then, after burning, the same SHA-256 and PAR2 checks on the burned disc. |

The log ends with a summary for each level (staging, ISO and disc). A level that was not checked is reported as **NOT VERIFIED**, never as passed.

With TAR on, Quick checks the TAR checksum in staging, and Deep also checks it on the burned disc.

## Checking and repairing a disc later

You don't need the app for this. You only need `shasum` (built into macOS) and `par2`.

**Check every file:**

```bash
cd "/Volumes/<label>"
shasum -a 256 -c _BluArchive/SHA256SUMS.txt
```

**Check with PAR2.** The file names inside each set are relative to the disc root, so pass `-B`:

```bash
par2 verify -B "/Volumes/<label>" "/Volumes/<label>/_BluArchive/par2/001_1975.par2"
```

**Repair.** A disc is read-only, so first copy the damaged folder **and** `_BluArchive/par2` to a writable disk, keeping the same layout. Then run:

```bash
par2 repair -B "/path/to/copy" "/path/to/copy/_BluArchive/par2/001_1975.par2"
```

Folders that are empty or hold only 0-byte files get no PAR2 set, because par2 cannot protect them. They are still covered by `SHA256SUMS.txt`.

## Disc-safe file names

Some names change when macOS reads them back from a UDF disc. A changed name breaks the checksums and the PAR2 sets. The rules below were measured with `hdiutil makehybrid -udf -iso -joliet` on macOS.

| Problem | Example | Name on disc |
|---|---|---|
| `:` in the name. This is how Finder stores a `/` that you type in a name. | `17/11/2007` | `17-11-2007` |
| The name is longer than 127 characters and contains a character above U+00FF (for example `–`) | A long title ending in `.jpg` | Shortened, with `~` marking the cut and the extension kept |
| The new name already exists in the folder | `a:b` next to `a-b` | `a-b (2)` |

- Only the **copy** on the disc is renamed. Your originals keep their names.
- Every rename is listed in the log and in `_BluArchive/RENAMED.txt`.
- Before copying anything, the app builds a small test image with all the planned names and checks that each one reads back unchanged. If one would not, the run stops within seconds and lists the affected names. Nothing has been copied at that point.
- All other special characters, such as `?`, `*`, `"`, `æøå` and emoji, are stored unchanged. par2 prints a warning about `?` because Windows does not allow it in file names. On macOS the warning is harmless.

## Disk space and where files are written

Everything is written to the **output folder** you choose:

- `<output>/_bdxl_work/` holds the staging copy, the PAR2 file lists and, in TAR mode, the TAR. It is deleted at the start of every run. It is also deleted after a successful run, unless **Keep staging** is on.
- `<output>/<volume label>.iso` is the disc image.

The app writes only two other things elsewhere: a tiny name-test image and temporary mount points in the system temp folder. Both are removed right away.

With TAR off, plan for about **2.1× the source size, plus PAR2**, in the output folder: one staging copy and one ISO. The app checks this before it starts. For a 90 GB archive, use an external disk, not the startup disk.

Memory use stays flat at about 100 MB, however large the archive is. Versions before 1.3 leaked memory while hashing, which pushed macOS into gigabytes of swap on the startup disk. See [What this fork changes](#what-this-fork-changes).

## Troubleshooting

| Message or symptom | Cause and fix |
|---|---|
| `par2 not found. Install with: brew install par2` | Install par2 with Homebrew. |
| `Insufficient free disk space at output…` | Choose an output folder on a disk with more free space. |
| `Source is larger than safe limit for …` | Choose a larger media profile or split the source. |
| `Output folder must be outside the source folder…` | Choose an output folder that is not inside the source. |
| `… name(s) would change on the disc; nothing was copied…` | A name that the rules above don't cover yet. The log lists it. Rename it in the source, or report it. |
| The startup disk fills up during a run | Either the output folder is on the startup disk, so choose an external one, or you are on a version before 1.3 (the swap leak), so update. |
| par2 sits at 100% CPU with no progress (old versions) | The pipe deadlock that this fork fixes. Cancel, update and run again. |
| `Ignoring out of basepath source file` from par2 (old versions) | A Unicode normalization mismatch (`å` stored as NFC vs NFD). Fixed in this fork. |
| Gatekeeper refuses to open the app | Right-click the app and choose **Open**. The app is ad hoc signed, not notarized. |

## What this fork changes

All changes apply to the **TAR off** mode unless noted otherwise.

**PAR2 that works without TAR** (`fix/par2-non-tar-mode`)
- `hdiutil makehybrid` takes a single folder. The app now copies the source to staging and places the PAR2 sets and checksums next to the files. Upstream left them off the disc.
- There is one PAR2 set per top-level item, with correct base paths (`-B`), so spaces and Unicode in names work.
- Verification is real and never reports a false success: SHA-256 of every file, plus `par2 verify` on the ISO and on the disc.

**Performance and robustness** (`fix/par2-performance`)
- Fixed the par2 hang. Upstream read tool output with blocking reads on Swift's cooperative thread pool. On large sets, nothing emptied the 64 KB pipe, so par2 blocked in `write()` while its other threads spun at 100% CPU. GCD handlers now read the output as it arrives.
- The PAR2 block size is planned per set from the file count and data size. This keeps each set within par2's block limit and avoids padding waste on many small photos.
- par2 gets an explicit file list (`@filelist`) instead of scanning folders recursively. On exFAT, macOS writes a `._` file for every new file. `par2 -R` protected those too, but the ISO doesn't contain them, so verification failed.
- File paths are built from directory listings, so NFC/NFD differences can no longer break par2's byte-wise path matching.
- The staging copy holds data only, with no Finder metadata. Progress and heartbeat logging and clean cancel handling were added.

**Disc-safe names and memory** (`fix/disc-safe-names`, app 1.2–1.3)
- Names the disc can't store are renamed automatically, with the name test and `RENAMED.txt`. See [Disc-safe file names](#disc-safe-file-names).
- Verification of staging and the ISO now runs before burning.
- 1.3: hashing uses constant memory. Before, every 4 MB chunk stayed in memory until the run ended. On a 1.9 GB test run, peak RAM dropped from 2.0 GB to 95 MB.
- New preflight checks: the output folder must be outside the source, there must be enough free space, and the disc must have room for the source plus the PAR2 data.

## Branches

| Branch | Contents |
|---|---|
| `fix/disc-safe-names` | **Latest.** Everything below, plus renaming and the memory fix |
| `fix/par2-performance` | Hang fix, file lists, progress |
| `fix/par2-non-tar-mode` | PAR2 and verification without TAR |
| `main` | Upstream, unchanged |

## Testing

Tested on macOS (Apple Silicon) with par2cmdline 1.4.0, using synthetic data on APFS and exFAT. Burning was switched off for every run.

- Non-TAR and TAR runs end to end, with the ISO also checked separately using `shasum -c` and `par2 verify`.
- PAR2 repair: a damaged file and a deleted file were both restored bit-identical.
- Names with spaces, `æøå` (NFC and NFD), `:`, `?`, long names and collisions.
- Scale: 2.2 GB in 3,000 files, and 8,000 small files.
- Cancel, external kill and tool failure: no ISO, no burn and no orphaned par2 process.
- After every run, the source folder was checked and was unchanged, in both names and contents.

**Not tested by this fork:** physical burning, and reading the discs on Windows or Linux.

## Limitations

- Finder tags, resource forks and other extended attributes are not stored on the disc. File contents, dates and permissions are.
- The app runs system tools (`par2`, `hdiutil`, `shasum`, `tar`, `drutil`). It is not its own disc engine.
- Burning uses `hdiutil burn`. Test with a spare disc before archiving anything irreplaceable.

## License

Use and modify for personal archival workflows (same terms as upstream).
