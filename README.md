# NAS Scripts Manager

A small, opinionated set of **PowerShell 7+** scripts for organizing and transferring media (Anime, TV, Movies) and for ingesting Photos/Video into a NAS-backed archive.

Core ideas:

* **Mover scripts live on the NAS share they target** (so the logic is stored with the data).
* Local “launcher” scripts in this repo run those NAS-hosted scripts via UNC paths.
* Operations are designed to be **safe to re-run** and **easy to understand** (clear console logging + progress bars).

---

## Folder layout

### Local machine

```text
E:\Sync
├─ Anime files (flat and/or packs)
├─ TV
│  ├─ loose episodes (optional)
│  └─ season / mini-series folders
└─ Movies
   ├─ movie folders
   └─ loose movie files
```

### NAS (example: \192.168.1.1)

```text
\\192.168.1.1
├─ anime
│  ├─ AnimeMover.ps1
│  └─ organized anime folders
├─ tv
│  ├─ TvMover.ps1
│  └─ organized TV series folders
├─ movies
│  ├─ MovieMover.ps1
│  └─ organized movie folders
└─ images
   ├─ Build-ExistingFilesIndex-Parallel.ps1
   ├─ Copy-ImagesPhotosIndex-Parallel.ps1
   └─ (date-based archive folders + index files)
```

---

## Media movers

All movers share the same behavior style:

* **Per-file logging** (COPIED / SKIPPED / ERROR with full source and destination)
* **Progress bar** with ETA and throughput
* **Skip-if-already-copied** when destination exists and file sizes match
* **Retry** on transient copy failures

### AnimeMover.ps1 (NAS-hosted)

* Source: `E:\Sync`
* Destination: `\\NAS\anime`
* Groups tagged anime files into series folders

Run directly (from a Windows machine that can reach the NAS):

```powershell
pwsh "\\192.168.1.1\anime\AnimeMover.ps1"
```

### TvMover.ps1 (NAS-hosted)

* Source: `E:\Sync\TV`
* Destination: `\\NAS\tv`
* Supports top-level folders (season packs) and loose files
* Derives series name from Sxx / SxxEyy patterns and common Season folder names

Run directly:

```powershell
pwsh "\\192.168.1.1\tv\TvMover.ps1"
```

### MovieMover.ps1 (NAS-hosted)

* Source: `E:\Sync\Movies`
* Destination: `\\NAS\movies`
* Copies entire movie folders as-is (preserves structure and empty folders)
* Also supports loose movie files

Run directly:

```powershell
pwsh "\\192.168.1.1\movies\MovieMover.ps1"
```

---

## Launchers in this repo

These scripts live in the GitHub repo and exist to run NAS-hosted scripts consistently.

### Run NAS movers (Anime, TV, Movies)

Use the launcher that points at the NAS share where each mover script lives and passes the standard parameters.

Typical usage:

```powershell
pwsh .\Run-NasMovers.ps1
```

Common parameters:

* `-SyncRoot` (default `E:\Sync`)
* `-NasAnimeRoot` (default `\\192.168.1.1\anime`)
* `-NasTvRoot` (if present in your launcher)
* `-NasMovieRoot` (default `\\192.168.1.1\movies`)
* `-LogEvery`
* `-ContinueOnError`

---

## Images / Photos archive pipeline

This repo includes a two-part workflow for ingesting photos and videos into a NAS archive while avoiding duplicates.

### Scripts on the NAS (in the images share)

These are intended to live at:

* `\\192.168.1.1\images\Build-ExistingFilesIndex-Parallel.ps1`
* `\\192.168.1.1\images\Copy-ImagesPhotosIndex-Parallel.ps1`

### 1) Build a destination hash index

**NAS script:** `Build-ExistingFilesIndex-Parallel.ps1`

What it does:

* Scans the destination tree under the images share
* Hashes destination files in parallel (PowerShell 7+)
* Writes a cache index file (default: `ExistingFilesIndex.clixml`) mapping Path -> Hash
* Uses a temp file + replace to avoid corrupt indexes

**Repo launcher:** `Run-ExistingFilesIndex.ps1`

Example:

```powershell
pwsh .\Run-ExistingFilesIndex.ps1 -NasRoot "\\192.168.1.1\images"
```

Useful parameters:

* `-ImageTarget` (defaults to the NAS root)
* `-CacheFileName` (default `ExistingFilesIndex.clixml`)
* `-Algorithm` (SHA256, SHA1, MD5)
* `-ThrottleLimit`, `-BatchSize`, `-ReportEvery`

### 2) Copy new photos/videos and update the index

**NAS script:** `Copy-ImagesPhotosIndex-Parallel.ps1`

What it does:

* Scans a source folder recursively
* Filters to common ingest extensions (currently includes: jpg, mp4, xml, arw)
* Hashes candidates in parallel
* Skips files already present in the destination (using the hash index)
* Copies new files into a date-based structure (year/month/day)
* Handles name collisions:

  * same name + same content: skip
  * same name + different content: write a "-new-" suffixed filename
* Updates the destination index (clixml)
* Tracks a sent list (default file name: `SentFiles.txt`) to avoid re-processing across runs

**Repo launcher:** `Run-ImagesPhotosIndex.ps1`

Example:

```powershell
pwsh .\Run-ImagesPhotosIndex.ps1 -ImageSource "D:\CameraDump" -NasRoot "\\192.168.1.1\images"
```

Notes:

* The sent list defaults to being written on the Desktop of the machine running the launcher.
* The index file lives on the NAS (default `ExistingFilesIndex.clixml`).

---

## Requirements

* Windows
* PowerShell 7+ (`pwsh`)
* Network access to the NAS via UNC paths
* Permissions to read from the source directories and write to the NAS shares

---

## Troubleshooting tips

* If a mover shows "0 files": check whether your source contains folders vs loose files and that the script’s source path is correct.
* If you see access denied errors: confirm share permissions and that the NAS path is reachable from the machine running the script.
* If progress bars look stuck: the job may be hashing large files; leave it running and watch the per-file logs.
