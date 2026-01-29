#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Camera Recording with Jetson GPU Hardware Encoding
# Supports both Reolink and Axis cameras
# Uses GStreamer + nvv4l2h264enc for ~20x less CPU than ffmpeg libx264
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load local credentials (not in git)
CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"
if [[ -f "$CREDENTIALS_FILE" ]]; then
  source "$CREDENTIALS_FILE"
else
  echo "ERROR: Missing credentials file: $CREDENTIALS_FILE"
  echo ""
  echo "Create it from the template:"
  echo "  cp credentials.template credentials.local"
  echo "  # Edit credentials.local with your passwords"
  exit 1
fi

# Config file (cameras defined here, credentials substituted at runtime)
CONF="${SCRIPT_DIR}/cameras.conf"
BASE="${RECORDING_BASE:-/home/paul/data/recordings}"
LOGS="${LOG_BASE:-/home/paul/data/logs}"

SEGMENT_SECONDS=600     # 10 minutes

# Hardware encoder settings (bitrate in bits/sec)
DEFAULT_BITRATE=8000000      # 8Mbps for 30fps
HIGH_BITRATE=12000000        # 12Mbps for 60fps

mkdir -p "$BASE" "$LOGS"

# Substitute credentials in URL
expand_url() {
  local url="$1"
  # Replace credential placeholders with actual values
  url="${url//\$REOLINK_USER/$REOLINK_USER}"
  url="${url//\$REOLINK_PASS/$REOLINK_PASS}"
  url="${url//\$AXIS_USER/$AXIS_USER}"
  url="${url//\$AXIS_PASS/$AXIS_PASS}"
  # Also expand any environment variables
  eval echo "$url"
}

start_one () {
  local name="$1"
  local url_template="$2"
  local fps="${3:-30}"
  local bitrate="${4:-$DEFAULT_BITRATE}"

  # Expand credentials in URL
  local url
  url=$(expand_url "$url_template")

  local outdir="${BASE}/${name}"
  mkdir -p "$outdir"

  local logfile="${LOGS}/${name}_gpu.log"
  
  # Check if already running for this camera
  if pgrep -af "gst-launch" | grep -F -- "/${name}/" >/dev/null 2>&1; then
    echo "Already running: ${name}"
    return 0
  fi

  # Calculate GOP size (1 second of frames)
  local gop_size="${fps}"

  echo "Starting ${name} (GPU encoding @ ${fps}fps, $((bitrate/1000))kbps)..."

  # Generate timestamp for this recording session
  local timestamp=$(date +%Y%m%d_%H%M%S)
  
  # splitmuxsink uses %05d for segment number (00000, 00001, etc.)
  # Format: cameraname_YYYYMMDD_HHMMSS_00000.mkv
  nohup gst-launch-1.0 -e \
    rtspsrc location="${url}" protocols=tcp latency=0 ! \
    rtph264depay ! h264parse ! nvv4l2decoder ! \
    nvv4l2h264enc bitrate=${bitrate} iframeinterval=${gop_size} ! \
    h264parse ! \
    splitmuxsink location="${outdir}/${name}_${timestamp}_%05d.mkv" \
      max-size-time=$((SEGMENT_SECONDS * 1000000000)) \
      muxer=matroskamux \
    >> "$logfile" 2>&1 &

  local pid=$!
  echo "  PID: ${pid}"
  
  # Save PID for easier management
  echo "${pid}" > "/tmp/camera_${name}.pid"
}

stop_one () {
  local name="$1"
  local pidfile="/tmp/camera_${name}.pid"
  
  if [[ -f "$pidfile" ]]; then
    local pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Stopping ${name} (PID: ${pid})..."
      kill -INT "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
      rm -f "$pidfile"
    fi
  fi
}

show_status () {
  echo ""
  echo "Camera Recording Status"
  echo "========================"
  
  for pidfile in /tmp/camera_*.pid; do
    [[ -f "$pidfile" ]] || continue
    local name=$(basename "$pidfile" .pid | sed 's/camera_//')
    local pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      echo "  ✓ ${name} running (PID: ${pid})"
    else
      echo "  ✗ ${name} stopped (stale PID file)"
      rm -f "$pidfile"
    fi
  done
  
  echo ""
  echo "GStreamer processes:"
  pgrep -af "gst-launch.*recordings" || echo "  (none)"
  echo ""
}

stop_all () {
  echo "Stopping all camera recordings..."
  
  # Graceful shutdown
  pkill -INT -f "gst-launch.*recordings" 2>/dev/null || true
  sleep 2
  
  # Force if needed
  if pgrep -af "gst-launch.*recordings" >/dev/null 2>&1; then
    pkill -TERM -f "gst-launch.*recordings" 2>/dev/null || true
    sleep 2
  fi

  if pgrep -af "gst-launch.*recordings" >/dev/null 2>&1; then
    pkill -9 -f "gst-launch.*recordings" 2>/dev/null || true
  fi
  
  # Clean up PID files
  rm -f /tmp/camera_*.pid
  
  echo "All recordings stopped."
}

start_all () {
  if [[ ! -f "$CONF" ]]; then
    echo "ERROR: Config file not found: $CONF"
    echo ""
    echo "Create it with format:"
    echo "  name|rtsp_url|fps|bitrate"
    exit 1
  fi

  # Read config lines: name|url|fps|bitrate
  while IFS='|' read -r name url fps bitrate; do
    # Skip empty lines and comments
    [[ -z "${name// }" ]] && continue
    [[ "$name" =~ ^# ]] && continue
    [[ -z "${url// }" ]] && continue

    # Use defaults if not specified
    fps="${fps:-30}"
    bitrate="${bitrate:-$DEFAULT_BITRATE}"

    start_one "$name" "$url" "$fps" "$bitrate"
  done < "$CONF"

  sleep 2
  show_status
  
  echo "Monitor GPU usage with: tegrastats"
  echo "Check logs in: ${LOGS}/"
}

# =============================================================================
# Daemon mode - monitor and restart crashed recordings
# =============================================================================

MONITOR_INTERVAL=30  # seconds between health checks

monitor_and_restart() {
  echo "Starting daemon mode - monitoring recordings..."
  echo "Press Ctrl+C to stop"
  
  # Trap SIGTERM/SIGINT for graceful shutdown
  trap 'echo "Shutting down..."; stop_all; exit 0' SIGTERM SIGINT
  
  # Initial start
  start_all
  
  while true; do
    sleep "$MONITOR_INTERVAL"
    
    # Check each camera from config
    while IFS='|' read -r name url fps bitrate; do
      [[ -z "${name// }" ]] && continue
      [[ "$name" =~ ^# ]] && continue
      [[ -z "${url// }" ]] && continue
      
      fps="${fps:-30}"
      bitrate="${bitrate:-$DEFAULT_BITRATE}"
      
      local pidfile="/tmp/camera_${name}.pid"
      local needs_restart=false
      
      if [[ -f "$pidfile" ]]; then
        local pid=$(cat "$pidfile")
        if ! kill -0 "$pid" 2>/dev/null; then
          echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${name} died (PID ${pid}), restarting..."
          rm -f "$pidfile"
          needs_restart=true
        fi
      else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${name} not running, starting..."
        needs_restart=true
      fi
      
      if [[ "$needs_restart" == "true" ]]; then
        start_one "$name" "$url" "$fps" "$bitrate"
      fi
    done < "$CONF"
  done
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
    monitor_and_restart
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|daemon}"
    echo ""
    echo "  start   - Start recording all cameras in config"
    echo "  stop    - Stop all recordings gracefully"
    echo "  restart - Stop then start all recordings"
    echo "  status  - Show running recordings"
    echo "  daemon  - Run in foreground, monitor and auto-restart crashed recordings"
    exit 1
    ;;
esac
