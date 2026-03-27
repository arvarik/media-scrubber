#!/usr/bin/env bash
# ==============================================================================
# Ultimate Media Scrubber
# Safe for Radarr/Sonarr Hardlinks, Plex-Ready, TrueNAS/Unraid Optimized
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

show_help() {
    cat << EOF
🎬 Ultimate Media Scrubber
Usage: \$(basename "\$0") -d <directory> [OPTIONS]

A robust utility to safely scrub non-target audio and subtitle tracks from MKV 
and external SRT files. Designed safely for open-source NAS environments.

Required:
  -d, --dir <path>          Target directory containing media files.

Options:
  -l, --langs <langs>       Comma-separated list of language codes to KEEP.
                            (Default: 'eng,en'). 'und', 'zxx', and 'mis' are always kept.
  --live                    ⚠️ RUN IN LIVE MODE. Modifies and deletes files.
                            (Default is DRY-RUN mode for safety).
  --process-hardlinks       Process hardlinked files.
                            (Default: skipped to prevent destroying torrent seeds).
  --min-age <minutes>       Skip files modified within this many minutes.
                            (Default: 60 - prevents modifying active downloads).
  --engine <engine>         Execution engine: 'auto', 'docker', or 'native'.
                            (Default: 'auto' - prefers docker if available).
  --image <image>           Specify a custom FFmpeg Docker image.
                            (Default: linuxserver/ffmpeg:latest)
  -h, --help                Show this help menu and exit.

Examples:
  # Dry-run on a directory (safe default)
  \$(basename "\$0") -d /mnt/media/movies

  # Live run, keeping English and Japanese tracks natively
  \$(basename "\$0") -d /mnt/media/anime -l "eng,en,jpn,ja" --live --engine native
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
        --engine) ENGINE="$2"; shift 2 ;;
        --image) DOCKER_IMAGE="$2"; shift 2 ;;
        --internal-run) INTERNAL_RUN="true"; shift 1 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "❌ Unknown parameter: $1"; exit 1 ;;
    esac
done

if [[ -z "$TARGET_DIR" || ! -d "$TARGET_DIR" ]]; then
    echo "❌ Error: Target directory (-d) is invalid or not provided: '$TARGET_DIR'"
    exit 1
fi

# ==============================================================================
# PHASE 1: HOST BOOTSTRAPPER (Runs on Host OS to setup environment)
# ==============================================================================
if [[ "$INTERNAL_RUN" == "false" ]]; then
    TARGET_DIR=$(cd "$TARGET_DIR" &>/dev/null && pwd) # Convert to absolute path
    
    # --- LOCKFILE & LOGGING ---
    # Lock hash based on target dir allowing concurrent runs on different dirs
    if command -v md5sum >/dev/null 2>&1; then
        LOCK_HASH=$(echo -n "$TARGET_DIR" | md5sum | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
        LOCK_HASH=$(echo -n "$TARGET_DIR" | md5 | awk '{print $1}')
    else
        LOCK_HASH=$(echo -n "$TARGET_DIR" | tr -c 'a-zA-Z0-9' '_')
    fi
    LOCK_FILE="/tmp/media_scrubber_${LOCK_HASH}.lock"

    # Use flock if available (Linux) or fallback to simple lockdir (macOS)
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo "❌ Another instance is currently processing $TARGET_DIR. Exiting."
            exit 1
        fi
    else
        if ! mkdir "${LOCK_FILE}.dir" 2>/dev/null; then
            echo "❌ Another instance is currently processing $TARGET_DIR. Exiting."
            exit 1
        fi
        trap 'rm -rf "${LOCK_FILE}.dir"' EXIT INT TERM
    fi

    # Initialize Logging
    LOG_DIR="${TARGET_DIR}/.scrubber_logs"
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/scrubber_log_$(date +%Y%m%d_%H%M%S).txt"
    exec > >(tee -a "$LOG_FILE") 2>&1

    echo "===================================================================="
    echo "🎬 Ultimate Media Scrubber Initialized"
    echo "===================================================================="
    echo "📁 Target Directory : $TARGET_DIR"
    echo "🗣️  Languages Kept   : $KEEP_LANGS (+ und, zxx, mis)"
    echo "⏱️  Min File Age     : $MIN_AGE_MINS minutes"
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

    if [[ "$ENGINE" == "docker" ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            echo "❌ Error: Docker is not installed."
            exit 1
        fi
        
        # Determine cross-platform UID/GID map for TrueNAS/Unraid safe processing
        if stat -c "%u" "$TARGET_DIR" >/dev/null 2>&1; then
            TARGET_UID=$(stat -c "%u" "$TARGET_DIR")
            TARGET_GID=$(stat -c "%g" "$TARGET_DIR")
        else
            TARGET_UID=$(stat -f "%u" "$TARGET_DIR" 2>/dev/null || id -u)
            TARGET_GID=$(stat -f "%g" "$TARGET_DIR" 2>/dev/null || id -g)
        fi
        
        MOUNT_OPTS=$([[ "$DRY_RUN" == "true" ]] && echo "ro" || echo "rw")
        
        # Self-Piping Docker Execution: Safely feeds itself into the container
        docker run --rm -i \
            --user "$TARGET_UID:$TARGET_GID" \
            --network none \
            -v "$TARGET_DIR:/media_mount:$MOUNT_OPTS" \
            --entrypoint /bin/bash \
            "$DOCKER_IMAGE" -s \
            --internal-run \
            -d "/media_mount" \
            $([[ "$DRY_RUN" == "false" ]] && echo "--live") \
            -l "$KEEP_LANGS" \
            $([[ "$SKIP_HARDLINKS" == "false" ]] && echo "--process-hardlinks") \
            --min-age "$MIN_AGE_MINS" \
            < "$0"
            
        exit $?
    elif [[ "$ENGINE" == "native" ]]; then
        if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
            echo "❌ Error: ffmpeg or ffprobe not found in PATH."
            exit 1
        fi
        
        # Re-invoke itself natively bypassing bootstrap
        "$0" --internal-run \
            -d "$TARGET_DIR" \
            $([[ "$DRY_RUN" == "false" ]] && echo "--live") \
            -l "$KEEP_LANGS" \
            $([[ "$SKIP_HARDLINKS" == "false" ]] && echo "--process-hardlinks") \
            --min-age "$MIN_AGE_MINS"
            
        exit $?
    else
        echo "❌ Error: Unknown engine '$ENGINE'"
        exit 1
    fi
fi

# ==============================================================================
# PHASE 2: INTERNAL WORKER PAYLOAD (Runs inside Docker or Natively)
# ==============================================================================

trap 'echo -e "\n🛑 Interrupted! Cleaning up..."; [ -n "${tmp_file:-}" ] && rm -f "$tmp_file" 2>/dev/null; exit 1' INT TERM

# Construct Regex for Languages to Keep
IFS=',' read -r -a lang_arr <<< "$KEEP_LANGS"
KEEP_REGEX="^(und|zxx|mis"
for lang in "${lang_arr[@]}"; do
    lang=$(echo "$lang" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [[ -n "$lang" ]] && KEEP_REGEX="${KEEP_REGEX}|${lang}"
done
KEEP_REGEX="${KEEP_REGEX})(-[a-z0-9]+)?$"

# Standard ISO-639 codes to prevent false positive matches on unknown strings like 'movie.HDR.srt'
KNOWN_LANGS="ab|aa|af|ak|sq|am|ar|ara|an|hy|as|av|ae|ay|az|bm|ba|eu|be|bn|bh|bi|bs|br|bg|bul|my|ca|ch|ce|ny|zh|zho|chi|zh-tw|zh-cn|zh-hk|zh-sg|zh-hant|zh-hans|cv|kw|co|cr|hr|hrv|cs|cze|ces|da|dan|nl|dut|nld|dz|eo|et|est|ee|fo|fj|fi|fin|fr|fre|fra|ff|gl|ka|de|ger|deu|el|gre|ell|gn|gu|ht|ha|he|heb|hz|hi|hin|ho|hu|hun|ig|is|io|ii|iu|ie|ia|id|ind|ik|it|ita|jv|ja|jpn|kl|kn|ks|kr|kk|km|ki|rw|ky|kv|kg|ko|kor|ku|kj|la|lb|lg|li|ln|lo|lt|lit|lu|lv|lav|gv|mk|mg|ms|may|msa|ml|mt|mi|mr|mh|mn|na|nv|nd|ne|ng|nb|nn|no|nor|ii|nr|oc|oj|cu|om|or|os|pa|pi|fa|per|fas|pl|pol|ps|pt|por|pt-br|pt-pt|qu|rm|rn|ro|rum|ron|ru|rus|sa|sc|sd|se|sm|sg|sr|srp|gd|sn|si|sk|slk|slo|sl|slv|so|st|es|spa|su|sw|ss|sv|swe|ta|te|tg|th|tha|ti|bo|tib|bod|tk|tl|tn|to|tr|tur|ts|tt|tw|ty|ug|uk|ukr|ur|uz|ve|vi|vie|vo|wa|cy|wel|cym|wo|fy|xh|yi|yo|za|zu"
KNOWN_LANGS_REGEX="^(${KNOWN_LANGS})(-[a-z0-9]+)?$"

START_TIME=$(date +%s)
if du -s -k "$TARGET_DIR" >/dev/null 2>&1; then
    INITIAL_REPO_BYTES=$(du -s -k "$TARGET_DIR" | awk '{print $1 * 1024}')
else
    INITIAL_REPO_BYTES=0
fi

STAT_SRT_TOTAL=0; STAT_SRT_REMOVED=0; STAT_MKV_TOTAL=0; STAT_MKV_ALTERED=0
STAT_MKV_SKIPPED_LINKS=0; STAT_MKV_SKIPPED_AGE=0; STAT_DRY_RUN_SRT_BYTES=0

format_bytes() {
    awk -v bytes="$1" 'BEGIN {
        split("B KB MB GB TB", type)
        for(i=1; bytes>=1024 && i<5; i++) bytes/=1024
        printf "%.2f %s\n", bytes, type[i]
    }'
}

# POSIX wrappers for stat (supports GNU Linux and macOS/BSD natively)
get_file_size() { stat -c "%s" "$1" 2>/dev/null || stat -f "%z" "$1" 2>/dev/null || echo 0; }
get_file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
get_file_links() { stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null || echo 1; }

echo ""
echo "===================================================================="
echo "Phase 1: Efficiently Cleaning External Non-Target .srt Files"
echo "===================================================================="

while IFS= read -r -d "" subfile; do
    ((STAT_SRT_TOTAL++))
    filename=$(basename "$subfile")
    
    # Matches patterns like movie.es.srt, movie.spa.srt, movie.en-US.forced.srt
    if [[ "$filename" =~ \.([a-zA-Z]{2,3}(-[a-zA-Z]{2,4})?)(\.(forced|sdh|cc|hi|default))?\.srt$ ]]; then
        lang_code=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]') 
        lang_base="${lang_code%%-*}"
        
        # Verify it's actually a recognized ISO language code before making a decision
        if [[ "$lang_base" =~ $KNOWN_LANGS_REGEX ]]; then
            # If the language code does NOT match user's KEEP_REGEX, drop it
            if [[ ! "$lang_code" =~ $KEEP_REGEX ]]; then
                file_size=$(get_file_size "$subfile")
                
                if [[ "$DRY_RUN" == "true" ]]; then
                    echo "👀 [DRY-RUN] Would delete non-target subtitle: $filename"
                    ((STAT_DRY_RUN_SRT_BYTES+=file_size))
                else
                    echo "🗑️  Deleting non-target subtitle: $filename"
                    rm -f "$subfile"
                fi
                ((STAT_SRT_REMOVED++))
            fi
        fi
    fi
done < <(find "$TARGET_DIR" -type f -iname "*.srt" -print0)

echo ""
echo "===================================================================="
echo "Phase 2: Safely Scrubbing Embedded MKV Tracks"
echo "===================================================================="

if [[ "$DRY_RUN" == "false" ]]; then
    find "$TARGET_DIR" -type f -name "*.tmp.mkv" -mmin +120 -delete 2>/dev/null || true
fi

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
    PROBE_DATA=$(ffprobe -loglevel error -show_entries stream=index,codec_type:stream_tags=language -of csv=p=0 "$file" | tr -d '\r')
    
    DROP_ARGS=()
    AUDIO_TOTAL=0
    AUDIO_KEPT=0
    HAS_FOREIGN=0
    
    while IFS=, read -r idx codec lang rest; do
        [[ -n "$rest" ]] && lang="$lang,$rest"
        lang="${lang#"${lang%%[![:space:]]*}"}"
        lang="${lang%"${lang##*[![:space:]]}"}"
        lang=$(echo "$lang" | tr '[:upper:]' '[:lower:]')
        
        [[ -z "$idx" ]] && continue
        
        if [[ "$codec" == "audio" ]]; then
            ((AUDIO_TOTAL++))
            if [[ -z "$lang" || "$lang" =~ $KEEP_REGEX ]]; then
                ((AUDIO_KEPT++))
            else
                DROP_ARGS+=("-map" "-0:$idx")
                HAS_FOREIGN=1
            fi
        elif [[ "$codec" == "subtitle" ]]; then
            if [[ -z "$lang" || "$lang" =~ $KEEP_REGEX ]]; then
                : # Keep empty tags or matching languages
            else
                DROP_ARGS+=("-map" "-0:$idx")
                HAS_FOREIGN=1
            fi
        fi
    done <<< "$PROBE_DATA"
    
    if [[ "$HAS_FOREIGN" -eq 0 ]]; then continue; fi

    if [[ "$AUDIO_TOTAL" -gt 0 ]] && [[ "$AUDIO_KEPT" -eq 0 ]]; then
        echo "⚠️  WARNING: Stripping foreign audio leaves $(basename "$file") SILENT! Skipping."
        continue
    fi

    echo "------------------------------------------------"
    echo "⚙️  Processing: $(basename "$file")"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "   👀 [DRY-RUN] FFmpeg drop maps calculated as: ${DROP_ARGS[*]}"
        ((STAT_MKV_ALTERED++))
        continue
    fi
    
    # --- 4. Disk Space Pre-Check (POSIX Compliant using df -P) ---
    FILE_SIZE_BYTES=$(get_file_size "$file")
    REQUIRED_BYTES=$((FILE_SIZE_BYTES * 11 / 10)) # Needs 110% available
    AVAILABLE_KB=$(df -P -k "$TARGET_DIR" | awk 'NR==2 {print $4}' 2>/dev/null || echo 0)
    AVAILABLE_BYTES=$((AVAILABLE_KB * 1024))

    if [[ "$AVAILABLE_BYTES" -lt "$REQUIRED_BYTES" ]]; then
        echo "⚠️  WARNING: Insufficient disk space to process $(basename "$file"). Skipping."
        continue
    fi

    tmp_file="${file%.mkv}.tmp.mkv"
    
    # --- 5. FFmpeg Execution ---
    if ffmpeg -nostdin -y -v error -stats -i "$file" -map 0 "${DROP_ARGS[@]}" -c copy "$tmp_file"; then
        if [[ -s "$tmp_file" ]]; then
            OLD_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null | awk '{print int($1)}')
            NEW_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$tmp_file" 2>/dev/null | awk '{print int($1)}')
            
            if [[ -n "$OLD_DUR" ]] && [[ -n "$NEW_DUR" ]] && [[ "$OLD_DUR" -gt 0 ]]; then
                diff=$(( OLD_DUR - NEW_DUR ))
                diff=${diff#-} 
                
                if [[ "$diff" -le 5 ]]; then
                    touch -r "$file" "$tmp_file"
                    mv -f "$tmp_file" "$file"
                    echo "✅ Successfully cleaned and replaced."
                    ((STAT_MKV_ALTERED++))
                else
                    echo "❌ ERROR: Duration mismatch (Old: ${OLD_DUR}s, New: ${NEW_DUR}s). Aborting rewrite."
                    rm -f "$tmp_file"
                fi
            else
                if ffprobe -loglevel error -show_format "$tmp_file" >/dev/null 2>&1; then
                    touch -r "$file" "$tmp_file"
                    mv -f "$tmp_file" "$file"
                    echo "✅ Successfully cleaned and replaced (Verified via structural probe)."
                    ((STAT_MKV_ALTERED++))
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

if du -s -k "$TARGET_DIR" >/dev/null 2>&1; then
    FINAL_REPO_BYTES=$(du -s -k "$TARGET_DIR" | awk '{print $1 * 1024}')
else
    FINAL_REPO_BYTES=0
fi

if [[ "$DRY_RUN" == "true" ]]; then
    SPACE_SAVED_BYTES=$STAT_DRY_RUN_SRT_BYTES
    SPACE_SAVED_STR="$(format_bytes "$SPACE_SAVED_BYTES") (from SRTs only. MKV savings unknown until live run)"
else
    SPACE_SAVED_BYTES=$((INITIAL_REPO_BYTES - FINAL_REPO_BYTES))
    [[ "$SPACE_SAVED_BYTES" -lt 0 ]] && SPACE_SAVED_BYTES=0 
    SPACE_SAVED_STR="$(format_bytes "$SPACE_SAVED_BYTES")"
fi

echo ""
echo "===================================================================="
echo "📊 SCRUBBER TELEMETRY & STATISTICS"
echo "===================================================================="
printf "%-30s : %s\n" "Execution Mode" "$([[ "$DRY_RUN" == "true" ]] && echo 'DRY RUN' || echo 'LIVE COMMIT')"
printf "%-30s : %dh %dm %ds\n" "Elapsed Time" $((ELAPSED_SEC/3600)) $((ELAPSED_SEC%3600/60)) $((ELAPSED_SEC%60))
echo "--------------------------------------------------------------------"
printf "%-30s : %s\n" "Total SRTs Analyzed" "$STAT_SRT_TOTAL"
printf "%-30s : %s\n" "SRTs Flagged/Removed" "$STAT_SRT_REMOVED"
printf "%-30s : %s\n" "Total MKVs Analyzed" "$STAT_MKV_TOTAL"
printf "%-30s : %s\n" "MKVs Skipped (Hardlinks)" "$STAT_MKV_SKIPPED_LINKS"
printf "%-30s : %s\n" "MKVs Skipped (Recent)" "$STAT_MKV_SKIPPED_AGE"
printf "%-30s : %s\n" "MKVs Processed/Cleaned" "$STAT_MKV_ALTERED"
echo "--------------------------------------------------------------------"
printf "%-30s : %s\n" "Total Space Reclaimed" "$SPACE_SAVED_STR"
echo "===================================================================="
