# 🎬 Media Scrubber

An enterprise-grade utility that recursively scans your media directories and cleanly strips out non-target audio tracks, subtitles, and external `.srt` files to save massive amounts of disk space.

## ✨ Key Features

- **Safe Defaults**:
  - Runs in `DRY-RUN` mode by default. No files are modified unless you explicitly pass the `--live` flag.
  - **Silence Protection:** If a file only has non-target audio tracks (e.g., Korean-only, but you requested English), the scrubber gracefully skips it instead of rendering it completely silent.
- **Hardlink Safe**: Skips hardlinked files by default to prevent breaking links to your pristine source library.
- **Active Download Protection**: Skips files modified within the last 60 minutes (configurable) to avoid corrupting active downloads.
- **Engine Auto-Detection**: Automatically uses Docker (`linuxserver/ffmpeg:latest`) if available to keep your host OS clean, or falls back to native `ffmpeg`/`ffprobe`.
- **Comprehensive Scrubbing**:
  - Deletes non-target external `.srt` subtitle files.
  - Strips non-target embedded audio and subtitle tracks from `.mkv` files.
  - Always preserves `und` (undetermined), `zxx` (no linguistic content), and `mis` (uncoded languages) tracks to prevent accidental silence.
- **Junk File Cleanup**: Scrub out `.nfo`, `.txt`, `.url`, `.exe`, `.bat`, OS artifacts (`.DS_Store`, `Thumbs.db`, `._*`), sample videos under 50 MB, and prune empty directory trees using `--clean-junk`.
- **Metadata Scrubbing**: Strip hardcoded internal MKV titles (often scene release names) using `--strip-tags` so Plex reads the filename instead.
- **Stream Normalization**: Automatically sets the `default` flag on the first audio and subtitle tracks you keep so media players auto-select correctly.
- **Disk Space Pre-Checks**: Ensures at least 110% of the original file size is available before processing to prevent out-of-space crash corruptions.
- **Persistent Logging**: Every run appends a full transcript to `<TARGET_DIR>/.scrubber_logs/scrubber_log_YYYYMMDD_HHMMSS.txt` for auditing and post-run review.

## 📋 Prerequisites

To run this script, your system needs to meet **one** of the following requirements:

- **Docker** installed and running (Recommended for TrueNAS/Unraid).
  - *Install Guide:* [Get Docker](https://docs.docker.com/get-docker/)
- **Native `ffmpeg` and `ffprobe`** installed and available in your `$PATH`.
  - *Ubuntu/Debian:* `sudo apt install ffmpeg`
  - *macOS:* `brew install ffmpeg`
  - *Other:* [Download FFmpeg](https://ffmpeg.org/download.html)

## 📥 Installation

Download the executable script directly to your OS path and make it runnable:

```bash
sudo curl -L "https://raw.githubusercontent.com/arvarik/media-scrubber/main/media-scrubber.sh" -o /usr/local/bin/media-scrubber
sudo chmod +x /usr/local/bin/media-scrubber
```

## 🚀 Usage

```text
media-scrubber -d <directory> [OPTIONS]
```

### Required Arguments
- `-d, --dir <path>`: Target directory containing your media files.

### Options
- `-l, --langs <langs>`: Comma-separated list of ISO-639 language codes to KEEP. (Default: `eng,en`).
- `--live`: **⚠️ RUN IN LIVE MODE.** Modifies and deletes files. (Default is DRY-RUN mode for safety).
- `--process-hardlinks`: Process hardlinked files. (Warning: rewriting breaks the link and doubles disk usage). (Default: skipped).
- `--min-age <minutes>`: Skip files modified within this many minutes. Must be a non-negative integer. (Default: `60`).
- `--strip-tags`: Remove internal MKV `title` and `comment` metadata tags.
- `--clean-junk`: Delete `.nfo`, `.txt`, `.url`, `.exe`, `.bat`, `.DS_Store`, `Thumbs.db`, `._*`, sample media under 50 MB, & empty dirs.
- `--engine <engine>`: Execution engine: `auto`, `docker`, or `native`. (Default: `auto`).
- `--image <image>`: Specify a custom FFmpeg Docker image. (Default: `linuxserver/ffmpeg:latest`).
- `-h, --help`: Show the help menu and exit.

### Detailed Examples

**1. The "Safety First" Run (Dry-Run Default)**
By default, the script protects your files. This command purely simulates an English-only scrub. It prints out exactly what files and tracks *would* be removed, without touching a single byte on disk.
```bash
media-scrubber -d /mnt/media/movies
```

**2. The Aggressive "Clean Everything" Run (Live)**
The standard, set-and-forget use case. Destructively scrub your TV Shows with all capabilities enabled. Uses the Docker engine, strips non-English audio/subtitles, removes junk files (`.nfo`, empty directories, etc.), and clears internal MKV release titles.
```bash
media-scrubber -d /mnt/media/tvshows --live --clean-junk --strip-tags
```

**3. The "Anime Enthusiast" Run (Multi-Language)**
Perfect for foreign content. Keep both English and Japanese tracks while safely skipping any purely Korean/French files via the Silence Protection failsafe. Uses bare-metal native FFmpeg.
```bash
media-scrubber -d /mnt/media/anime -l "eng,en,jpn,ja" --live --engine native
```

**4. Accelerated Post-Processing (Bypass Min Age)**
Ignore the 60-minute active download protection check. Ideal for automated post-processing scripts where the file is guaranteed to have finished transferring.
```bash
media-scrubber -d /mnt/media/downloads --live --min-age 0
```

**5. Custom FFmpeg Docker Image**
Provide a custom FFmpeg Docker image — for example one optimized for Intel QuickSync, AMD, or Nvidia hardware.
```bash
media-scrubber -d /mnt/media/movies --live --image "jrottenberg/ffmpeg:vaapi"
```

## 🧠 Under The Hood

- **Cross-Platform UID/GID Mapping**: When using Docker, the script detects the target folder's owner (`UID`/`GID`) using `stat` with a GNU/BSD fallback. The container runs under that exact identity so files are never left permission-locked as `root:root`.
- **Concurrency Lockfiles**: Employs `flock` on Linux and an atomic `mkdir` fallback on macOS to prevent two instances from colliding on the *same* directory, while allowing concurrent runs on *different* directories. The lockfile is automatically cleaned up on exit — including normal exits, `Ctrl+C`, and `SIGTERM`.
- **Interruption Cleanup (`trap`)**: Pressing `Ctrl+C` midway through a large MKV rewrite traps the signal and immediately removes the half-written `.tmp.mkv` file rather than leaving it on disk.
- **Duration Integrity Validation**: After every FFmpeg remux, the output duration is compared against the original using float-precision arithmetic (via `awk`). If the difference exceeds 5 seconds, the rewrite is aborted and the original preserved. Falls back to a structural `ffprobe` format probe when duration metadata is unavailable.
- **Reporting & Telemetry**: Space savings are evaluated via `stat` locally (bypassing slow `du` calls over network shares) to print a detailed execution summary including space reclaimed, track counts, and elapsed time.

## 🛠️ Troubleshooting

- **Permission Denied / Docker Group Errors**
  The script automatically detects the target directory's `UID`/`GID` and runs the Docker container under that identity. If you still hit permission errors, ensure the user running the script has read/write access to the target directory, or use `sudo` (keeping in mind how your NAS maps root).

- **Lockfile Errors (`Another instance is currently processing...`)**
  The script creates a lockfile at `<TargetDirectory>/.scrubber_logs/run.lock` (or `run.lock.dir/` on macOS) to prevent concurrent runs on the same directory. The lockfile is automatically removed on clean exit, `Ctrl+C`, and `SIGTERM`. If the process was force-killed (`kill -9` / `SIGKILL`), which cannot be trapped, you may need to manually delete the stale lockfile:
  ```bash
  # Linux (flock-based)
  rm -f /your/media/dir/.scrubber_logs/run.lock
  # macOS (mkdir-based fallback)
  rm -rf /your/media/dir/.scrubber_logs/run.lock.dir
  ```

- **"Insufficient disk space" Warning**
  When scrubbing an `.mkv` file, the script writes to a temporary `.tmp.mkv` alongside the original before atomically replacing it. This requires roughly 110% of the file's current size in free space on the same drive. Free up space on the target drive to continue.

- **Files Are Being Skipped**
  - **Recent Modification**: By default, files modified within the last 60 minutes are skipped. Pass `--min-age 0` to disable this check entirely.
  - **Hardlinks**: Hardlinked files are skipped by default to preserve original linked copies. Pass `--process-hardlinks` to process them anyway (note: this will break the hardlink and double the disk space consumed by that file).
  - **Already Clean**: Files with no foreign audio/subtitle tracks (and no `--strip-tags` pending) are skipped automatically — no FFmpeg call is made.

- **`--engine native` Fails When Piped from curl**
  The `native` engine re-invokes the script itself (`$0`) and therefore requires it to exist as a saved file on disk. Running the script directly via `bash <(curl ...)` will fail with a clear error. Either save the script first (see [Installation](#-installation)), or use `--engine docker` (the default) which handles piped execution correctly.

- **Log Files Accumulating in My Media Directory**
  Every run creates a log at `<TARGET_DIR>/.scrubber_logs/scrubber_log_YYYYMMDD_HHMMSS.txt`. These are plain-text and safe to delete at any time. You can periodically prune old logs with:
  ```bash
  find /your/media/dir/.scrubber_logs -name "scrubber_log_*.txt" -mtime +30 -delete
  ```
