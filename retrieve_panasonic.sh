#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Retrieve Recordings from Panasonic Camcorder (AVCHD SD Card)
#
# Imports MTS clips from an AVCHD SD card, renames them with the original
# recording timestamp extracted from the MPL playlist, and optionally
# uploads to the 4t server.
#
# The AVCHD binary playlist stores the original recording date/time for
# each clip in a BCD-encoded PLEX extension section. This script parses
# that to recover the real timestamps, then:
#   1. Converts .MTS (AVCHD) to .mp4 via ffmpeg -c copy (no re-encode)
#   2. Names output as panasonic_YYYYMMDD_HHMMSS.mp4
#   3. Sets file modification time to the original recording time
#   4. Uploads to 4t server
#
# Files are saved locally and uploaded to the 4t server:
#   Local:   /Users/paul2/j40/data/sd_data/panasonic/
#   Remote:  4t:/home/pa91/data/recordings/panasonic/
#
# Usage:
#   ./retrieve_panasonic.sh <avchd_path>                    # Import all clips
#   ./retrieve_panasonic.sh <avchd_path> <start> <end>      # Filter by time
#   ./retrieve_panasonic.sh upload                           # Upload only
#
# Examples:
#   ./retrieve_panasonic.sh /Volumes/SD_CARD/PRIVATE/AVCHD
#   ./retrieve_panasonic.sh /Users/paul2/PRIVATE/AVCHD
#   ./retrieve_panasonic.sh /Volumes/SD_CARD/PRIVATE/AVCHD "2025-03-15 08:00" "2025-03-15 12:00"
#   SKIP_UPLOAD=1 ./retrieve_panasonic.sh /Users/paul2/PRIVATE/AVCHD
#
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local base directory
LOCAL_BASE="/Users/paul2/j40/data/sd_data"
OUTPUT_DIR="${LOCAL_BASE}/panasonic"

# Remote server for upload (ssh alias "4t")
REMOTE_HOST="4t"
REMOTE_BASE="/home/pa91/data/recordings"
REMOTE_DIR="${REMOTE_BASE}/panasonic"

# Skip upload if set to 1
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"

# =============================================================================
# Logging
# =============================================================================

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# =============================================================================
# Progress helpers
# =============================================================================

format_bytes() {
  local bytes=$1
  if [[ $bytes -ge 1073741824 ]]; then
    echo "$(( bytes / 1073741824 )).$(( (bytes % 1073741824) * 10 / 1073741824 )) GB"
  elif [[ $bytes -ge 1048576 ]]; then
    echo "$(( bytes / 1048576 )) MB"
  elif [[ $bytes -ge 1024 ]]; then
    echo "$(( bytes / 1024 )) KB"
  else
    echo "${bytes} B"
  fi
}

format_duration() {
  local secs=$1
  if [[ $secs -ge 3600 ]]; then
    printf "%dh %dm %ds" $((secs / 3600)) $(( (secs % 3600) / 60 )) $((secs % 60))
  elif [[ $secs -ge 60 ]]; then
    printf "%dm %ds" $((secs / 60)) $((secs % 60))
  else
    printf "%ds" "$secs"
  fi
}

show_progress() {
  local current=$1 total=$2 bytes_done=$3 bytes_total=$4 elapsed=$5

  local pct=0
  if [[ $bytes_total -gt 0 ]]; then
    pct=$(( bytes_done * 100 / bytes_total ))
  elif [[ $total -gt 0 ]]; then
    pct=$(( current * 100 / total ))
  fi
  [[ $pct -gt 100 ]] && pct=100

  local bar_width=20
  local filled=$(( pct * bar_width / 100 ))
  local empty=$(( bar_width - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++)); do bar+="░"; done

  local speed_str="--"
  local speed_bps=0
  if [[ $elapsed -gt 0 && $bytes_done -gt 0 ]]; then
    speed_bps=$(( bytes_done / elapsed ))
    speed_str="$(format_bytes $speed_bps)/s"
  fi

  local eta_str="--"
  if [[ $speed_bps -gt 0 && $bytes_total -gt 0 ]]; then
    local remaining_bytes=$(( bytes_total - bytes_done ))
    if [[ $remaining_bytes -gt 0 ]]; then
      local eta_secs=$(( remaining_bytes / speed_bps ))
      eta_str=$(format_duration $eta_secs)
    else
      eta_str="done"
    fi
  fi

  printf "\r  [%d/%d] %s %3d%% │ %s / %s │ %s │ ETA %s    " \
    "$current" "$total" "$bar" "$pct" \
    "$(format_bytes $bytes_done)" "$(format_bytes $bytes_total)" \
    "$speed_str" "$eta_str"
}

# =============================================================================
# Upload with progress (shared with retrieve_recordings.sh pattern)
# =============================================================================

upload_to_server() {
  local src="$1"
  local dst="$2"
  local label="${3:-panasonic}"

  if [[ ! -d "$src" ]]; then
    log_err "Local directory not found: ${src}"
    return 1
  fi

  # Build list of local files
  declare -a upload_files
  local upload_count=0
  local upload_total_bytes=0
  for f in "${src}"/*.mp4 "${src}"/*.MTS "${src}"/*.mts; do
    [[ -f "$f" ]] || continue
    upload_files+=("$f")
    local fsize
    fsize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
    upload_total_bytes=$((upload_total_bytes + fsize))
    upload_count=$((upload_count + 1))
  done

  if [[ $upload_count -eq 0 ]]; then
    log_msg "${label}: No recordings to upload"
    return 0
  fi

  # Ensure remote directory exists
  if ! ssh "$REMOTE_HOST" "mkdir -p '${dst}'" 2>/dev/null; then
    log_err "${label}: Cannot create remote directory (is ${REMOTE_HOST} reachable?)"
    return 1
  fi

  # Get list of files already on the remote
  local remote_files
  remote_files=$(ssh "$REMOTE_HOST" "ls -1 '${dst}/' 2>/dev/null" 2>/dev/null || echo "")

  declare -a to_upload
  local to_upload_count=0
  local to_upload_bytes=0
  local skipped=0
  local skipped_bytes=0

  for f in "${upload_files[@]}"; do
    local fname
    fname=$(basename "$f")
    if echo "$remote_files" | grep -qF "$fname"; then
      skipped=$((skipped + 1))
      local fsize
      fsize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
      skipped_bytes=$((skipped_bytes + fsize))
    else
      to_upload+=("$f")
      local fsize
      fsize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)
      to_upload_bytes=$((to_upload_bytes + fsize))
      to_upload_count=$((to_upload_count + 1))
    fi
  done

  log_msg "${label}: ${upload_count} file(s) local ($(format_bytes $upload_total_bytes))"
  if [[ $skipped -gt 0 ]]; then
    log_msg "${label}: ${skipped} already on server ($(format_bytes $skipped_bytes)), skipping"
  fi

  if [[ $to_upload_count -eq 0 ]]; then
    log_msg "${label}: All files already on server. Nothing to upload."
    return 0
  fi

  log_msg "${label}: Uploading ${to_upload_count} file(s) ($(format_bytes $to_upload_bytes))"
  echo ""

  local uploaded=0
  local failed=0
  local bytes_done=0
  local upload_start
  upload_start=$(date +%s)

  for f in "${to_upload[@]}"; do
    local fname fsize
    fname=$(basename "$f")
    fsize=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null)

    uploaded=$((uploaded + 1))
    local now_epoch elapsed
    now_epoch=$(date +%s)
    elapsed=$((now_epoch - upload_start))

    show_progress $uploaded $to_upload_count $bytes_done $to_upload_bytes $elapsed
    echo ""
    log_msg "  ↑ ${fname} ($(format_bytes $fsize))"

    if rsync -avh --progress "$f" "${REMOTE_HOST}:${dst}/" 2>&1 | tail -2; then
      bytes_done=$((bytes_done + fsize))
      local now2 elapsed2 speed_str
      now2=$(date +%s)
      elapsed2=$((now2 - upload_start))
      speed_str="--"
      [[ $elapsed2 -gt 0 ]] && speed_str="$(format_bytes $((bytes_done / elapsed2)))/s"
      log_msg "  ✓ OK — avg ${speed_str}"
    else
      log_err "  ✗ FAILED: ${fname}"
      failed=$((failed + 1))
    fi
  done

  local total_elapsed=$(( $(date +%s) - upload_start ))
  show_progress $to_upload_count $to_upload_count $bytes_done $to_upload_bytes $total_elapsed
  echo ""

  local avg_speed_str="--"
  if [[ $total_elapsed -gt 0 && $bytes_done -gt 0 ]]; then
    avg_speed_str="$(format_bytes $((bytes_done / total_elapsed)))/s"
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Upload Summary — ${label}"
  echo "════════════════════════════════════════════════════════════════"
  echo "  Uploaded:    $((uploaded - failed)) / ${to_upload_count} file(s)"
  echo "  Skipped:     ${skipped} (already on server)"
  echo "  Failed:      ${failed}"
  echo "  Size:        $(format_bytes $bytes_done)"
  echo "  Elapsed:     $(format_duration $total_elapsed)"
  echo "  Avg speed:   ${avg_speed_str}"
  echo "  Remote:      ${REMOTE_HOST}:${dst}"
  echo "════════════════════════════════════════════════════════════════"
  echo ""

  [[ $failed -eq 0 ]] && return 0 || return 1
}

# =============================================================================
# Upload-only mode
# =============================================================================

if [[ "${1:-}" == "upload" ]]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║        Upload Panasonic Recordings to 4t                    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Local:   ${OUTPUT_DIR}"
  echo "  Remote:  ${REMOTE_HOST}:${REMOTE_DIR}"
  echo ""

  upload_to_server "$OUTPUT_DIR" "$REMOTE_DIR" "panasonic"
  log_msg "Done."
  exit 0
fi

# =============================================================================
# Require ffmpeg for MTS → MP4 conversion
# =============================================================================

if ! command -v ffmpeg &>/dev/null; then
  log_err "ffmpeg is required for MTS → MP4 conversion but was not found."
  log_err "Install with: brew install ffmpeg"
  exit 1
fi

# =============================================================================
# Usage
# =============================================================================

usage() {
  echo "Usage: $0 <avchd_path> [start_time] [end_time]"
  echo "       $0 upload                    Upload local files to 4t (no import)"
  echo ""
  echo "Arguments:"
  echo "  avchd_path   Path to AVCHD directory (e.g., /Volumes/SD_CARD/PRIVATE/AVCHD)"
  echo "  start_time   Optional filter: \"YYYY-MM-DD HH:MM\" (import clips from this time)"
  echo "  end_time     Optional filter: \"YYYY-MM-DD HH:MM\" (import clips until this time)"
  echo ""
  echo "Files are renamed with the original recording timestamp and saved to:"
  echo "  Local:   ${OUTPUT_DIR}/"
  echo "  Remote:  ${REMOTE_HOST}:${REMOTE_DIR}/"
  echo ""
  echo "Examples:"
  echo "  $0 /Volumes/SD_CARD/PRIVATE/AVCHD"
  echo "  $0 /Users/paul2/PRIVATE/AVCHD"
  echo "  $0 /Volumes/SD_CARD/PRIVATE/AVCHD \"2025-03-15 08:00\" \"2025-03-15 12:00\""
  echo "  SKIP_UPLOAD=1 $0 /Users/paul2/PRIVATE/AVCHD"
  echo ""
  echo "Environment:"
  echo "  SKIP_UPLOAD=1   Skip upload to 4t server"
  exit 1
}

if [[ $# -lt 1 ]]; then
  usage
fi

AVCHD_PATH="$1"
FILTER_START="${2:-}"
FILTER_END="${3:-}"

# =============================================================================
# Validate AVCHD directory
# =============================================================================

if [[ ! -d "$AVCHD_PATH" ]]; then
  log_err "AVCHD path not found: $AVCHD_PATH"
  exit 1
fi

STREAM_DIR="${AVCHD_PATH}/BDMV/STREAM"
PLAYLIST_DIR="${AVCHD_PATH}/BDMV/PLAYLIST"

if [[ ! -d "$STREAM_DIR" ]]; then
  log_err "STREAM directory not found: $STREAM_DIR"
  log_err "Expected AVCHD structure: <path>/BDMV/STREAM/*.MTS"
  exit 1
fi

# Find the MPL playlist file
MPL_FILE=""
for f in "${PLAYLIST_DIR}"/*.MPL "${PLAYLIST_DIR}"/*.mpl; do
  if [[ -f "$f" ]]; then
    MPL_FILE="$f"
    break
  fi
done

if [[ -z "$MPL_FILE" ]]; then
  log_err "No MPL playlist found in: $PLAYLIST_DIR"
  exit 1
fi

# =============================================================================
# Parse timestamps from the MPL playlist
# =============================================================================

log_msg "Parsing AVCHD playlist: $(basename "$MPL_FILE")"

# Inline Python to parse AVCHD timestamps — returns CSV: filename,timestamp
CLIP_DATA=$(python3 -c "
import struct, sys

def bcd(b):
    return (b >> 4) * 10 + (b & 0x0f)

def is_bcd(b):
    return (b >> 4) <= 9 and (b & 0x0f) <= 9

data = open('${MPL_FILE}', 'rb').read()

# Parse playlist section offsets
playlist_start = struct.unpack('>I', data[8:12])[0]
playlist_mark   = struct.unpack('>I', data[12:16])[0]
ext_data_start  = struct.unpack('>I', data[16:20])[0]

if ext_data_start == 0:
    print('ERROR: No extension data — timestamps not available', file=sys.stderr)
    sys.exit(1)

# Extract clip names from playlist section
clips = []
for i in range(playlist_start, playlist_mark - 9):
    if data[i+5:i+9] == b'M2TS':
        candidate = data[i:i+5]
        if all(0x30 <= b <= 0x39 for b in candidate):
            name = data[i:i+9].decode('ascii')
            if not clips or i - clips[-1][0] > 20:
                clips.append((i, name))

# Extract BCD timestamps from PLEX extension
ed_len = struct.unpack('>I', data[ext_data_start:ext_data_start+4])[0]
search_end = min(ext_data_start + ed_len + 4, len(data))
timestamps = []
i = ext_data_start
while i < search_end - 8:
    if data[i] == 0x2A:
        raw = data[i+1:i+8]
        if len(raw) == 7 and all(is_bcd(b) for b in raw):
            year = bcd(raw[0]) * 100 + bcd(raw[1])
            mon, day = bcd(raw[2]), bcd(raw[3])
            hr, mn, sec = bcd(raw[4]), bcd(raw[5]), bcd(raw[6])
            if (2000 <= year <= 2099 and 1 <= mon <= 12 and
                1 <= day <= 31 and 0 <= hr <= 23 and
                0 <= mn <= 59 and 0 <= sec <= 59):
                timestamps.append('%04d-%02d-%02d %02d:%02d:%02d' % (year, mon, day, hr, mn, sec))
                i += 8
                continue
    i += 1

# Match clips to timestamps (first timestamp is playlist-level if N+1)
offset = 1 if len(timestamps) == len(clips) + 1 else 0

for idx in range(len(clips)):
    clip_name = clips[idx][1]
    mts_name = clip_name[:5] + '.MTS'
    ts_idx = idx + offset
    if ts_idx < len(timestamps):
        ts = timestamps[ts_idx]
    else:
        ts = 'UNKNOWN'
    print('%s,%s' % (mts_name, ts))
" 2>&1)

if [[ $? -ne 0 ]] || [[ -z "$CLIP_DATA" ]]; then
  log_err "Failed to parse AVCHD timestamps from: $MPL_FILE"
  echo "$CLIP_DATA" >&2
  exit 1
fi

# Count total clips
TOTAL_CLIPS=$(echo "$CLIP_DATA" | wc -l | tr -d ' ')
log_msg "Found ${TOTAL_CLIPS} clip(s) in playlist"

# =============================================================================
# Apply time filter if specified
# =============================================================================

parse_epoch() {
  local ts="$1"
  # Append :00 if no seconds
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] && ts="${ts}:00"
  date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s" 2>/dev/null || \
  date -d "$ts" "+%s" 2>/dev/null || \
  { log_err "Cannot parse date: $ts"; exit 1; }
}

if [[ -n "$FILTER_START" && -n "$FILTER_END" ]]; then
  FILTER_START_EPOCH=$(parse_epoch "$FILTER_START")
  FILTER_END_EPOCH=$(parse_epoch "$FILTER_END")

  FILTERED_DATA=""
  while IFS=',' read -r mts_name ts; do
    ts_epoch=$(parse_epoch "$ts")
    if [[ $ts_epoch -ge $FILTER_START_EPOCH && $ts_epoch -le $FILTER_END_EPOCH ]]; then
      FILTERED_DATA+="${mts_name},${ts}"$'\n'
    fi
  done <<< "$CLIP_DATA"

  # Remove trailing newline
  FILTERED_DATA=$(echo -n "$FILTERED_DATA" | sed '/^$/d')

  FILTERED_COUNT=$(echo "$FILTERED_DATA" | grep -c '.' || echo "0")
  log_msg "Filter: ${FILTER_START} → ${FILTER_END}"
  log_msg "Matched ${FILTERED_COUNT} of ${TOTAL_CLIPS} clips"

  if [[ $FILTERED_COUNT -eq 0 ]]; then
    log_msg "No clips match the time filter."
    exit 0
  fi

  CLIP_DATA="$FILTERED_DATA"
  TOTAL_CLIPS=$FILTERED_COUNT
fi

# =============================================================================
# Show plan
# =============================================================================

# Calculate total source size
TOTAL_SRC_BYTES=0
while IFS=',' read -r mts_name ts; do
  src_file="${STREAM_DIR}/${mts_name}"
  if [[ -f "$src_file" ]]; then
    fsize=$(stat -f%z "$src_file" 2>/dev/null || stat -c%s "$src_file" 2>/dev/null)
    TOTAL_SRC_BYTES=$((TOTAL_SRC_BYTES + fsize))
  fi
done <<< "$CLIP_DATA"

# Get date range
FIRST_TS=$(echo "$CLIP_DATA" | head -1 | cut -d',' -f2)
LAST_TS=$(echo "$CLIP_DATA" | tail -1 | cut -d',' -f2)

mkdir -p "$OUTPUT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Import Panasonic Camcorder Recordings                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Source:     ${AVCHD_PATH}"
echo "  Clips:      ${TOTAL_CLIPS} ($(format_bytes $TOTAL_SRC_BYTES))"
echo "  Period:     ${FIRST_TS} → ${LAST_TS}"
echo "  Local:      ${OUTPUT_DIR}"
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  echo "  Remote:     ${REMOTE_HOST}:${REMOTE_DIR}"
fi
echo ""

# =============================================================================
# Copy files with timestamp renaming and progress
# =============================================================================

log_msg "Importing clips..."
echo ""

# Count how many need copying (skip existing)
TO_COPY=0
COPY_BYTES=0
while IFS=',' read -r mts_name ts; do
  ts_flat=$(echo "$ts" | sed 's/[- :]//g')
  out_file="${OUTPUT_DIR}/panasonic_${ts_flat}.mp4"
  if [[ ! -f "$out_file" ]]; then
    src_file="${STREAM_DIR}/${mts_name}"
    if [[ -f "$src_file" ]]; then
      fsize=$(stat -f%z "$src_file" 2>/dev/null || stat -c%s "$src_file" 2>/dev/null)
      TO_COPY=$((TO_COPY + 1))
      COPY_BYTES=$((COPY_BYTES + fsize))
    fi
  fi
done <<< "$CLIP_DATA"

SKIPPED=$((TOTAL_CLIPS - TO_COPY))

if [[ $TO_COPY -eq 0 ]]; then
  log_msg "All ${TOTAL_CLIPS} clips already imported. Nothing to copy."
else
  if [[ $SKIPPED -gt 0 ]]; then
    log_msg "Copying ${TO_COPY} clip(s) ($(format_bytes $COPY_BYTES)), skipping ${SKIPPED} existing"
  else
    log_msg "Copying ${TO_COPY} clip(s) ($(format_bytes $COPY_BYTES))"
  fi
  echo ""

  COPIED=0
  FAILED=0
  BYTES_DONE=0
  COPY_START=$(date +%s)
  DL_INDEX=0

  while IFS=',' read -r mts_name ts; do
    src_file="${STREAM_DIR}/${mts_name}"
    ts_flat=$(echo "$ts" | sed 's/[- :]//g')
    out_file="${OUTPUT_DIR}/panasonic_${ts_flat}.mp4"

    # Skip if source doesn't exist
    if [[ ! -f "$src_file" ]]; then
      log_err "  Source not found: ${mts_name}"
      FAILED=$((FAILED + 1))
      continue
    fi

    # Skip if already exists
    if [[ -f "$out_file" ]]; then
      continue
    fi

    DL_INDEX=$((DL_INDEX + 1))
    local_size=$(stat -f%z "$src_file" 2>/dev/null || stat -c%s "$src_file" 2>/dev/null)
    local_mb=$(( local_size / 1048576 ))

    NOW_EPOCH=$(date +%s)
    ELAPSED=$((NOW_EPOCH - COPY_START))

    show_progress $DL_INDEX $TO_COPY $BYTES_DONE $COPY_BYTES $ELAPSED
    echo ""
    log_msg "  ← ${mts_name} → panasonic_${ts_flat}.mp4 (${local_mb} MB) [${ts}]"

    # Convert MTS → MP4 (stream copy, no re-encode)
    if ffmpeg -nostdin -y -i "$src_file" -c copy -movflags +faststart "$out_file" 2>/dev/null; then
      # Set file modification time to the original recording timestamp
      # macOS touch format: [[CC]YY]MMDDhhmm[.SS]
      touch_ts=$(echo "$ts" | python3 -c "
import sys
ts = sys.stdin.read().strip()
# Input:  2025-03-15 08:11:39
# Output: 202503150811.39
print(ts.replace('-','').replace(' ','').replace(':','')[:-2] + '.' + ts[-2:])
")
      touch -t "$touch_ts" "$out_file"

      actual_size=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file" 2>/dev/null)
      BYTES_DONE=$((BYTES_DONE + actual_size))
      COPIED=$((COPIED + 1))

      NOW2=$(date +%s)
      ELAPSED2=$((NOW2 - COPY_START))
      SPEED_STR="--"
      [[ $ELAPSED2 -gt 0 ]] && SPEED_STR="$(format_bytes $((BYTES_DONE / ELAPSED2)))/s"
      log_msg "  ✓ OK ($(format_bytes $actual_size)) — avg ${SPEED_STR}"
    else
      log_err "  ✗ FAILED: ${mts_name}"
      rm -f "$out_file"
      FAILED=$((FAILED + 1))
    fi
  done <<< "$CLIP_DATA"

  # Final progress bar
  FINAL_ELAPSED=$(( $(date +%s) - COPY_START ))
  show_progress $TO_COPY $TO_COPY $BYTES_DONE $COPY_BYTES $FINAL_ELAPSED
  echo ""
fi

# Summary
TOTAL_ELAPSED=$(( $(date +%s) - ${COPY_START:-$(date +%s)} ))
AVG_SPEED="--"
if [[ ${TOTAL_ELAPSED:-0} -gt 0 && ${BYTES_DONE:-0} -gt 0 ]]; then
  AVG_SPEED="$(format_bytes $((BYTES_DONE / TOTAL_ELAPSED)))/s"
fi

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Import Summary — Panasonic"
echo "════════════════════════════════════════════════════════════════"
echo "  Source:      ${AVCHD_PATH}"
echo "  Clips:       ${TOTAL_CLIPS} found"
echo "  Copied:      ${COPIED:-0} ($(format_bytes ${BYTES_DONE:-0}))"
echo "  Skipped:     ${SKIPPED} (already exist)"
echo "  Failed:      ${FAILED:-0}"
if [[ ${TOTAL_ELAPSED:-0} -gt 0 ]]; then
  echo "  Elapsed:     $(format_duration $TOTAL_ELAPSED)"
  echo "  Avg speed:   ${AVG_SPEED}"
fi
echo "  Local:       ${OUTPUT_DIR}"
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  echo "  Remote:      ${REMOTE_HOST}:${REMOTE_DIR} (uploading next...)"
fi
echo "════════════════════════════════════════════════════════════════"
echo ""

# =============================================================================
# Upload to 4t
# =============================================================================

if [[ "$SKIP_UPLOAD" != "1" ]]; then
  upload_to_server "$OUTPUT_DIR" "$REMOTE_DIR" "panasonic"
fi

log_msg "Done."
