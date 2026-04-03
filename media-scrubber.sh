#!/usr/bin/env bash
# ==============================================================================
# Ultimate Media Scrubber
# Safe for Hardlinks, Plex-Ready, TrueNAS/Unraid Optimized
# ==============================================================================

set -uo pipefail

# --- CONFIGURATION & DEFAULTS ---
TARGET_DIR=""
DRY_RUN="true"
SKIP_HARDLINKS="true"
KEEP_LANGS="eng,en"
MIN_AGE_MINS=60
ENGINE="auto"
DOCKER_IMAGE="linuxserver/ffmpeg:latest"
INTERNAL_RUN="false"
STRIP_TAGS="false"
CLEAN_JUNK="false"

show_help() {
    cat <<EOF
🎬 Ultimate Media Scrubber
Usage: $(basename "$0") -d <directory> [OPTIONS]

A robust utility to safely scrub non-target audio, subtitles, titles, and junk files.
Designed safely for open-source NAS environments.

Required:
  -d, --dir <path>          Target directory containing media files.

Options:
  -l, --langs <langs>       Comma-separated list of language codes to KEEP.
                            (Default: 'eng,en'). 'und', 'zxx', and 'mis' are always kept.
  --live                    ⚠️ RUN IN LIVE MODE. Modifies and deletes files.
                            (Default is DRY-RUN mode for safety).
  --process-hardlinks       Process hardlinked files.
                            (Default: skipped to preserve linked source files).
  --min-age <minutes>       Skip files modified within this many minutes.
                            (Default: 60 - prevents modifying active downloads).
  --strip-tags              Remove internal MKV 'title' and 'comment' metadata tags.
  --clean-junk              Delete .nfo, .txt, .exe, sample media, and empty dirs.
  --engine <engine>         Execution engine: 'auto', 'docker', or 'native'.
                            (Default: 'auto' - prefers docker if available).
  --image <image>           Specify a custom FFmpeg Docker image.
                            (Default: linuxserver/ffmpeg:latest)
  -h, --help                Show this help menu and exit.

Examples:
  # Dry-run on a directory with junk cleaning and tag stripping enabled
  $(basename "$0") -d /mnt/media/movies --clean-junk --strip-tags

  # Live run, keeping English and Japanese tracks natively
  $(basename "$0") -d /mnt/media/anime -l "eng,en,jpn,ja" --live --engine native
EOF
}

# --- ARGUMENT PARSING ---
if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dir) TARGET_DIR="$2"; shift 2 ;;
        -l|--langs) KEEP_LANGS="$2"; shift 2 ;;
        --live) DRY_RUN="false"; shift 1 ;;
        --process-hardlinks) SKIP_HARDLINKS="false"; shift 1 ;;
        --min-age) MIN_AGE_MINS="$2"; shift 2 ;;
        --strip-tags) STRIP_TAGS="true"; shift 1 ;;
        --clean-junk) CLEAN_JUNK="true"; shift 1 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --image) DOCKER_IMAGE="$2"; shift 2 ;;
        --internal-run) INTERNAL_RUN="true"; shift 1 ;; # Internal: skips host bootstrap phase
        -h|--help) show_help; exit 0 ;;
        *) echo "❌ Unknown parameter: $1"; exit 1 ;;
    esac
done

# --- INPUT VALIDATION ---
if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    echo "❌ Error: Target directory (-d) is invalid or not provided: '$TARGET_DIR'"
    exit 1
fi

if ! [[ "$MIN_AGE_MINS" =~ ^[0-9]+$ ]]; then
    echo "❌ Error: --min-age must be a non-negative integer (got: '$MIN_AGE_MINS')."
    exit 1
fi

# ==============================================================================
# PHASE 1: HOST BOOTSTRAPPER (Runs on Host OS to setup environment)
# ==============================================================================
if [[ "$INTERNAL_RUN" == "false" ]]; then
    TARGET_DIR=$(cd "$TARGET_DIR" &>/dev/null && pwd) # Convert to absolute path

    # --- LOGGING & LOCKFILE ---
    LOG_DIR="${TARGET_DIR}/.scrubber_logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/scrubber_log_$(date +%Y%m%d_%H%M%S).txt"
    exec > >(tee -a "$LOG_FILE") 2>&1

    # Lock scoped to target dir, allowing concurrent runs on different dirs
    LOCK_FILE="${LOG_DIR}/run.lock"

    # Use flock if available (Linux) or fallback to atomic lockdir (macOS)
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "❌ Another instance is currently processing $TARGET_DIR. Exiting."
            exit 1
        fi
        # Clean up the lockfile on any exit (fd release is implicit, but the file persists)
        trap 'rm -f "$LOCK_FILE"' EXIT INT TERM
    else
        if ! mkdir "${LOCK_FILE}.dir" 2>/dev/null; then
            echo "❌ Another instance is currently processing $TARGET_DIR. Exiting."
            exit 1
        fi
        trap 'rm -rf "${LOCK_FILE}.dir"' EXIT INT TERM
    fi

    echo "===================================================================="
    echo "🎬 Ultimate Media Scrubber Initialized"
    echo "===================================================================="
    echo "📁 Target Directory : $TARGET_DIR"
    echo "🗣️  Languages Kept   : $KEEP_LANGS (+ und, zxx, mis)"
    echo "⏱️  Min File Age     : $MIN_AGE_MINS minutes"
    echo "🏷️  Strip MKV Tags   : $STRIP_TAGS"
    echo "🧹  Clean Junk Files : $CLEAN_JUNK"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "⚠️  MODE             : DRY-RUN (Read-Only)"
    else
        echo -e "🔥 MODE             : LIVE (Destructive)"
    fi

    # Engine Auto-Detection
    if [[ "$ENGINE" == "auto" ]]; then
        if command -v docker >/dev/null 2>&1; then
            ENGINE="docker"
        elif command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
            ENGINE="native"
        else
            echo "❌ Error: Neither Docker nor Native FFmpeg found. Exiting."
            exit 1
        fi
    fi

    echo "🛡️  Execution Engine : $ENGINE"
    echo "===================================================================="

    # Build optional-flags array to prevent empty-string word-splitting
    # when conditional flags are absent. Never expand an unquoted empty subshell.
    EXTRA_ARGS=()
    [[ "$DRY_RUN"       == "false" ]] && EXTRA_ARGS+=("--live")
    [[ "$SKIP_HARDLINKS" == "false" ]] && EXTRA_ARGS+=("--process-hardlinks")
    [[ "$STRIP_TAGS"     == "true"  ]] && EXTRA_ARGS+=("--strip-tags")
    [[ "$CLEAN_JUNK"     == "true"  ]] && EXTRA_ARGS+=("--clean-junk")

    if [[ "$ENGINE" == "docker" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            echo "❌ Error: Docker is not installed."
            exit 1
        fi

        echo "🐳 Verifying Docker Image ($DOCKER_IMAGE)..."
        # Emit a warning instead of silently ignoring pull failures
        if ! docker pull "$DOCKER_IMAGE" >/dev/null 2>&1; then
            echo "⚠️  WARNING: Could not pull $DOCKER_IMAGE. Proceeding with cached image if available."
        fi

        # Determine cross-platform UID/GID for TrueNAS/Unraid safe file ownership
        if stat -c "%u" "$TARGET_DIR" >/dev/null 2>&1; then
            TARGET_UID=$(stat -c "%u" "$TARGET_DIR")
            TARGET_GID=$(stat -c "%g" "$TARGET_DIR")
        else
            TARGET_UID=$(stat -f "%u" "$TARGET_DIR" 2>/dev/null || id -u)
            TARGET_GID=$(stat -f "%g" "$TARGET_DIR" 2>/dev/null || id -g)
        fi

        MOUNT_OPTS=$([[ "$DRY_RUN" == "true" ]] && echo "ro" || echo "rw")

        # Self-Piping Docker Execution: feeds the script itself into the container via stdin
        docker run --rm -i \
            --user "$TARGET_UID:$TARGET_GID" \
            --network none \
            -v "$TARGET_DIR:/media_mount:$MOUNT_OPTS" \
            --entrypoint /bin/bash \
            "$DOCKER_IMAGE" -s \
            --internal-run \
            -d "/media_mount" \
            -l "$KEEP_LANGS" \
            --min-age "$MIN_AGE_MINS" \
            "${EXTRA_ARGS[@]}" \
            < "$0"

        exit $?

    elif [[ "$ENGINE" == "native" ]]; then
        if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
            echo "❌ Error: ffmpeg or ffprobe not found in PATH."
            exit 1
        fi

        # Self-invocation requires a regular file; guard against pipe/process-substitution execution
        if [[ ! -f "$0" ]]; then
            echo "❌ Error: --engine native requires the script to be a regular file, not a pipe or stdin."
            echo "   Tip: Save the script to disk first, or use --engine docker instead."
            exit 1
        fi

        # Re-invoke itself natively, bypassing the host bootstrap phase
        "$0" --internal-run \
            -d "$TARGET_DIR" \
            -l "$KEEP_LANGS" \
            --min-age "$MIN_AGE_MINS" \
            "${EXTRA_ARGS[@]}"

        exit $?

    else
        echo "❌ Error: Unknown engine '$ENGINE'. Valid options: auto, docker, native."
        exit 1
    fi
fi

# ==============================================================================
# PHASE 2: INTERNAL WORKER PAYLOAD (Runs inside Docker or Natively)
# ==============================================================================

trap 'echo -e "\n🛑 Interrupted! Cleaning up..."; [ -n "${tmp_file:-}" ] && rm -f "$tmp_file" 2>/dev/null; exit 1' INT TERM

# Construct regex for languages to keep
IFS=',' read -r -a lang_arr <<< "$KEEP_LANGS"
KEEP_REGEX="^(und|zxx|mis"
for lang in "${lang_arr[@]}"; do
    lang="${lang// /}"
    lang="${lang,,}"
    [[ -n "$lang" ]] && KEEP_REGEX="${KEEP_REGEX}|${lang}"
done
KEEP_REGEX="${KEEP_REGEX})(-[a-z0-9]+)?$"

# ISO-639-1/2/3 known language codes (as of 2025).
# Used to filter SRT filenames with recognizable language codes vs unstructured names.
KNOWN_LANGS="ab|aa|af|ak|sq|am|ar|ara|an|hy|as|av|ae|ay|az|bm|ba|eu|be|bn|bh|bi|bs|br|bg|bul|my|ca|ch|ce|ny|zh|zho|chi|zh-tw|zh-cn|zh-hk|zh-sg|zh-hant|zh-hans|cv|kw|co|cr|hr|hrv|cs|cze|ces|da|dan|nl|dut|nld|dz|eo|et|est|ee|fo|fj|fi|fin|fr|fre|fra|ff|gl|ka|de|ger|deu|el|gre|ell|gn|gu|ht|ha|he|heb|hz|hi|hin|ho|hu|hun|ig|is|io|ii|iu|ie|ia|id|ind|ik|it|ita|jv|ja|jpn|kl|kn|ks|kr|kk|km|ki|rw|ky|kv|kg|ko|kor|ku|kj|la|lb|lg|li|ln|lo|lt|lit|lu|lv|lav|gv|mk|mg|ms|may|msa|ml|mt|mi|mr|mh|mn|na|nv|nd|ne|ng|nb|nn|no|nor|ii|nr|oc|oj|cu|om|or|os|pa|pi|fa|per|fas|pl|pol|ps|pt|por|pt-br|pt-pt|qu|rm|rn|ro|rum|ron|ru|rus|sa|sc|sd|se|sm|sg|sr|srp|gd|sn|si|sk|slk|slo|sl|slv|so|st|es|spa|su|sw|ss|sv|swe|ta|te|tg|th|tha|ti|bo|tib|bod|tk|tl|tn|to|tr|tur|ts|tt|tw|ty|ug|uk|ukr|ur|uz|ve|vi|vie|vo|wa|cy|wel|cym|wo|fy|xh|yi|yo|za|zu"
KNOWN_LANGS_REGEX="^(${KNOWN_LANGS})(-[a-z0-9]+)?$"

START_TIME=$(date +%s)

STAT_SRT_TOTAL=0; STAT_SRT_REMOVED=0; STAT_MKV_TOTAL=0; STAT_MKV_ALTERED=0
STAT_MKV_SKIPPED_LINKS=0; STAT_MKV_SKIPPED_AGE=0; STAT_MKV_CLEAN_SKIPS=0
STAT_SRT_SAVED_BYTES=0; STAT_MKV_SAVED_BYTES=0
STAT_JUNK_REMOVED=0; STAT_DIRS_REMOVED=0; STAT_JUNK_SAVED_BYTES=0
STAT_AUDIO_DROPPED=0; STAT_SUB_DROPPED=0; STAT_TAGS_STRIPPED=0; STAT_STREAMS_ANALYZED=0

format_bytes() {
    awk -v bytes="$1" 'BEGIN {
        split("B KB MB GB TB", type)
        for(i=1; bytes>=1024 && i<5; i++) bytes/=1024
        printf "%.2f %s\n", bytes, type[i]
    }'
}

get_file_size()  { stat -c "%s" "$1" 2>/dev/null || stat -f "%z" "$1" 2>/dev/null || echo 0; }
get_file_mtime() { stat -c  %Y  "$1" 2>/dev/null || stat -f  %m  "$1" 2>/dev/null || echo 0; }
get_file_links() { stat -c  '%h' "$1" 2>/dev/null || stat -f  '%l' "$1" 2>/dev/null || echo 1; }

# Helper: commit a successfully remuxed tmp file over the original.
# Usage: commit_output [description_suffix]
# Reads from outer-scope: file, tmp_file, FILE_SIZE_BYTES, AUDIO_TOTAL, AUDIO_KEPT,
#                         SUB_TOTAL, SUB_KEPT, NEEDS_TAG_STRIP
commit_output() {
    local NEW_SIZE_BYTES SAVED_BYTES
    NEW_SIZE_BYTES=$(get_file_size "$tmp_file")
    SAVED_BYTES=$((FILE_SIZE_BYTES - NEW_SIZE_BYTES))
    [[ "$SAVED_BYTES" -lt 0 ]] && SAVED_BYTES=0

    # Preserve original mtime; non-fatal if filesystem doesn't support it
    touch -r "$file" "$tmp_file" || true
    mv -f "$tmp_file" "$file"
    echo "✅ Successfully cleaned and replaced${1:+ ($1)}."
    ((STAT_MKV_ALTERED++))
    ((STAT_MKV_SAVED_BYTES+=SAVED_BYTES))
    ((STAT_AUDIO_DROPPED += (AUDIO_TOTAL - AUDIO_KEPT)))
    ((STAT_SUB_DROPPED   += (SUB_TOTAL  - SUB_KEPT)))
    [[ "$NEEDS_TAG_STRIP" -eq 1 ]] && ((STAT_TAGS_STRIPPED++))
}

echo ""
echo "===================================================================="
echo "Phase 1: Efficiently Cleaning External Non-Target .srt Files"
echo "===================================================================="

while IFS= read -r -d "" subfile; do
    ((STAT_SRT_TOTAL++))
    filename=$(basename "$subfile")

    if [[ "$filename" =~ \.([a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?)(\.(forced|sdh|cc|hi|default))?\.srt$ ]]; then
        lang_code="${BASH_REMATCH[1],,}"
        lang_base="${lang_code%%-*}"

        if [[ "$lang_base" =~ $KNOWN_LANGS_REGEX ]]; then
            if [[ ! "$lang_code" =~ $KEEP_REGEX ]]; then
                file_size=$(get_file_size "$subfile")

                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "👀 [DRY-RUN] Would delete non-target subtitle: $filename"
                else
                    echo "🗑️  Deleting non-target subtitle: $filename"
                    rm -f "$subfile"
                fi
                ((STAT_SRT_SAVED_BYTES+=file_size))
                ((STAT_SRT_REMOVED++))
            fi
        fi
    fi
done < <(find "$TARGET_DIR" -type f -iname "*.srt" -print0)

echo ""
echo "===================================================================="
echo "Phase 1.5: Scrubbing Junk/Sample Files & Empty Directories"
echo "===================================================================="
if [[ "$CLEAN_JUNK" == "true" ]]; then
    while IFS= read -r -d "" junkfile; do
        junk_size=$(get_file_size "$junkfile")
        filename=$(basename "$junkfile")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "👀 [DRY-RUN] Would delete junk file: $filename"
        else
            echo "🗑️  Deleting junk file: $filename"
            rm -f "$junkfile"
        fi
        ((STAT_JUNK_REMOVED++))
        ((STAT_JUNK_SAVED_BYTES+=junk_size))
    done < <(find "$TARGET_DIR" -type f \( -iname "*.nfo" -o -iname "*.txt" -o -iname "*.url" -o -iname "*.exe" -o -iname "*.com" -o -iname "*.bat" -o -iname ".DS_Store" -o -iname "Thumbs.db" -o -iname "._*" \) -print0; find "$TARGET_DIR" -type f \( -iname "*sample*.mkv" -o -iname "*sample*.mp4" -o -iname "*sample*.avi" \) -size -50M -print0)

    if [[ "$DRY_RUN" == "false" ]]; then
        while IFS= read -r -d "" emptydir; do
            echo "🗑️  Deleting empty directory: $(basename "$emptydir")"
            rmdir "$emptydir" 2>/dev/null || true
            ((STAT_DIRS_REMOVED++))
        done < <(find "$TARGET_DIR" -depth -type d -empty -print0)
    else
        # In dry-run, files weren't deleted, so only already-empty dirs are found.
        # Count and label these accurately; a live run may remove additional dirs freed by junk deletion.
        while IFS= read -r -d "" emptydir; do
            echo "👀 [DRY-RUN] Would delete empty directory: $(basename "$emptydir")"
            ((STAT_DIRS_REMOVED++))
        done < <(find "$TARGET_DIR" -depth -type d -empty -print0)
    fi
else
    echo "⏭️  Junk cleaning skipped (use --clean-junk to enable)."
fi

echo ""
echo "===================================================================="
echo "Phase 2: Safely Scrubbing Embedded MKV Tracks & Metadata"
echo "===================================================================="

if [[ "$DRY_RUN" == "false" ]]; then
    find "$TARGET_DIR" -type f -name "*.tmp.mkv" -mmin +120 -delete 2>/dev/null || true
fi

# Snapshot current time once before the loop. A 60-minute age check does
# not require per-file syscall granularity, and this avoids thousands of fork()s.
CURRENT_TIME=$(date +%s)

while IFS= read -r -d "" file; do
    ((STAT_MKV_TOTAL++))

    # --- 1. Minimum Age Safety Check ---
    if [[ "$MIN_AGE_MINS" -gt 0 ]]; then
        file_mtime=$(get_file_mtime "$file")
        if [[ "$file_mtime" -gt 0 ]]; then
            file_age_min=$(( (CURRENT_TIME - file_mtime) / 60 ))
            if [[ "$file_age_min" -lt "$MIN_AGE_MINS" ]]; then
                echo "⏭️  Skipping: $(basename "$file") (Modified ${file_age_min}m ago < threshold)."
                ((STAT_MKV_SKIPPED_AGE++))
                continue
            fi
        fi
    fi

    # --- 2. Hardlink Safety Check ---
    if [[ "$SKIP_HARDLINKS" == "true" ]]; then
        links=$(get_file_links "$file")
        if [[ "$links" -gt 1 ]]; then
            echo "⏭️  Skipping: $(basename "$file") is hardlinked ($links links)."
            ((STAT_MKV_SKIPPED_LINKS++))
            continue
        fi
    fi

    # --- 3. Track Probe ---
    # Use awk to produce clean tab-delimited output from ffprobe's CSV,
    # extracting exactly the first 3 fields (index, codec_type, language).
    # This eliminates ambiguity from comma-containing values and fragile multi-field re-joining.
    PROBE_DATA=$(ffprobe -loglevel error \
        -show_entries stream=index,codec_type:stream_tags=language \
        -of csv=p=0 "$file" | tr -d '\r' | awk -F',' '{print $1 "\t" $2 "\t" $3}')

    DROP_ARGS=()
    AUDIO_TOTAL=0
    AUDIO_KEPT=0
    SUB_TOTAL=0
    SUB_KEPT=0
    HAS_FOREIGN=0
    NEEDS_TAG_STRIP=0

    [[ "$STRIP_TAGS" == "true" ]] && NEEDS_TAG_STRIP=1

    while IFS=$'\t' read -r idx codec lang; do
        lang="${lang#"${lang%%[![:space:]]*}"}"
        lang="${lang%"${lang##*[![:space:]]}"}"
        lang="${lang,,}"

        [[ -z "$idx" ]] && continue

        if [[ "$codec" == "audio" ]]; then
            ((AUDIO_TOTAL++))
            ((STAT_STREAMS_ANALYZED++))
            if [[ -z "$lang" || "$lang" =~ $KEEP_REGEX ]]; then
                ((AUDIO_KEPT++))
            else
                DROP_ARGS+=("-map" "-0:$idx")
                HAS_FOREIGN=1
            fi
        elif [[ "$codec" == "subtitle" ]]; then
            ((SUB_TOTAL++))
            ((STAT_STREAMS_ANALYZED++))
            if [[ -z "$lang" || "$lang" =~ $KEEP_REGEX ]]; then
                ((SUB_KEPT++))
            else
                DROP_ARGS+=("-map" "-0:$idx")
                HAS_FOREIGN=1
            fi
        fi
    done <<< "$PROBE_DATA"

    if [[ "$HAS_FOREIGN" -eq 0 ]] && [[ "$NEEDS_TAG_STRIP" -eq 0 ]]; then
        ((STAT_MKV_CLEAN_SKIPS++))
        continue
    fi

    if [[ "$AUDIO_TOTAL" -gt 0 ]] && [[ "$AUDIO_KEPT" -eq 0 ]]; then
        echo "⚠️  WARNING: Stripping foreign audio leaves $(basename "$file") SILENT! Skipping."
        continue
    fi

    echo "------------------------------------------------"
    echo "⚙️  Processing: $(basename "$file")"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "   👀 [DRY-RUN] FFmpeg drop maps calculated as: ${DROP_ARGS[*]}"
        [[ "$NEEDS_TAG_STRIP" -eq 1 ]] && echo "   👀 [DRY-RUN] Stripping Title/Comment Metadata Tags"
        ((STAT_MKV_ALTERED++))
        ((STAT_AUDIO_DROPPED += (AUDIO_TOTAL - AUDIO_KEPT)))
        ((STAT_SUB_DROPPED   += (SUB_TOTAL  - SUB_KEPT)))
        [[ "$NEEDS_TAG_STRIP" -eq 1 ]] && ((STAT_TAGS_STRIPPED++))
        continue
    fi

    # --- 4. Disk Space Pre-Check ---
    FILE_SIZE_BYTES=$(get_file_size "$file")
    REQUIRED_BYTES=$((FILE_SIZE_BYTES * 11 / 10))
    AVAILABLE_KB=$(df -P -k "$TARGET_DIR" | awk 'NR==2 {print $4}' 2>/dev/null || echo 0)
    AVAILABLE_BYTES=$((AVAILABLE_KB * 1024))

    if [[ "$AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]]; then
        echo "⚠️  WARNING: Insufficient disk space to process $(basename "$file"). Skipping."
        continue
    fi

    tmp_file="${file%.mkv}.tmp.mkv"

    # --- 5. Generate Dynamic FFmpeg Args ---
    FF_DISPOSITION=()
    if [[ "$AUDIO_KEPT" -gt 0 ]]; then
        FF_DISPOSITION+=("-disposition:a" "0" "-disposition:a:0" "default")
    fi
    if [[ "$SUB_KEPT" -gt 0 ]]; then
        FF_DISPOSITION+=("-disposition:s" "0" "-disposition:s:0" "default")
    fi

    FF_METADATA=()
    if [[ "$NEEDS_TAG_STRIP" -eq 1 ]]; then
        FF_METADATA+=("-metadata" "title=" "-metadata" "comment=")
    fi

    # --- 6. FFmpeg Execution ---
    if ffmpeg -nostdin -y -v error -stats -i "$file" -map 0 "${DROP_ARGS[@]}" -c copy "${FF_DISPOSITION[@]}" "${FF_METADATA[@]}" "$tmp_file"; then
        if [[ -s "$tmp_file" ]]; then
            # Get raw float durations to avoid integer-truncation artefacts in the
            # duration diff check (e.g. 5.6s diff truncated to 5 would pass; 5.4s truncated
            # to 5 on each side, producing diff=0, would incorrectly hide a real drift).
            OLD_DUR_RAW=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null)
            NEW_DUR_RAW=$(ffprobe -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$tmp_file" 2>/dev/null)

            # Scrub missing duration "N/A" outputs to trigger structural integrity fallback
            [[ "$OLD_DUR_RAW" == "N/A" ]] && OLD_DUR_RAW=""
            [[ "$NEW_DUR_RAW" == "N/A" ]] && NEW_DUR_RAW=""

            if [[ -n "$OLD_DUR_RAW" ]] && [[ -n "$NEW_DUR_RAW" ]]; then
                # Float-safe comparison via awk (threshold: ±5 seconds)
                if awk "BEGIN { diff = $OLD_DUR_RAW - $NEW_DUR_RAW; if (diff < 0) diff = -diff; exit (diff <= 5 ? 0 : 1) }"; then
                    commit_output
                else
                    OLD_DUR_INT=$(printf "%.0f" "$OLD_DUR_RAW")
                    NEW_DUR_INT=$(printf "%.0f" "$NEW_DUR_RAW")
                    echo "❌ ERROR: Duration mismatch (Old: ${OLD_DUR_INT}s, New: ${NEW_DUR_INT}s). Aborting rewrite."
                    rm -f "$tmp_file"
                fi
            else
                # Duration unavailable; fall back to structural integrity probe
                if ffprobe -loglevel error -show_format "$tmp_file" >/dev/null 2>&1; then
                    commit_output "verified via structural probe"
                else
                    echo "❌ ERROR: Output file failed structural integrity probe. Aborting rewrite."
                    rm -f "$tmp_file"
                fi
            fi
        else
            echo "❌ ERROR: FFmpeg output is empty. Aborting rewrite."
            rm -f "$tmp_file"
        fi
    else
        echo "❌ ERROR: FFmpeg processing failed. Aborting rewrite."
        rm -f "$tmp_file"
    fi
    tmp_file=""
done < <(find "$TARGET_DIR" -type f -iname "*.mkv" ! -name "*.tmp.mkv" -print0)

# --- EMIT STATISTICS ---
END_TIME=$(date +%s)
ELAPSED_SEC=$((END_TIME - START_TIME))

TOTAL_SAVED_BYTES=$((STAT_SRT_SAVED_BYTES + STAT_MKV_SAVED_BYTES + STAT_JUNK_SAVED_BYTES))

if [[ "$DRY_RUN" == "true" ]]; then
    SPACE_SAVED_STR="$(format_bytes "$TOTAL_SAVED_BYTES") (from non-MKV files. MKV savings unknown until live run)"
else
    SPACE_SAVED_STR="$(format_bytes "$TOTAL_SAVED_BYTES")"
fi

echo ""
echo "===================================================================="
echo "📊 SCRUBBER TELEMETRY & STATISTICS"
echo "===================================================================="
printf "%-30s : %s\n" "Execution Mode" "$([[ "$DRY_RUN" == "true" ]] && echo 'DRY RUN' || echo 'LIVE COMMIT')"
printf "%-30s : %dh %dm %ds\n" "Elapsed Time" $((ELAPSED_SEC/3600)) $((ELAPSED_SEC%3600/60)) $((ELAPSED_SEC%60))
echo "--------------------------------------------------------------------"

[[ "$STAT_SRT_TOTAL"   -gt 0 ]] && printf "%-30s : %s\n" "Total Ext-SRTs Analyzed"    "$STAT_SRT_TOTAL"
[[ "$STAT_SRT_REMOVED" -gt 0 ]] && printf "%-30s : %s\n" "Ext-SRTs Flagged/Removed"   "$STAT_SRT_REMOVED"

if [[ "$CLEAN_JUNK" == "true" ]]; then
    [[ "$STAT_JUNK_REMOVED" -gt 0 ]] && printf "%-30s : %s\n" "Junk Files Removed" "$STAT_JUNK_REMOVED"
    if [[ "$STAT_DIRS_REMOVED" -gt 0 ]]; then
        # Use accurate label based on mode — dry-run finds, live mode removes
        if [[ "$DRY_RUN" == "true" ]]; then
            printf "%-30s : %s\n" "Empty Dirs Found (Pre-existing)" "$STAT_DIRS_REMOVED"
        else
            printf "%-30s : %s\n" "Empty Dirs Removed" "$STAT_DIRS_REMOVED"
        fi
    fi
fi

printf "%-30s : %s\n" "Total MKVs Analyzed"           "$STAT_MKV_TOTAL"
[[ "$STAT_STREAMS_ANALYZED"  -gt 0 ]] && printf "%-30s : %s\n" "Internal Streams Analyzed"    "$STAT_STREAMS_ANALYZED"
[[ "$STAT_MKV_CLEAN_SKIPS"   -gt 0 ]] && printf "%-30s : %s\n" "MKVs Skipped (Already Clean)" "$STAT_MKV_CLEAN_SKIPS"
[[ "$STAT_MKV_SKIPPED_LINKS" -gt 0 ]] && printf "%-30s : %s\n" "MKVs Skipped (Hardlinks)"     "$STAT_MKV_SKIPPED_LINKS"
[[ "$STAT_MKV_SKIPPED_AGE"   -gt 0 ]] && printf "%-30s : %s\n" "MKVs Skipped (Recent)"        "$STAT_MKV_SKIPPED_AGE"
[[ "$STAT_MKV_ALTERED"       -gt 0 ]] && printf "%-30s : %s\n" "MKVs Processed/Cleaned"       "$STAT_MKV_ALTERED"

[[ "$STAT_AUDIO_DROPPED"     -gt 0 ]] && printf "%-30s : %s\n" "Audio Streams Removed"        "$STAT_AUDIO_DROPPED"
[[ "$STAT_SUB_DROPPED"       -gt 0 ]] && printf "%-30s : %s\n" "Subtitle Streams Removed"     "$STAT_SUB_DROPPED"
[[ "$STAT_TAGS_STRIPPED"     -gt 0 ]] && printf "%-30s : %s\n" "Metadata Tags Stripped"       "$STAT_TAGS_STRIPPED"

echo "--------------------------------------------------------------------"
if [[ "$STAT_MKV_SAVED_BYTES" -gt 0 ]]; then
    printf "%-30s : %s\n" "Reclaimed (MKV Streams)"    "$(format_bytes "$STAT_MKV_SAVED_BYTES")"
fi
JUNK_EXT_TOTAL=$((STAT_SRT_SAVED_BYTES + STAT_JUNK_SAVED_BYTES))
if [[ "$JUNK_EXT_TOTAL" -gt 0 ]]; then
    printf "%-30s : %s\n" "Reclaimed (Junk & Ext Subs)" "$(format_bytes "$JUNK_EXT_TOTAL")"
fi
printf "%-30s : %s\n" "Total Space Reclaimed" "$SPACE_SAVED_STR"

if [[ "$ELAPSED_SEC" -gt 0 ]] && [[ "$STAT_MKV_ALTERED" -gt 0 ]]; then
    SPEED_SEC=$((ELAPSED_SEC / STAT_MKV_ALTERED))
    printf "%-30s : ~%ss per scrubbed MKV\n" "Average Processing Speed" "$SPEED_SEC"
fi
echo "===================================================================="
