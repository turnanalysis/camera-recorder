#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Reolink SD Card Recording Puller
# Downloads full-quality recordings from Reolink camera SD cards via HTTP API.
#
# SD card recordings are significantly higher quality than RTSP streams:
#   - SD card: ~4-5 Mbps (camera's internal encoder, full quality)
#   - RTSP:    ~2-3 Mbps (reduced for streaming bandwidth)
#
# The camera stores 5-minute MP4 segments on the SD card. This script
# polls the camera, discovers new segments, and downloads them.
#
# Usage:
#   ./reolink_sdcard_pull.sh start       # Start pulling all configured cameras
#   ./reolink_sdcard_pull.sh stop        # Stop all pull processes
#   ./reolink_sdcard_pull.sh status      # Show running pull processes
#   ./reolink_sdcard_pull.sh daemon      # Run in foreground with auto-restart
#   ./reolink_sdcard_pull.sh once R3     # Pull latest segments once for R3
#   ./reolink_sdcard_pull.sh info        # Show configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# How often to check for new segments (seconds)
POLL_INTERVAL="${POLL_INTERVAL:-30}"

# How far back to search for segments (minutes)
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-10}"

# Download timeout per segment (seconds) — 5min segment is ~150MB, ~3MB/s = ~50s
DOWNLOAD_TIMEOUT=120

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
# Load credentials
# =============================================================================

CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"
if [[ -f "$CREDENTIALS_FILE" ]]; then
  source "$CREDENTIALS_FILE"
else
  log_err "Missing credentials file: $CREDENTIALS_FILE"
  exit 1
fi

# =============================================================================
# Camera configuration
# Format: name|ip_address
# Uses REOLINK_USER and REOLINK_PASS from credentials.local
# =============================================================================

# Configurable paths
BASE="${RECORDING_BASE:-/home/paul/data/recordings}"
LOGS="${LOG_BASE:-/home/paul/data/logs}"

# Camera list (parsed from cameras.conf, Reolink only)
declare -A CAMERA_IPS

parse_cameras() {
  local conf="${SCRIPT_DIR}/cameras.conf"
  if [[ ! -f "$conf" ]]; then
    log_err "Config file not found: $conf"
    exit 1
  fi

  while IFS='|' read -r name url fps bitrate encoder; do
    [[ -z "${name// }" ]] && continue
    [[ "$name" =~ ^# ]] && continue
    [[ -z "${url// }" ]] && continue

    # Only Reolink cameras (have h265Preview or h264Preview in URL)
    if [[ "$url" == *"Preview_01_main"* ]]; then
      # Extract IP from RTSP URL: rtsp://user:pass@IP:port/...
      local ip
      ip=$(echo "$url" | sed -E 's|.*@([0-9.]+):.*|\1|')
      CAMERA_IPS["$name"]="$ip"
    fi
  done < "$conf"

  if [[ ${#CAMERA_IPS[@]} -eq 0 ]]; then
    log_err "No Reolink cameras found in $conf"
    exit 1
  fi
}

# =============================================================================
# Reolink API helpers
# =============================================================================

# Login and get auth token
reolink_login() {
  local ip="$1"
  local token
  token=$(curl -s -m 10 -X POST "https://${ip}/api.cgi?cmd=Login" -k \
    -d "[{\"cmd\":\"Login\",\"param\":{\"User\":{\"Version\":\"0\",\"userName\":\"${REOLINK_USER}\",\"password\":\"${REOLINK_PASS}\"}}}]" \
    2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['value']['Token']['name'])" 2>/dev/null)

  if [[ -z "$token" ]]; then
    log_err "Failed to login to camera at ${ip}"
    return 1
  fi
  echo "$token"
}

# Search for recordings in a time range
# Returns JSON array of file entries
reolink_search() {
  local ip="$1"
  local token="$2"
  local start_time="$3"  # format: "YYYY MM DD HH MM SS"
  local end_time="$4"    # format: "YYYY MM DD HH MM SS"

  read -r sy smo sd sh smi ss <<< "$start_time"
  read -r ey emo ed eh emi es <<< "$end_time"

  local result
  result=$(curl -s -m 15 -X POST "https://${ip}/api.cgi?cmd=Search&token=${token}" -k \
    -d "[{\"cmd\":\"Search\",\"action\":0,\"param\":{\"Search\":{\"channel\":0,\"onlyStatus\":0,\"streamType\":\"main\",\"StartTime\":{\"year\":${sy},\"mon\":${smo},\"day\":${sd},\"hour\":${sh},\"min\":${smi},\"sec\":${ss}},\"EndTime\":{\"year\":${ey},\"mon\":${emo},\"day\":${ed},\"hour\":${eh},\"min\":${emi},\"sec\":${es}}}}}]" \
    2>/dev/null)

  echo "$result"
}

# Download a recording file from the camera
reolink_download() {
  local ip="$1"
  local token="$2"
  local remote_file="$3"  # e.g. "Mp4Record/2026-02-12/RecM03_20260212_162006_162506_6732830_888E411.mp4"
  local output_path="$4"

  curl -sk -m "$DOWNLOAD_TIMEOUT" \
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
# Main pull logic for one camera
# =============================================================================

pull_camera() {
  local name="$1"
  local ip="$2"
  local outdir="${BASE}/${name}"
  local trackfile="${outdir}/.downloaded_segments"
  local logfile="${LOGS}/${name}_sdpull.log"

  mkdir -p "$outdir"
  touch "$trackfile"

  # Login
  local token
  token=$(reolink_login "$ip") || return 1

  # Calculate time range: now - LOOKBACK_MINUTES to now
  local now_epoch end_time start_time
  now_epoch=$(date +%s)
  end_time=$(date -d "@${now_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null || date -r "${now_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null)
  local start_epoch=$((now_epoch - LOOKBACK_MINUTES * 60))
  start_time=$(date -d "@${start_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null || date -r "${start_epoch}" '+%Y %m %d %H %M %S' 2>/dev/null)

  # Search for recordings
  local search_result
  search_result=$(reolink_search "$ip" "$token" "$start_time" "$end_time")

  if [[ -z "$search_result" ]]; then
    return 0
  fi

  # Parse file list and download new ones
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

  if [[ -z "$files_json" ]]; then
    return 0
  fi

  local downloaded=0
  while IFS='|' read -r remote_file size start_str end_str; do
    [[ -z "$remote_file" ]] && continue

    # Skip if already downloaded (check tracking file)
    if grep -qF "$remote_file" "$trackfile" 2>/dev/null; then
      continue
    fi

    # Skip currently-recording segment (end time very close to now)
    # The last segment may still be open — skip it to avoid partial download
    local end_epoch
    end_epoch=$(date -d "${end_str:0:8} ${end_str:9:2}:${end_str:11:2}:${end_str:13:2}" +%s 2>/dev/null || \
                date -j -f "%Y%m%d %H%M%S" "${end_str:0:8} ${end_str:9:6}" +%s 2>/dev/null || echo 0)
    local age=$((now_epoch - end_epoch))
    if [[ $age -lt 30 ]]; then
      # Segment ended less than 30s ago, might still be writing
      continue
    fi

    # Output filename: camera_YYYYMMDD_HHMMSS.mp4
    local out_file="${outdir}/${name}_${start_str}.mp4"

    # Skip if file already exists locally
    if [[ -f "$out_file" ]]; then
      echo "$remote_file" >> "$trackfile"
      continue
    fi

    local size_mb=$((size / 1048576))
    log_msg "${name}: Downloading ${start_str} (${size_mb}MB)..."

    if reolink_download "$ip" "$token" "$remote_file" "$out_file"; then
      local actual_size
      actual_size=$(stat -c%s "$out_file" 2>/dev/null || stat -f%z "$out_file" 2>/dev/null)
      local actual_mb=$((actual_size / 1048576))
      log_msg "${name}: Downloaded ${out_file} (${actual_mb}MB)"
      echo "$remote_file" >> "$trackfile"
      downloaded=$((downloaded + 1))
    else
      log_err "${name}: Failed to download ${remote_file}"
    fi
  done <<< "$files_json"

  if [[ $downloaded -gt 0 ]]; then
    log_msg "${name}: Downloaded ${downloaded} new segment(s)"
  fi
}

# =============================================================================
# Continuous pull loop for one camera
# =============================================================================

pull_camera_loop() {
  local name="$1"
  local ip="$2"
  local logfile="${LOGS}/${name}_sdpull.log"

  log_msg "${name}: Starting SD card pull (${ip}, poll every ${POLL_INTERVAL}s, lookback ${LOOKBACK_MINUTES}min)"

  while true; do
    pull_camera "$name" "$ip" >> "$logfile" 2>&1 || true
    sleep "$POLL_INTERVAL"
  done
}

# =============================================================================
# Commands
# =============================================================================

start_all() {
  parse_cameras
  mkdir -p "$BASE" "$LOGS"

  log_msg "SD Card Pull - Starting"
  log_msg "Recording base: ${BASE}"
  log_msg "Poll interval: ${POLL_INTERVAL}s"
  log_msg "Lookback: ${LOOKBACK_MINUTES} minutes"
  log_msg "Cameras: ${!CAMERA_IPS[*]}"

  for name in "${!CAMERA_IPS[@]}"; do
    local ip="${CAMERA_IPS[$name]}"
    local pidfile="/tmp/sdpull_${name}.pid"

    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      log_msg "${name}: Already running (PID $(cat "$pidfile"))"
      continue
    fi

    pull_camera_loop "$name" "$ip" &
    local pid=$!
    echo "$pid" > "$pidfile"
    log_msg "${name}: Started with PID ${pid} (${ip})"
  done

  echo ""
  show_status
}

stop_all() {
  log_msg "Stopping all SD card pulls..."
  for pidfile in /tmp/sdpull_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name
    name=$(basename "$pidfile" .pid | sed 's/sdpull_//')
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log_msg "${name}: Stopped (PID ${pid})"
    fi
    rm -f "$pidfile"
  done
  log_msg "All pulls stopped."
}

show_status() {
  echo ""
  echo "SD Card Pull Status"
  echo "===================="

  local running=0
  for pidfile in /tmp/sdpull_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name
    name=$(basename "$pidfile" .pid | sed 's/sdpull_//')
    local pid
    pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ✓ ${name} running (PID: ${pid})"
      running=$((running + 1))

      # Show recent downloads
      local logfile="${LOGS}/${name}_sdpull.log"
      if [[ -f "$logfile" ]]; then
        local recent
        recent=$(tail -3 "$logfile" 2>/dev/null)
        if [[ -n "$recent" ]]; then
          echo "    Last activity:"
          echo "$recent" | sed 's/^/      /'
        fi
      fi
    else
      echo "  ✗ ${name} stopped (stale PID file)"
      rm -f "$pidfile"
    fi
  done

  if [[ $running -eq 0 ]]; then
    echo "  (no active pulls)"
  fi

  echo ""

  # Show disk usage
  if [[ -d "$BASE" ]]; then
    echo "Disk usage:"
    du -sh "$BASE"/*/ 2>/dev/null | sed 's/^/  /' || echo "  (empty)"
    echo ""
  fi
}

once() {
  local target="${1:-}"
  parse_cameras

  if [[ -n "$target" ]]; then
    local ip="${CAMERA_IPS[$target]:-}"
    if [[ -z "$ip" ]]; then
      log_err "Camera '${target}' not found. Available: ${!CAMERA_IPS[*]}"
      exit 1
    fi
    mkdir -p "$BASE" "$LOGS"
    log_msg "One-time pull for ${target} (${ip})"
    pull_camera "$target" "$ip"
  else
    mkdir -p "$BASE" "$LOGS"
    for name in "${!CAMERA_IPS[@]}"; do
      local ip="${CAMERA_IPS[$name]}"
      log_msg "One-time pull for ${name} (${ip})"
      pull_camera "$name" "$ip"
    done
  fi
}

daemon_mode() {
  parse_cameras
  mkdir -p "$BASE" "$LOGS"

  trap 'log_msg "Shutting down..."; stop_all; exit 0' SIGTERM SIGINT

  log_msg "SD Card Pull Daemon - Starting"
  log_msg "Cameras: ${!CAMERA_IPS[*]}"
  log_msg "Poll interval: ${POLL_INTERVAL}s"

  start_all

  # Monitor and restart
  while true; do
    sleep "$POLL_INTERVAL"
    for name in "${!CAMERA_IPS[@]}"; do
      local pidfile="/tmp/sdpull_${name}.pid"
      if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if ! kill -0 "$pid" 2>/dev/null; then
          log_msg "${name}: Pull process died, restarting..."
          rm -f "$pidfile"
          local ip="${CAMERA_IPS[$name]}"
          pull_camera_loop "$name" "$ip" &
          echo "$!" > "$pidfile"
        fi
      fi
    done
  done
}

show_info() {
  parse_cameras
  echo ""
  echo "SD Card Pull Configuration"
  echo "==========================="
  echo "Poll interval:   ${POLL_INTERVAL}s"
  echo "Lookback:        ${LOOKBACK_MINUTES} minutes"
  echo "Download timeout: ${DOWNLOAD_TIMEOUT}s"
  echo "Recording base:  ${BASE}"
  echo "Log directory:   ${LOGS}"
  echo ""
  echo "Cameras:"
  for name in "${!CAMERA_IPS[@]}"; do
    echo "  ${name}: ${CAMERA_IPS[$name]}"
  done
  echo ""
  echo "Environment overrides:"
  echo "  POLL_INTERVAL=60 $0 start     # Poll every 60s"
  echo "  LOOKBACK_MINUTES=30 $0 once   # Search last 30 minutes"
  echo ""
}

# =============================================================================
# Main
# =============================================================================

case "${1:-}" in
  start)
    start_all
    ;;
  stop)
    stop_all
    ;;
  restart)
    stop_all
    sleep 1
    start_all
    ;;
  status)
    show_status
    ;;
  daemon)
    daemon_mode
    ;;
  once)
    once "${2:-}"
    ;;
  info)
    show_info
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|daemon|once [camera]|info}"
    echo ""
    echo "  start           Start pulling SD card recordings for all Reolink cameras"
    echo "  stop            Stop all pull processes"
    echo "  restart         Restart all pull processes"
    echo "  status          Show running pulls and recent activity"
    echo "  daemon          Run in foreground with monitoring and auto-restart"
    echo "  once [camera]   Pull latest segments once (optionally for specific camera)"
    echo "  info            Show configuration"
    echo ""
    echo "Pulls full-quality recordings directly from Reolink SD cards via HTTP API."
    echo "SD card quality (~4-5 Mbps) is significantly better than RTSP (~2-3 Mbps)."
    echo ""
    echo "Environment variables:"
    echo "  POLL_INTERVAL=30      Seconds between checks (default: 30)"
    echo "  LOOKBACK_MINUTES=10   How far back to search (default: 10)"
    exit 1
    ;;
esac
