#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Camera Recording with Hardware Encoding
# Supports both Reolink and Axis cameras
# Auto-detects platform: Jetson (NVENC), x86 (VA-API/QSV), or software fallback
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
  # Check for Jetson (NVIDIA Tegra)
  if [[ -f /etc/nv_tegra_release ]] || [[ -d /sys/class/tegra* ]] 2>/dev/null; then
    if gst-inspect-1.0 nvv4l2h264enc &>/dev/null; then
      echo "jetson"
      return
    fi
  fi

  # Check for VA-API (Intel/AMD)
  # Use GST_VAAPI_ALL_DRIVERS=1 to support AMD Mesa (not in GStreamer's default whitelist)
  if GST_VAAPI_ALL_DRIVERS=1 gst-inspect-1.0 vaapih264enc &>/dev/null; then
    # Verify VA-API actually works (has H264 encode support)
    # Note: vainfo may print X server errors to stderr on headless systems, so check stdout for profiles
    if vainfo 2>/dev/null | grep -q "VAProfileH264.*VAEntrypointEncSlice"; then
      echo "vaapi"
      return
    fi
  fi

  # Fallback to software encoding
  if gst-inspect-1.0 x264enc &>/dev/null; then
    echo "software"
    return
  fi

  echo "none"
}

PLATFORM="${ENCODER_PLATFORM:-$(detect_platform)}"

case "$PLATFORM" in
  jetson)
    PLATFORM_DESC="Jetson NVENC"
    MONITOR_CMD="tegrastats"
    ;;
  vaapi)
    PLATFORM_DESC="VA-API (Intel/AMD)"
    # Enable all VA-API drivers (AMD Mesa not in GStreamer's default whitelist)
    export GST_VAAPI_ALL_DRIVERS=1
    # Detect GPU vendor for appropriate monitor command
    if lspci 2>/dev/null | grep -qi "vga.*intel"; then
      MONITOR_CMD="intel_gpu_top"
    elif lspci 2>/dev/null | grep -qi "vga.*amd\|vga.*radeon"; then
      MONITOR_CMD="radeontop"
    else
      MONITOR_CMD="htop"
    fi
    ;;
  software)
    PLATFORM_DESC="Software x264 (high CPU)"
    MONITOR_CMD="htop"
    ;;
  *)
    echo "ERROR: No suitable encoder found."
    echo "Install GStreamer plugins:"
    echo "  Jetson: nvidia-l4t-gstreamer (usually pre-installed)"
    echo "  Intel:  sudo apt install gstreamer1.0-vaapi intel-media-va-driver vainfo"
    echo "  Fallback: sudo apt install gstreamer1.0-plugins-ugly"
    exit 1
    ;;
esac

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

  local logfile="${LOGS}/${name}.log"
  
  # Check if already running for this camera
  if pgrep -af "gst-launch" | grep -F -- "/${name}/" >/dev/null 2>&1; then
    echo "Already running: ${name}"
    return 0
  fi

  # Calculate GOP size (1 second of frames)
  local gop_size="${fps}"
  local bitrate_kbps=$((bitrate/1000))

  echo "Starting ${name} (${PLATFORM_DESC} @ ${fps}fps, ${bitrate_kbps}kbps)..."

  # Generate timestamp for this recording session
  local timestamp=$(date +%Y%m%d_%H%M%S)

  # Build platform-specific encode pipeline
  local encode_pipeline
  case "$PLATFORM" in
    jetson)
      # NVIDIA Jetson hardware encoding
      encode_pipeline="nvv4l2decoder ! nvv4l2h264enc bitrate=${bitrate} iframeinterval=${gop_size}"
      ;;
    vaapi)
      # Intel/AMD VA-API hardware encoding
      # Note: vaapi uses kbps for bitrate
      encode_pipeline="vaapidecodebin ! vaapih264enc bitrate=${bitrate_kbps} keyframe-period=${gop_size}"
      ;;
    software)
      # Software x264 encoding (high CPU usage)
      encode_pipeline="avdec_h264 ! x264enc bitrate=${bitrate_kbps} key-int-max=${gop_size} speed-preset=superfast tune=zerolatency"
      ;;
  esac

  # splitmuxsink uses %05d for segment number (00000, 00001, etc.)
  # Format: cameraname_YYYYMMDD_HHMMSS_00000.mkv
  nohup gst-launch-1.0 -e \
    rtspsrc location="${url}" protocols=tcp latency=0 ! \
    rtph264depay ! h264parse ! ${encode_pipeline} ! \
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
  echo "Camera Recording Status (${PLATFORM_DESC})"
  echo "============================================"
  
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

  echo "Monitor with: ${MONITOR_CMD}"
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
  info)
    echo "Platform: ${PLATFORM_DESC}"
    echo "Encoder:  ${PLATFORM}"
    echo "Monitor:  ${MONITOR_CMD}"
    echo ""
    echo "Override with: ENCODER_PLATFORM=jetson|vaapi|software $0 start"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|daemon|info}"
    echo ""
    echo "  start   - Start recording all cameras in config"
    echo "  stop    - Stop all recordings gracefully"
    echo "  restart - Stop then start all recordings"
    echo "  status  - Show running recordings"
    echo "  daemon  - Run in foreground, monitor and auto-restart crashed recordings"
    echo "  info    - Show detected platform and encoder"
    exit 1
    ;;
esac
