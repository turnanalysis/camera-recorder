#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Retrieve Recordings from Camera SD Cards
#
# Downloads recordings from camera SD cards for a specific time period.
# Supports Reolink (R1, R2, R3) via HTTP API and Axis via VAPIX API.
#
# Files are saved locally and automatically uploaded to the 4t server:
#   Local:   /Users/paul2/j40/data/sd_data/<camera>/
#   Remote:  4t:/home/pa91/data/recordings/<camera>/
#
# Usage:
#   ./retrieve_recordings.sh <camera> <start> <end> [output_dir]
#   ./retrieve_recordings.sh upload <camera>       # Upload only (no download)
#   ./retrieve_recordings.sh upload                # Upload all cameras
#
# Examples:
#   ./retrieve_recordings.sh R1 "2026-02-15 08:00" "2026-02-15 12:00"
#   ./retrieve_recordings.sh R2 "2026-02-14 09:30" "2026-02-14 10:45"
#   ./retrieve_recordings.sh axis "2026-02-15 08:00" "2026-02-15 09:00"
#   ./retrieve_recordings.sh upload R2             # Upload R2 local files to 4t
#   ./retrieve_recordings.sh upload                # Upload all cameras to 4t
#   SKIP_UPLOAD=1 ./retrieve_recordings.sh R3 "2026-02-15 08:00" "2026-02-15 12:00"
#
# The camera name is case-insensitive: R1, r1, Axis, AXIS all work.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Download timeout per segment (seconds)
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-300}"

# Local base directory for SD card data
LOCAL_BASE="/Users/paul2/j40/data/sd_data"

# Remote server for upload (ssh alias "4t")
REMOTE_HOST="4t"
REMOTE_BASE="/home/pa91/data/recordings"

# Skip upload if set to 1
SKIP_UPLOAD="${SKIP_UPLOAD:-0}"

# =============================================================================
# Logging (defined early so upload-only mode can use them)
# =============================================================================

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# =============================================================================
# Progress helpers (defined early so upload-only mode can use them)
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

# Print a progress line: [N/total] ██████░░░░ 45% | 1.2 GB / 2.7 GB | 35 MB/s | ETA 1m 23s
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
# Shared upload function with per-file progress
# Upload all .mp4/.mkv from a local dir to a remote dir via scp, with progress.
# Usage: upload_dir_to_server <local_dir> <remote_dir> [label]
# =============================================================================

upload_dir_to_server() {
  local src="$1"
  local dst="$2"
  local label="${3:-upload}"

  if [[ ! -d "$src" ]]; then
    log_err "Local directory not found: ${src}"
    return 1
  fi

  # Build list of local files
  declare -a upload_files
  local upload_count=0
  local upload_total_bytes=0
  for f in "${src}"/*.mp4 "${src}"/*.mkv; do
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

  # Get list of files already on the remote to skip them
  local remote_files
  remote_files=$(ssh "$REMOTE_HOST" "ls -1 '${dst}/' 2>/dev/null" 2>/dev/null || echo "")

  # Figure out what needs uploading
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

  # Final progress
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
# Upload-only mode: ./retrieve_recordings.sh upload [camera]
# Syncs local files to 4t without downloading from cameras.
# =============================================================================

if [[ "${1:-}" == "upload" ]]; then
  UPLOAD_TARGET="${2:-}"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║            Upload Local Recordings to 4t                    ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Local base:  ${LOCAL_BASE}"
  echo "  Remote base: ${REMOTE_HOST}:${REMOTE_BASE}"
  echo ""

  if [[ -n "$UPLOAD_TARGET" ]]; then
    upload_dir_to_server "${LOCAL_BASE}/${UPLOAD_TARGET}" "${REMOTE_BASE}/${UPLOAD_TARGET}" "$UPLOAD_TARGET"
  else
    found=0
    for cam_dir in "${LOCAL_BASE}"/*/; do
      [[ -d "$cam_dir" ]] || continue
      cam=$(basename "$cam_dir")
      upload_dir_to_server "${LOCAL_BASE}/${cam}" "${REMOTE_BASE}/${cam}" "$cam"
      found=$((found + 1))
    done
    if [[ $found -eq 0 ]]; then
      log_err "No camera directories found in ${LOCAL_BASE}"
      exit 1
    fi
  fi

  log_msg "Done."
  exit 0
fi

# =============================================================================
# Load credentials
# =============================================================================

CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"
if [[ -f "$CREDENTIALS_FILE" ]]; then
  source "$CREDENTIALS_FILE"
else
  log_err "Missing credentials file: $CREDENTIALS_FILE"
  echo "Create it from the template: cp credentials.template credentials.local"
  exit 1
fi

# =============================================================================
# Camera lookup from cameras.conf
# =============================================================================

declare -A CAMERA_MAP   # name -> ip/url
declare -A CAMERA_METHOD # name -> sdcard|ffmpeg

parse_cameras() {
  local conf="${SCRIPT_DIR}/cameras.conf"
  if [[ ! -f "$conf" ]]; then
    log_err "Config file not found: $conf"
    exit 1
  fi

  while IFS='|' read -r name url fps bitrate method; do
    [[ -z "${name// }" ]] && continue
    [[ "$name" =~ ^# ]] && continue
    [[ -z "${url// }" ]] && continue

    local lname
    lname=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    method="${method:-ffmpeg}"

    CAMERA_MAP["$lname"]="$url"
    CAMERA_METHOD["$lname"]="$method"
  done < "$conf"
}

# =============================================================================
# Argument parsing
# =============================================================================

usage() {
  echo "Usage: $0 <camera> <start_time> <end_time> [output_dir]"
  echo "       $0 upload [camera]    Upload local files to 4t (no download)"
  echo ""
  echo "Arguments:"
  echo "  camera      Camera name: R1, R2, R3, or Axis (case-insensitive)"
  echo "  start_time  Start time: \"YYYY-MM-DD HH:MM\" or \"YYYY-MM-DD HH:MM:SS\""
  echo "  end_time    End time:   \"YYYY-MM-DD HH:MM\" or \"YYYY-MM-DD HH:MM:SS\""
  echo "  output_dir  Output directory (default: ${LOCAL_BASE}/<camera>)"
  echo ""
  echo "Files are saved locally and uploaded to the 4t server automatically."
  echo "  Local:   ${LOCAL_BASE}/<camera>/"
  echo "  Remote:  ${REMOTE_HOST}:${REMOTE_BASE}/<camera>/"
  echo ""
  echo "Commands:"
  echo "  $0 upload              Upload ALL cameras to 4t"
  echo "  $0 upload R2           Upload only R2 to 4t"
  echo ""
  echo "Examples:"
  echo "  $0 R1 \"2026-02-15 08:00\" \"2026-02-15 12:00\""
  echo "  $0 axis \"2026-02-15 09:00\" \"2026-02-15 10:30\""
  echo "  $0 R3 \"2026-02-15 08:00\" \"2026-02-15 12:00\" ~/Desktop/race"
  echo ""
  echo "Environment:"
  echo "  DOWNLOAD_TIMEOUT=300  Timeout per file download in seconds (default: 300)"
  echo "  SKIP_UPLOAD=1         Skip upload to 4t server"
  exit 1
}

if [[ $# -lt 3 ]]; then
  usage
fi

CAMERA_INPUT="$1"
START_TIME="$2"
END_TIME="$3"
OUTPUT_DIR="${4:-}"

# Normalize camera name to lowercase
CAMERA=$(echo "$CAMERA_INPUT" | tr '[:upper:]' '[:lower:]')

# Parse cameras.conf
parse_cameras

# Validate camera
if [[ -z "${CAMERA_MAP[$CAMERA]:-}" ]]; then
  log_err "Unknown camera: $CAMERA_INPUT"
  echo "Available cameras: ${!CAMERA_MAP[*]}"
  exit 1
fi

CAMERA_URL="${CAMERA_MAP[$CAMERA]}"
METHOD="${CAMERA_METHOD[$CAMERA]}"

# =============================================================================
# Validate and parse times
# =============================================================================

# Append :00 seconds if not provided
[[ "$START_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] && START_TIME="${START_TIME}:00"
[[ "$END_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}$ ]] && END_TIME="${END_TIME}:00"

# Validate format
if ! [[ "$START_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  log_err "Invalid start time format: $START_TIME"
  echo "Expected: YYYY-MM-DD HH:MM or YYYY-MM-DD HH:MM:SS"
  exit 1
fi

if ! [[ "$END_TIME" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
  log_err "Invalid end time format: $END_TIME"
  echo "Expected: YYYY-MM-DD HH:MM or YYYY-MM-DD HH:MM:SS"
  exit 1
fi

# Parse into epoch for comparison (macOS compatible)
parse_epoch() {
  local ts="$1"
  date -j -f "%Y-%m-%d %H:%M:%S" "$ts" "+%s" 2>/dev/null || \
  date -d "$ts" "+%s" 2>/dev/null || \
  { log_err "Cannot parse date: $ts"; exit 1; }
}

START_EPOCH=$(parse_epoch "$START_TIME")
END_EPOCH=$(parse_epoch "$END_TIME")

if [[ $START_EPOCH -ge $END_EPOCH ]]; then
  log_err "Start time must be before end time"
  exit 1
fi

# Duration info
DURATION_SECS=$((END_EPOCH - START_EPOCH))
DURATION_MIN=$((DURATION_SECS / 60))
DURATION_HRS=$((DURATION_MIN / 60))
REMAINING_MIN=$((DURATION_MIN % 60))

if [[ $DURATION_HRS -gt 0 ]]; then
  DURATION_STR="${DURATION_HRS}h ${REMAINING_MIN}m"
else
  DURATION_STR="${DURATION_MIN}m"
fi

# Default output directory: /Users/paul2/j40/data/sd_data/<camera>/
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${LOCAL_BASE}/${CAMERA_INPUT}"
fi

# Remote directory: /home/pa91/data/recordings/<camera>/
REMOTE_DIR="${REMOTE_BASE}/${CAMERA_INPUT}"

mkdir -p "$OUTPUT_DIR"

# =============================================================================
# Display plan
# =============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            Retrieve Camera Recordings                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Camera:     ${CAMERA_INPUT} (${METHOD})"
echo "  Address:    ${CAMERA_URL}"
echo "  Period:     ${START_TIME} → ${END_TIME} (${DURATION_STR})"
echo "  Local:      ${OUTPUT_DIR}"
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  echo "  Remote:     ${REMOTE_HOST}:${REMOTE_DIR}"
fi
echo ""

# =============================================================================
# Reolink SD card retrieval
# =============================================================================

reolink_login() {
  local ip="$1"
  local token
  token=$(curl -s -m 10 -X POST "https://${ip}/api.cgi?cmd=Login" -k \
    -d "[{\"cmd\":\"Login\",\"param\":{\"User\":{\"Version\":\"0\",\"userName\":\"${REOLINK_USER}\",\"password\":\"${REOLINK_PASS}\"}}}]" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['value']['Token']['name'])" 2>/dev/null)

  if [[ -z "$token" ]]; then
    log_err "Failed to login to Reolink at ${ip}"
    return 1
  fi
  echo "$token"
}

reolink_search() {
  local ip="$1" token="$2" start_time="$3" end_time="$4"
  read -r sy smo sd sh smi ss <<< "$start_time"
  read -r ey emo ed eh emi es <<< "$end_time"

  curl -s -m 30 -X POST "https://${ip}/api.cgi?cmd=Search&token=${token}" -k \
    -d "[{\"cmd\":\"Search\",\"action\":0,\"param\":{\"Search\":{\"channel\":0,\"onlyStatus\":0,\"streamType\":\"main\",\"StartTime\":{\"year\":${sy},\"mon\":${smo},\"day\":${sd},\"hour\":${sh},\"min\":${smi},\"sec\":${ss}},\"EndTime\":{\"year\":${ey},\"mon\":${emo},\"day\":${ed},\"hour\":${eh},\"min\":${emi},\"sec\":${es}}}}}]" \
    2>/dev/null
}

reolink_download_file() {
  local ip="$1" token="$2" remote_file="$3" output_path="$4"

  curl -sk -m "$DOWNLOAD_TIMEOUT" --progress-bar \
    -o "$output_path" \
    "https://${ip}/cgi-bin/api.cgi?cmd=Playback&source=${remote_file}&output=${remote_file}&token=${token}"

  if [[ -f "$output_path" ]] && [[ $(stat -f%z "$output_path" 2>/dev/null || stat -c%s "$output_path" 2>/dev/null) -gt 1000 ]]; then
    return 0
  else
    rm -f "$output_path"
    return 1
  fi
}

retrieve_reolink() {
  local ip="$1"

  log_msg "Logging into Reolink camera at ${ip}..."
  local token
  token=$(reolink_login "$ip") || { log_err "Login failed"; exit 1; }
  log_msg "Login successful"

  # ── Phase 1: Search all days and collect segment list ──────────────────
  log_msg "Searching for recordings..."

  local current_epoch=$START_EPOCH

  # Collect all segments into arrays
  declare -a seg_remote seg_size seg_start seg_end
  local seg_count=0
  local seg_total_bytes=0

  while [[ $current_epoch -lt $END_EPOCH ]]; do
    local day_start_epoch=$current_epoch
    local day_end_str
    day_end_str=$(date -r "$day_start_epoch" "+%Y-%m-%d" 2>/dev/null || date -d "@$day_start_epoch" "+%Y-%m-%d" 2>/dev/null)
    local day_end_epoch
    day_end_epoch=$(parse_epoch "${day_end_str} 23:59:59")

    [[ $day_start_epoch -lt $START_EPOCH ]] && day_start_epoch=$START_EPOCH
    [[ $day_end_epoch -gt $END_EPOCH ]] && day_end_epoch=$END_EPOCH

    local ds de
    ds=$(date -r "$day_start_epoch" "+%Y %m %d %H %M %S" 2>/dev/null || date -d "@$day_start_epoch" "+%Y %m %d %H %M %S" 2>/dev/null)
    de=$(date -r "$day_end_epoch" "+%Y %m %d %H %M %S" 2>/dev/null || date -d "@$day_end_epoch" "+%Y %m %d %H %M %S" 2>/dev/null)

    log_msg "  Searching: ${day_end_str} ..."

    local search_result
    search_result=$(reolink_search "$ip" "$token" "$ds" "$de")

    if [[ -n "$search_result" ]]; then
      local files_json
      files_json=$(echo "$search_result" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    files = data[0].get('value', {}).get('SearchResult', {}).get('File', [])
    for f in files:
        name = f['name']
        size = f.get('size', '0')
        st = f['StartTime']
        et = f['EndTime']
        start_str = f\"{st['year']:04d}{st['mon']:02d}{st['day']:02d}_{st['hour']:02d}{st['min']:02d}{st['sec']:02d}\"
        end_str = f\"{et['year']:04d}{et['mon']:02d}{et['day']:02d}_{et['hour']:02d}{et['min']:02d}{et['sec']:02d}\"
        print(f'{name}|{size}|{start_str}|{end_str}')
except:
    pass
" 2>/dev/null)

      if [[ -n "$files_json" ]]; then
        while IFS='|' read -r remote_file size start_str end_str; do
          [[ -z "$remote_file" ]] && continue
          seg_remote+=("$remote_file")
          seg_size+=("$size")
          seg_start+=("$start_str")
          seg_end+=("$end_str")
          seg_total_bytes=$((seg_total_bytes + size))
          seg_count=$((seg_count + 1))
        done <<< "$files_json"
      fi
    fi

    current_epoch=$((day_end_epoch + 1))
  done

  if [[ $seg_count -eq 0 ]]; then
    log_msg "No recordings found for the requested period."
    return 0
  fi

  log_msg "Found ${seg_count} segment(s), ~$(format_bytes $seg_total_bytes) total"
  echo ""

  # ── Phase 2: Download with progress ───────────────────────────────────
  local total_downloaded=0
  local total_skipped=0
  local total_failed=0
  local bytes_done=0
  local download_start_epoch
  download_start_epoch=$(date +%s)

  # Figure out how many need downloading (for accurate progress)
  local to_download=0
  local download_bytes=0
  for ((i=0; i<seg_count; i++)); do
    local out_file="${OUTPUT_DIR}/${CAMERA_INPUT}_${seg_start[$i]}.mp4"
    if [[ ! -f "$out_file" ]]; then
      to_download=$((to_download + 1))
      download_bytes=$((download_bytes + seg_size[$i]))
    fi
  done

  if [[ $to_download -eq 0 ]]; then
    log_msg "All ${seg_count} segments already exist locally. Nothing to download."
    total_skipped=$seg_count
  else
    log_msg "Downloading ${to_download} segment(s) ($(format_bytes $download_bytes)), skipping $((seg_count - to_download)) existing"
    echo ""

    local dl_index=0
    for ((i=0; i<seg_count; i++)); do
      local remote_file="${seg_remote[$i]}"
      local size="${seg_size[$i]}"
      local start_str="${seg_start[$i]}"
      local out_file="${OUTPUT_DIR}/${CAMERA_INPUT}_${start_str}.mp4"

      # Skip if already exists locally
      if [[ -f "$out_file" ]]; then
        total_skipped=$((total_skipped + 1))
        continue
      fi

      dl_index=$((dl_index + 1))
      local size_mb=$((size / 1048576))
      local now_epoch
      now_epoch=$(date +%s)
      local elapsed=$((now_epoch - download_start_epoch))

      # Show progress bar
      show_progress $dl_index $to_download $bytes_done $download_bytes $elapsed
      echo ""
      log_msg "  ↓ ${CAMERA_INPUT}_${start_str}.mp4 (${size_mb} MB)"

      if reolink_download_file "$ip" "$token" "$remote_file" "$out_file"; then
        local actual_size
        actual_size=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file" 2>/dev/null)
        bytes_done=$((bytes_done + actual_size))
        total_downloaded=$((total_downloaded + 1))

        # Speed for this file
        local now2
        now2=$(date +%s)
        local elapsed2=$((now2 - download_start_epoch))
        local speed_str="--"
        if [[ $elapsed2 -gt 0 ]]; then
          speed_str="$(format_bytes $((bytes_done / elapsed2)))/s"
        fi
        log_msg "  ✓ OK ($(format_bytes $actual_size)) — avg ${speed_str}"
      else
        log_err "  ✗ FAILED: ${remote_file}"
        total_failed=$((total_failed + 1))
      fi
    done

    # Final progress bar
    local final_elapsed=$(( $(date +%s) - download_start_epoch ))
    show_progress $to_download $to_download $bytes_done $download_bytes $final_elapsed
    echo ""
  fi

  # Elapsed time
  local total_elapsed=$(( $(date +%s) - download_start_epoch ))
  local avg_speed_str="--"
  if [[ $total_elapsed -gt 0 && $bytes_done -gt 0 ]]; then
    avg_speed_str="$(format_bytes $((bytes_done / total_elapsed)))/s"
  fi

  # Summary
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Download Summary for ${CAMERA_INPUT}"
  echo "════════════════════════════════════════════════════════════════"
  echo "  Period:      ${START_TIME} → ${END_TIME}"
  echo "  Segments:    ${seg_count} found"
  echo "  Downloaded:  ${total_downloaded} ($(format_bytes $bytes_done))"
  echo "  Skipped:     ${total_skipped} (already exist)"
  echo "  Failed:      ${total_failed}"
  echo "  Elapsed:     $(format_duration $total_elapsed)"
  echo "  Avg speed:   ${avg_speed_str}"
  echo "  Local:       ${OUTPUT_DIR}"
  if [[ "$SKIP_UPLOAD" != "1" ]]; then
    echo "  Remote:      ${REMOTE_HOST}:${REMOTE_DIR} (uploading next...)"
  fi
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# =============================================================================
# Axis VAPIX retrieval
# =============================================================================

retrieve_axis() {
  local axis_url="$1"

  # Extract IP from the RTSP URL
  local ip
  ip=$(echo "$axis_url" | sed -E 's|.*@([0-9.]+)[:/].*|\1|')

  if [[ -z "$ip" ]]; then
    log_err "Could not extract Axis camera IP from URL: $axis_url"
    exit 1
  fi

  log_msg "Querying Axis camera at ${ip} for recordings..."

  # Format times for Axis VAPIX: YYYY-MM-DDTHH:MM:SS
  local vapix_start vapix_end
  vapix_start=$(echo "$START_TIME" | sed 's/ /T/')
  vapix_end=$(echo "$END_TIME" | sed 's/ /T/')

  # Use Axis VAPIX Recording API to list recordings
  local list_url="https://${ip}/axis-cgi/record/list.cgi?recordingid=all&starttime=${vapix_start}&stoptime=${vapix_end}"

  local list_result
  list_result=$(curl -sk -m 30 -u "${AXIS_USER}:${AXIS_PASS}" "$list_url" 2>/dev/null)

  if [[ -z "$list_result" ]]; then
    log_err "No response from Axis camera at ${ip}"
    log_msg "Falling back to RTSP time-range export..."
    retrieve_axis_rtsp "$ip"
    return
  fi

  # Check if the camera returned an error or has no recording API
  if echo "$list_result" | grep -qi "error\|not found\|unauthorized"; then
    log_msg "Axis recording list API not available, using RTSP time-range export..."
    retrieve_axis_rtsp "$ip"
    return
  fi

  # Parse recording IDs from XML response
  local recording_ids
  recording_ids=$(echo "$list_result" | python3 -c "
import sys, re
content = sys.stdin.read()
# Look for recordingid attributes in the response
ids = re.findall(r'recordingid=\"([^\"]+)\"', content, re.IGNORECASE)
if not ids:
    # Try alternative format
    ids = re.findall(r'<recordingid>([^<]+)</recordingid>', content, re.IGNORECASE)
for rid in ids:
    print(rid)
" 2>/dev/null)

  if [[ -z "$recording_ids" ]]; then
    log_msg "No recording IDs found via list API, using RTSP time-range export..."
    retrieve_axis_rtsp "$ip"
    return
  fi

  # Collect recording IDs into an array
  declare -a axis_ids
  local axis_count=0
  while IFS= read -r rec_id; do
    [[ -z "$rec_id" ]] && continue
    axis_ids+=("$rec_id")
    axis_count=$((axis_count + 1))
  done <<< "$recording_ids"

  log_msg "Found ${axis_count} recording(s)"

  # Count how many need downloading
  local to_download=0
  local skipped=0
  for ((i=0; i<axis_count; i++)); do
    local out_file="${OUTPUT_DIR}/${CAMERA_INPUT}_recording_${axis_ids[$i]}.mkv"
    if [[ -f "$out_file" ]]; then
      skipped=$((skipped + 1))
    else
      to_download=$((to_download + 1))
    fi
  done

  if [[ $to_download -eq 0 ]]; then
    log_msg "All ${axis_count} recordings already exist locally."
  else
    log_msg "Downloading ${to_download} recording(s), skipping ${skipped} existing"
    echo ""
  fi

  local downloaded=0 failed=0 bytes_done=0
  local download_start_epoch
  download_start_epoch=$(date +%s)
  local dl_index=0

  for ((i=0; i<axis_count; i++)); do
    local rec_id="${axis_ids[$i]}"
    local out_file="${OUTPUT_DIR}/${CAMERA_INPUT}_recording_${rec_id}.mkv"

    if [[ -f "$out_file" ]]; then
      continue
    fi

    dl_index=$((dl_index + 1))
    local now_epoch elapsed
    now_epoch=$(date +%s)
    elapsed=$((now_epoch - download_start_epoch))

    # Progress (no byte total available for Axis, so use file count)
    show_progress $dl_index $to_download $bytes_done $bytes_done $elapsed
    echo ""
    log_msg "  ↓ Recording ${rec_id} (${dl_index}/${to_download})"

    local export_url="https://${ip}/axis-cgi/record/export/exportrecording.cgi?recordingid=${rec_id}"

    if curl -sk -m "$DOWNLOAD_TIMEOUT" --progress-bar \
         -u "${AXIS_USER}:${AXIS_PASS}" \
         -o "$out_file" \
         "$export_url"; then
      local actual_size
      actual_size=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file" 2>/dev/null)
      if [[ $actual_size -gt 1000 ]]; then
        bytes_done=$((bytes_done + actual_size))
        downloaded=$((downloaded + 1))
        local now2 elapsed2 speed_str
        now2=$(date +%s)
        elapsed2=$((now2 - download_start_epoch))
        speed_str="--"
        [[ $elapsed2 -gt 0 ]] && speed_str="$(format_bytes $((bytes_done / elapsed2)))/s"
        log_msg "  ✓ OK ($(format_bytes $actual_size)) — avg ${speed_str}"
      else
        rm -f "$out_file"
        log_err "  ✗ FAILED (too small): ${rec_id}"
        failed=$((failed + 1))
      fi
    else
      rm -f "$out_file"
      log_err "  ✗ FAILED: ${rec_id}"
      failed=$((failed + 1))
    fi
  done

  local total_elapsed=$(( $(date +%s) - download_start_epoch ))
  local avg_speed_str="--"
  if [[ $total_elapsed -gt 0 && $bytes_done -gt 0 ]]; then
    avg_speed_str="$(format_bytes $((bytes_done / total_elapsed)))/s"
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Download Summary for ${CAMERA_INPUT}"
  echo "════════════════════════════════════════════════════════════════"
  echo "  Period:      ${START_TIME} → ${END_TIME}"
  echo "  Recordings:  ${axis_count} found"
  echo "  Downloaded:  ${downloaded} ($(format_bytes $bytes_done))"
  echo "  Skipped:     ${skipped} (already exist)"
  echo "  Failed:      ${failed}"
  echo "  Elapsed:     $(format_duration $total_elapsed)"
  echo "  Avg speed:   ${avg_speed_str}"
  echo "  Local:       ${OUTPUT_DIR}"
  if [[ "$SKIP_UPLOAD" != "1" ]]; then
    echo "  Remote:      ${REMOTE_HOST}:${REMOTE_DIR} (uploading next...)"
  fi
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# Fallback: use ffmpeg to grab a time range via RTSP playback
retrieve_axis_rtsp() {
  local ip="$1"

  log_msg "Exporting Axis recording via RTSP time-range request..."

  # Axis supports RTSP playback with start/end parameters
  local vapix_start vapix_end
  vapix_start=$(echo "$START_TIME" | sed 's/ /T/; s/$/.000Z/')
  vapix_end=$(echo "$END_TIME" | sed 's/ /T/; s/$/.000Z/')

  local rtsp_url="rtsp://${AXIS_USER}:${AXIS_PASS}@${ip}/axis-media/media.amp?starttime=${vapix_start}&stoptime=${vapix_end}"

  local timestamp
  timestamp=$(echo "$START_TIME" | sed 's/[- :]//g')
  local out_file="${OUTPUT_DIR}/${CAMERA_INPUT}_${timestamp}.mkv"

  if [[ -f "$out_file" ]]; then
    log_msg "Output already exists: $(basename "$out_file")"
    return 0
  fi

  log_msg "Capturing via RTSP (this may take a while)..."
  log_msg "  Output: $(basename "$out_file")"

  if ffmpeg -hide_banner -y \
       -rtsp_transport tcp \
       -i "$rtsp_url" \
       -c:v copy \
       -c:a copy \
       -t "$DURATION_SECS" \
       "$out_file" 2>/dev/null; then
    local actual_size
    actual_size=$(stat -f%z "$out_file" 2>/dev/null || stat -c%s "$out_file" 2>/dev/null)
    log_msg "OK: $(basename "$out_file") ($(( actual_size / 1048576 ))MB)"
  else
    log_err "RTSP export failed"
    rm -f "$out_file"
    exit 1
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Download Summary for ${CAMERA_INPUT}"
  echo "════════════════════════════════════════════════════════════════"
  echo "  Period:      ${START_TIME} → ${END_TIME}"
  echo "  Local:       ${out_file}"
  if [[ "$SKIP_UPLOAD" != "1" ]]; then
    echo "  Remote:      ${REMOTE_HOST}:${REMOTE_DIR} (uploading next...)"
  fi
  echo "════════════════════════════════════════════════════════════════"
  echo ""
}

# =============================================================================
# Upload to 4t server (post-download)
# =============================================================================

upload_to_server() {
  if [[ "$SKIP_UPLOAD" == "1" ]]; then
    log_msg "Upload skipped (SKIP_UPLOAD=1)"
    return 0
  fi

  echo ""
  upload_dir_to_server "$OUTPUT_DIR" "$REMOTE_DIR" "$CAMERA_INPUT"
}

# =============================================================================
# Main
# =============================================================================

case "$METHOD" in
  sdcard)
    retrieve_reolink "$CAMERA_URL"
    ;;
  ffmpeg)
    retrieve_axis "$CAMERA_URL"
    ;;
  *)
    log_err "Unknown recording method: $METHOD"
    exit 1
    ;;
esac

# Upload downloaded files to 4t server
upload_to_server

log_msg "Done."
