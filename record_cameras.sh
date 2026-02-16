#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Camera Recording — Unified Script
#
# Two recording methods based on camera type:
#   sdcard  — Reolink: Pull full-quality recordings from camera SD card via
#             HTTP API. Best quality for fast-moving skiers. ~5min segment delay.
#   ffmpeg  — Axis/other: RTSP stream capture with -c:v copy (no re-encode).
#             Real-time recording. Full RTSP stream quality.
#
# Usage:
#   ./record_cameras.sh start       # Start recording all cameras
#   ./record_cameras.sh stop        # Stop all recordings
#   ./record_cameras.sh restart     # Restart all
#   ./record_cameras.sh status      # Show running recordings
#   ./record_cameras.sh daemon      # Run in foreground with auto-restart
#   ./record_cameras.sh info        # Show platform and config info
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Logging
# =============================================================================

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_debug() {
  if [[ "${DEBUG:-}" == "1" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
  fi
}

# =============================================================================
# Load credentials
# =============================================================================

CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"
if [[ -f "$CREDENTIALS_FILE" ]]; then
  log_msg "Loading credentials from $CREDENTIALS_FILE"
  source "$CREDENTIALS_FILE"
else
  log_err "Missing credentials file: $CREDENTIALS_FILE"
  echo "Create it from the template: cp credentials.template credentials.local"
  exit 1
fi

# =============================================================================
# Configuration
# =============================================================================

CONF="${SCRIPT_DIR}/cameras.conf"
BASE="${RECORDING_BASE:-/home/paul/data/recordings}"
LOGS="${LOG_BASE:-/home/paul/data/logs}"

# RTSP (ffmpeg) settings
SEGMENT_SECONDS=600     # 10-minute segments for RTSP recordings

# SD card pull settings
SDCARD_POLL_INTERVAL="${SDCARD_POLL_INTERVAL:-30}"     # Seconds between SD card checks
SDCARD_LOOKBACK="${SDCARD_LOOKBACK:-10}"               # Minutes to look back for segments
SDCARD_DOWNLOAD_TIMEOUT=180                            # Seconds per segment download

# Substitute credentials in URL
expand_url() {
  local url="$1"
  url="${url//\$REOLINK_USER/$REOLINK_USER}"
  url="${url//\$REOLINK_PASS/$REOLINK_PASS}"
  url="${url//\$AXIS_USER/$AXIS_USER}"
  url="${url//\$AXIS_PASS/$AXIS_PASS}"
  eval echo "$url"
}

# =============================================================================
# Reolink SD Card Pull — API helpers
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

  curl -s -m 15 -X POST "https://${ip}/api.cgi?cmd=Search&token=${token}" -k \
    -d "[{\"cmd\":\"Search\",\"action\":0,\"param\":{\"Search\":{\"channel\":0,\"onlyStatus\":0,\"streamType\":\"main\",\"StartTime\":{\"year\":${sy},\"mon\":${smo},\"day\":${sd},\"hour\":${sh},\"min\":${smi},\"sec\":${ss}},\"EndTime\":{\"year\":${ey},\"mon\":${emo},\"day\":${ed},\"hour\":${eh},\"min\":${emi},\"sec\":${es}}}}}]" \
    2>/dev/null
}

reolink_download() {
  local ip="$1" token="$2" remote_file="$3" output_path="$4"

  curl -sk -m "$SDCARD_DOWNLOAD_TIMEOUT" \
    -o "$output_path" \
    "https://${ip}/cgi-bin/api.cgi?cmd=Playback&source=${remote_file}&output=${remote_file}&token=${token}" \
    2>/dev/null

  if [[ -f "$output_path" ]] && [[ $(stat -c%s "$output_path" 2>/dev/null || stat -f%z "$output_path" 2>/dev/null) -gt 1000 ]]; then
    return 0
  else
    rm -f "$output_path"
    return 1
  fi
}

# =============================================================================
# SD card pull — main logic for one camera
# =============================================================================

sdcard_pull_once() {
  local name="$1" ip="$2"
  local outdir="${BASE}/${name}"
  local trackfile="${outdir}/.downloaded_segments"

  mkdir -p "$outdir"
  touch "$trackfile"

  # Login
  local token
  token=$(reolink_login "$ip") || return 1

  # Time range: now - LOOKBACK to now
  local now_epoch end_time start_time start_epoch
  now_epoch=$(date +%s)
  end_time=$(date -d "@${now_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null || date -r "${now_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null)
  start_epoch=$((now_epoch - SDCARD_LOOKBACK * 60))
  start_time=$(date -d "@${start_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null || date -r "${start_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null)

  # Search
  local search_result
  search_result=$(reolink_search "$ip" "$token" "$start_time" "$end_time")
  [[ -z "$search_result" ]] && return 0

  # Parse file list
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
  [[ -z "$files_json" ]] && return 0

  local downloaded=0
  while IFS='|' read -r remote_file size start_str end_str; do
    [[ -z "$remote_file" ]] && continue

    # Skip already downloaded
    grep -qF "$remote_file" "$trackfile" 2>/dev/null && continue

    # Skip segment still being written (ended < 30s ago)
    local end_epoch age
    end_epoch=$(date -d "${end_str:0:8} ${end_str:9:2}:${end_str:11:2}:${end_str:13:2}" +%s 2>/dev/null || \
                date -j -f "%Y%m%d %H%M%S" "${end_str:0:8} ${end_str:9:6}" +%s 2>/dev/null || echo 0)
    age=$((now_epoch - end_epoch))
    [[ $age -lt 30 ]] && continue

    local out_file="${outdir}/${name}_${start_str}.mp4"

    # Skip if already exists locally
    if [[ -f "$out_file" ]]; then
      echo "$remote_file" >> "$trackfile"
      continue
    fi

    local size_mb=$((size / 1048576))
    log_msg "${name}: Downloading ${start_str} (${size_mb}MB)..."

    if reolink_download "$ip" "$token" "$remote_file" "$out_file"; then
      local actual_size actual_mb
      actual_size=$(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file" 2>/dev/null)
      actual_mb=$((actual_size / 1048576))
      log_msg "${name}: Downloaded ${out_file} (${actual_mb}MB)"
      echo "$remote_file" >> "$trackfile"
      downloaded=$((downloaded + 1))
    else
      log_err "${name}: Failed to download ${remote_file}"
    fi
  done <<< "$files_json"

  [[ $downloaded -gt 0 ]] && log_msg "${name}: Downloaded ${downloaded} new segment(s)"
}

# SD card pull loop (runs in background)
sdcard_pull_loop() {
  local name="$1" ip="$2"
  local logfile="${LOGS}/${name}.log"

  log_msg "${name}: Starting SD card pull (${ip}, poll every ${SDCARD_POLL_INTERVAL}s)"

  while true; do
    sdcard_pull_once "$name" "$ip" >> "$logfile" 2>&1 || true
    sleep "$SDCARD_POLL_INTERVAL"
  done
}

# =============================================================================
# RTSP ffmpeg recording — for Axis and other non-Reolink cameras
# =============================================================================

ffmpeg_start_one() {
  local name="$1" url_template="$2" fps="${3:-30}" bitrate="${4:-18000000}"
  local url outdir logfile timestamp

  url=$(expand_url "$url_template")
  outdir="${BASE}/${name}"
  logfile="${LOGS}/${name}.log"
  timestamp=$(date +%Y%m%d_%H%M%S)

  mkdir -p "$outdir"

  # Check if already running
  if pgrep -af "ffmpeg.*/${name}/" >/dev/null 2>&1; then
    log_msg "${name}: ffmpeg already running"
    return 0
  fi

  log_msg "${name}: Starting RTSP -c:v copy (${fps}fps)..."

  echo "" >> "$logfile"
  echo "=== FFmpeg started at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$logfile"
  echo "URL: ${url//:*@/:***@}" >> "$logfile"

  # RTSP -c:v copy: no re-encode, pass through original stream
  # -fflags +genpts: fix non-monotonic timestamps
  nohup ffmpeg -hide_banner -y \
    -fflags +genpts \
    -rtsp_transport tcp \
    -i "${url}" \
    -c:v copy \
    -c:a copy \
    -f segment \
    -segment_time "${SEGMENT_SECONDS}" \
    -segment_format matroska \
    -reset_timestamps 1 \
    -strftime 1 \
    "${outdir}/${name}_%Y%m%d_%H%M%S.mkv" \
    >> "$logfile" 2>&1 &

  local pid=$!
  echo "${pid}" > "/tmp/camera_${name}.pid"
  log_msg "${name}: Started ffmpeg with PID ${pid}"

  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null; then
    log_err "${name}: ffmpeg failed to start (check ${logfile})"
    rm -f "/tmp/camera_${name}.pid"
    return 1
  fi
}

# =============================================================================
# Unified start/stop/status
# =============================================================================

start_all() {
  mkdir -p "$BASE" "$LOGS"

  if [[ ! -f "$CONF" ]]; then
    log_err "Config file not found: $CONF"
    exit 1
  fi

  log_msg "Camera Recording — Starting"
  log_msg "Recording base: ${BASE}"
  log_msg "Config: ${CONF}"

  while IFS='|' read -r name url fps bitrate method; do
    [[ -z "${name// }" ]] && continue
    [[ "$name" =~ ^# ]] && continue
    [[ -z "${url// }" ]] && continue

    method="${method:-ffmpeg}"

    case "$method" in
      sdcard)
        local pidfile="/tmp/sdpull_${name}.pid"
        if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
          log_msg "${name}: SD card pull already running (PID $(cat "$pidfile"))"
          continue
        fi
        sdcard_pull_loop "$name" "$url" &
        local pid=$!
        echo "$pid" > "$pidfile"
        log_msg "${name}: SD card pull started (PID ${pid}, IP ${url})"
        ;;
      ffmpeg)
        ffmpeg_start_one "$name" "$url" "${fps:-30}" "${bitrate:-18000000}"
        ;;
      *)
        log_err "${name}: Unknown method '${method}' (use sdcard or ffmpeg)"
        ;;
    esac
  done < "$CONF"

  sleep 2
  show_status
}

stop_all() {
  log_msg "Stopping all camera recordings..."

  # Stop SD card pull processes
  for pidfile in /tmp/sdpull_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name pid
    name=$(basename "$pidfile" .pid | sed 's/sdpull_//')
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_msg "${name}: SD card pull stopped (PID ${pid})"
    fi
    rm -f "$pidfile"
  done

  # Stop ffmpeg processes
  for pidfile in /tmp/camera_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name pid
    name=$(basename "$pidfile" .pid | sed 's/camera_//')
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill -INT "$pid" 2>/dev/null || true
      sleep 2
      kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
      log_msg "${name}: ffmpeg stopped (PID ${pid})"
    fi
    rm -f "$pidfile"
  done

  # Catch any remaining ffmpeg recording processes
  pkill -INT -f "ffmpeg.*recordings" 2>/dev/null || true
  sleep 1
  pkill -TERM -f "ffmpeg.*recordings" 2>/dev/null || true

  log_msg "All recordings stopped."
}

show_status() {
  echo ""
  echo "Camera Recording Status"
  echo "========================"

  local running=0

  # SD card pull processes
  for pidfile in /tmp/sdpull_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name pid
    name=$(basename "$pidfile" .pid | sed 's/sdpull_//')
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ✓ ${name} [sdcard] running (PID: ${pid})"
      running=$((running + 1))
      # Show last downloaded file
      local latest
      latest=$(ls -t "${BASE}/${name}/"*.mp4 2>/dev/null | head -1)
      if [[ -n "$latest" ]]; then
        local lsize
        lsize=$(du -h "$latest" 2>/dev/null | cut -f1)
        echo "    Last: $(basename "$latest") (${lsize})"
      fi
    else
      echo "  ✗ ${name} [sdcard] stopped (stale PID)"
      rm -f "$pidfile"
    fi
  done

  # ffmpeg processes
  for pidfile in /tmp/camera_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name pid
    name=$(basename "$pidfile" .pid | sed 's/camera_//')
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ✓ ${name} [ffmpeg] running (PID: ${pid})"
      running=$((running + 1))
      local latest
      latest=$(ls -t "${BASE}/${name}/"*.mkv 2>/dev/null | head -1)
      if [[ -n "$latest" ]]; then
        local lsize
        lsize=$(du -h "$latest" 2>/dev/null | cut -f1)
        echo "    Last: $(basename "$latest") (${lsize})"
      fi
    else
      echo "  ✗ ${name} [ffmpeg] stopped (stale PID)"
      rm -f "$pidfile"
    fi
  done

  if [[ $running -eq 0 ]]; then
    echo "  (no active recordings)"
  fi

  echo ""

  # Disk usage
  if [[ -d "$BASE" ]]; then
    echo "Disk usage:"
    du -sh "$BASE"/*/ 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
    echo ""
  fi
}

daemon_mode() {
  mkdir -p "$BASE" "$LOGS"
  trap 'log_msg "Shutting down..."; stop_all; exit 0' SIGTERM SIGINT

  log_msg "Camera Recording Daemon — Starting"

  start_all

  local monitor_interval=30
  while true; do
    sleep "$monitor_interval"

    # Check and restart dead processes
    while IFS='|' read -r name url fps bitrate method; do
      [[ -z "${name// }" ]] && continue
      [[ "$name" =~ ^# ]] && continue
      [[ -z "${url// }" ]] && continue

      method="${method:-ffmpeg}"

      case "$method" in
        sdcard)
          local pidfile="/tmp/sdpull_${name}.pid"
          if [[ ! -f "$pidfile" ]] || ! kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
            log_msg "${name}: SD card pull died, restarting..."
            rm -f "$pidfile"
            sdcard_pull_loop "$name" "$url" &
            echo "$!" > "$pidfile"
          fi
          ;;
        ffmpeg)
          local pidfile="/tmp/camera_${name}.pid"
          if [[ ! -f "$pidfile" ]] || ! kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
            log_msg "${name}: ffmpeg died, restarting..."
            rm -f "$pidfile"
            ffmpeg_start_one "$name" "$url" "${fps:-30}" "${bitrate:-18000000}"
          fi
          ;;
      esac
    done < "$CONF"
  done
}

show_info() {
  echo ""
  echo "Camera Recording Configuration"
  echo "================================"
  echo "Config file:     ${CONF}"
  echo "Recording base:  ${BASE}"
  echo "Log directory:   ${LOGS}"
  echo ""
  echo "SD card pull settings:"
  echo "  Poll interval:     ${SDCARD_POLL_INTERVAL}s"
  echo "  Lookback:          ${SDCARD_LOOKBACK} minutes"
  echo "  Download timeout:  ${SDCARD_DOWNLOAD_TIMEOUT}s"
  echo ""
  echo "RTSP (ffmpeg) settings:"
  echo "  Segment duration:  ${SEGMENT_SECONDS}s"
  echo "  Mode:              -c:v copy (no re-encode)"
  echo ""
  echo "Cameras:"
  if [[ -f "$CONF" ]]; then
    while IFS='|' read -r name url fps bitrate method; do
      [[ -z "${name// }" ]] && continue
      [[ "$name" =~ ^# ]] && continue
      [[ -z "${url// }" ]] && continue
      method="${method:-ffmpeg}"
      case "$method" in
        sdcard) echo "  ${name}: SD card pull from ${url}" ;;
        ffmpeg) echo "  ${name}: RTSP -c:v copy (${fps:-30}fps)" ;;
      esac
    done < "$CONF"
  fi
  echo ""
  echo "Environment overrides:"
  echo "  SDCARD_POLL_INTERVAL=60 $0 start   # Poll SD cards every 60s"
  echo "  SDCARD_LOOKBACK=30 $0 start        # Search last 30 minutes"
  echo "  DEBUG=1 $0 start                   # Verbose logging"
  echo ""
}

# =============================================================================
# Main
# =============================================================================

case "${1:-start}" in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    sleep 2
    start_all
    ;;
  status)
    show_status
    ;;
  daemon)
    daemon_mode
    ;;
  info)
    show_info
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|daemon|info}"
    echo ""
    echo "  start   - Start recording all cameras"
    echo "  stop    - Stop all recordings"
    echo "  restart - Restart all recordings"
    echo "  status  - Show running recordings"
    echo "  daemon  - Run in foreground with monitoring and auto-restart"
    echo "  info    - Show configuration"
    echo ""
    echo "Recording methods (per camera in cameras.conf):"
    echo "  sdcard  - Reolink: pull full-quality recordings from SD card via HTTP API"
    echo "  ffmpeg  - Axis/other: RTSP stream capture with -c:v copy (no re-encode)"
    exit 1
    ;;
esac
