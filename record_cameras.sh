#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Camera Recording with Hardware Encoding
# Supports both Reolink and Axis cameras
# Auto-detects platform: Jetson (NVENC), x86 (VA-API/QSV), or software fallback
# Per-camera encoder override supported via 5th field in cameras.conf
# Encoder options: jetson, vaapi, software (gst x264), ffmpeg (recommended)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Logging with timestamps
# =============================================================================

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_debug() {
  if [[ "${DEBUG:-}" == "1" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
  fi
}

# Load local credentials FIRST (needed for ENCODER_PLATFORM override)
CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"
if [[ -f "$CREDENTIALS_FILE" ]]; then
  log_msg "Loading credentials from $CREDENTIALS_FILE"
  source "$CREDENTIALS_FILE"
else
  log_msg "ERROR: Missing credentials file: $CREDENTIALS_FILE"
  echo ""
  echo "Create it from the template:"
  echo "  cp credentials.template credentials.local"
  echo "  # Edit credentials.local with your passwords"
  exit 1
fi

# =============================================================================
# Platform Detection
# =============================================================================

detect_platform() {
  log_debug "Detecting platform..."

  # Check for Jetson (NVIDIA Tegra)
  if [[ -f /etc/nv_tegra_release ]] || [[ -d /sys/class/tegra* ]] 2>/dev/null; then
    log_debug "Detected Jetson/Tegra platform"
    if gst-inspect-1.0 nvv4l2h264enc &>/dev/null; then
      log_debug "nvv4l2h264enc encoder available"
      echo "jetson"
      return
    else
      log_debug "nvv4l2h264enc not available, continuing detection..."
    fi
  fi

  # Check for VA-API (Intel/AMD)
  # Use GST_VAAPI_ALL_DRIVERS=1 to support AMD Mesa (not in GStreamer's default whitelist)
  if GST_VAAPI_ALL_DRIVERS=1 gst-inspect-1.0 vaapih264enc &>/dev/null; then
    log_debug "vaapih264enc plugin found"
    # Verify VA-API actually works (has H264 encode support)
    # Note: vainfo may print X server errors to stderr on headless systems, so check stdout for profiles
    if vainfo 2>/dev/null | grep -q "VAProfileH264.*VAEntrypointEncSlice"; then
      log_debug "VA-API H264 encode support confirmed"
      echo "vaapi"
      return
    else
      log_debug "VA-API H264 encode not available in vainfo"
    fi
  fi

  # Prefer FFmpeg software encoding (better quality for fast motion)
  if command -v ffmpeg &>/dev/null; then
    log_debug "FFmpeg found at $(command -v ffmpeg)"
    # Use pattern match to avoid pipefail issues with ffmpeg exit code
    if [[ "$(ffmpeg -encoders 2>/dev/null)" == *libx264* ]]; then
      log_debug "libx264 encoder available in FFmpeg"
      echo "ffmpeg"
      return
    else
      log_debug "libx264 not available in FFmpeg"
    fi
  else
    log_debug "FFmpeg not found"
  fi

  # GStreamer software fallback
  if gst-inspect-1.0 x264enc &>/dev/null; then
    log_debug "GStreamer x264enc available"
    echo "software"
    return
  fi

  log_debug "No encoder found"
  echo "none"
}

# Check if a specific encoder is available
check_encoder_available() {
  local encoder="$1"
  case "$encoder" in
    jetson)
      [[ -f /etc/nv_tegra_release ]] || [[ -d /sys/class/tegra* ]] 2>/dev/null || return 1
      gst-inspect-1.0 nvv4l2h264enc &>/dev/null || return 1
      ;;
    vaapi)
      GST_VAAPI_ALL_DRIVERS=1 gst-inspect-1.0 vaapih264enc &>/dev/null || return 1
      vainfo 2>/dev/null | grep -q "VAProfileH264.*VAEntrypointEncSlice" || return 1
      ;;
    ffmpeg)
      command -v ffmpeg &>/dev/null || return 1
      # Use subshell to avoid pipefail issues with ffmpeg exit code
      [[ "$(ffmpeg -encoders 2>/dev/null)" == *libx264* ]] || return 1
      ;;
    software)
      gst-inspect-1.0 x264enc &>/dev/null || return 1
      ;;
    *)
      return 1
      ;;
  esac
  return 0
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
  ffmpeg)
    PLATFORM_DESC="FFmpeg libx264 (best motion quality)"
    MONITOR_CMD="htop"
    ;;
  software)
    PLATFORM_DESC="GStreamer x264 (high CPU)"
    MONITOR_CMD="htop"
    ;;
  *)
    echo "ERROR: No suitable encoder found."
    echo "Install one of:"
    echo "  FFmpeg:  sudo apt install ffmpeg (recommended for quality)"
    echo "  Jetson:  nvidia-l4t-gstreamer (usually pre-installed)"
    echo "  Intel:   sudo apt install gstreamer1.0-vaapi intel-media-va-driver vainfo"
    echo "  Fallback: sudo apt install gstreamer1.0-plugins-ugly"
    exit 1
    ;;
esac

# Config file (cameras defined here, credentials substituted at runtime)
CONF="${SCRIPT_DIR}/cameras.conf"
BASE="${RECORDING_BASE:-/home/paul/data/recordings}"
LOGS="${LOG_BASE:-/home/paul/data/logs}"

SEGMENT_SECONDS=600     # 10 minutes

# Hardware encoder settings (bitrate in bits/sec)
DEFAULT_BITRATE=8000000      # 8Mbps for 30fps
HIGH_BITRATE=12000000        # 12Mbps for 60fps

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
  local encoder_override="${5:-}"

  # Expand credentials in URL
  local url
  url=$(expand_url "$url_template")

  local outdir="${BASE}/${name}"
  mkdir -p "$outdir"

  local logfile="${LOGS}/${name}.log"

  # Check if already running for this camera (check both gst-launch and ffmpeg)
  if pgrep -af "gst-launch|ffmpeg" | grep -F -- "/${name}/" >/dev/null 2>&1; then
    log_msg "Already running: ${name}"
    return 0
  fi

  # Determine effective encoder: use override if valid, otherwise use platform default
  local effective_encoder="$PLATFORM"
  local encoder_desc="$PLATFORM_DESC"

  if [[ -n "$encoder_override" ]]; then
    case "$encoder_override" in
      jetson|vaapi|ffmpeg|software)
        if check_encoder_available "$encoder_override"; then
          effective_encoder="$encoder_override"
          case "$encoder_override" in
            jetson)   encoder_desc="Jetson NVENC (override)" ;;
            vaapi)    encoder_desc="VA-API (override)" ;;
            ffmpeg)   encoder_desc="FFmpeg libx264 (override)" ;;
            software) encoder_desc="GStreamer x264 (override)" ;;
          esac
          log_debug "${name}: Using encoder override '${encoder_override}'"
        else
          log_msg "WARNING: Encoder '${encoder_override}' not available for ${name}, falling back to ${PLATFORM_DESC}"
        fi
        ;;
      *)
        log_msg "WARNING: Invalid encoder '${encoder_override}' for ${name}, using ${PLATFORM_DESC}"
        ;;
    esac
  fi

  # Calculate GOP size (0.5 seconds of frames for better fast-motion handling)
  # Shorter GOP = more keyframes = better quality for sports/action but slightly larger files
  local gop_size=$((fps / 2))
  [[ $gop_size -lt 1 ]] && gop_size=1  # Minimum 1 frame
  local bitrate_kbps=$((bitrate/1000))

  log_msg "Starting ${name} (${encoder_desc} @ ${fps}fps, ${bitrate_kbps}kbps, GOP=${gop_size})..."
  log_debug "${name}: Output dir: ${outdir}"
  log_debug "${name}: Log file: ${logfile}"

  # Generate timestamp for this recording session
  local timestamp=$(date +%Y%m%d_%H%M%S)

  # FFmpeg encoder uses a completely different pipeline
  if [[ "$effective_encoder" == "ffmpeg" ]]; then
    log_debug "${name}: Launching FFmpeg encoder..."
    # FFmpeg with libx264 - best quality for fast motion
    # -preset medium: good balance of quality and speed (slower = better quality)
    # -tune film: optimized for high-quality video content
    # -crf 18: high quality (lower = better, 18 is visually lossless)
    # -maxrate/bufsize: constrain to target bitrate for consistent file sizes
    # -g: GOP size (keyframe interval)
    # -bf 0: no B-frames (better for fast motion)
    # -refs 4: more reference frames for better motion prediction
    # -segment_time: split into segments

    # Log the start to the camera log file
    echo "" >> "$logfile"
    echo "=== FFmpeg started at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$logfile"
    echo "URL: ${url//:*@/:***@}" >> "$logfile"  # Mask password in log
    echo "Output: ${outdir}/${name}_%Y%m%d_%H%M%S.mkv" >> "$logfile"
    echo "Settings: crf=18, preset=medium, gop=${gop_size}, maxrate=${bitrate_kbps}k" >> "$logfile"
    echo "================================================" >> "$logfile"

    nohup ffmpeg -hide_banner -y \
      -rtsp_transport tcp \
      -i "${url}" \
      -c:v libx264 \
      -preset medium \
      -tune film \
      -crf 18 \
      -maxrate "${bitrate_kbps}k" \
      -bufsize "$((bitrate_kbps * 2))k" \
      -g "${gop_size}" \
      -bf 0 \
      -refs 4 \
      -c:a aac -b:a 128k \
      -f segment \
      -segment_time "${SEGMENT_SECONDS}" \
      -segment_format matroska \
      -reset_timestamps 1 \
      -strftime 1 \
      "${outdir}/${name}_%Y%m%d_%H%M%S.mkv" \
      >> "$logfile" 2>&1 &
  else
    # GStreamer-based encoders (jetson, vaapi, software)
    # Build encoder-specific encode pipeline
    # Motion-optimized settings: no B-frames, shorter GOP, VBR rate control
    local encode_pipeline
    case "$effective_encoder" in
      jetson)
        # NVIDIA Jetson hardware encoding
        # maxperf-enable: max quality mode, num-B-Frames=0: disable B-frames for motion
        encode_pipeline="nvv4l2decoder ! nvv4l2h264enc bitrate=${bitrate} iframeinterval=${gop_size} maxperf-enable=true num-B-Frames=0"
        ;;
      vaapi)
        # Intel/AMD VA-API hardware encoding
        # Note: vaapi uses kbps for bitrate
        # max-bframes=0: disable B-frames (critical for fast motion)
        # rate-control=vbr: variable bitrate allows more bits for complex motion
        # quality-level=2: higher quality (1=best, 7=fastest)
        encode_pipeline="vaapidecodebin ! vaapih264enc bitrate=${bitrate_kbps} keyframe-period=${gop_size} max-bframes=0 rate-control=vbr quality-level=2"
        ;;
      software)
        # GStreamer x264 encoding (high CPU usage)
        # bframes=0: disable B-frames for motion, ref=4: more reference frames
        encode_pipeline="avdec_h264 ! x264enc bitrate=${bitrate_kbps} key-int-max=${gop_size} bframes=0 ref=4 speed-preset=superfast"
        ;;
    esac

    log_debug "${name}: Launching GStreamer encoder (${effective_encoder})..."

    # Log the start to the camera log file
    echo "" >> "$logfile"
    echo "=== GStreamer started at $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$logfile"
    echo "URL: ${url//:*@/:***@}" >> "$logfile"  # Mask password in log
    echo "Encoder: ${effective_encoder}" >> "$logfile"
    echo "Output: ${outdir}/${name}_${timestamp}_%05d.mkv" >> "$logfile"
    echo "Settings: gop=${gop_size}, bitrate=${bitrate_kbps}kbps" >> "$logfile"
    echo "==================================================" >> "$logfile"

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
  fi

  local pid=$!
  log_msg "${name}: Started with PID ${pid}"

  # Save PID for easier management
  echo "${pid}" > "/tmp/camera_${name}.pid"

  # Brief delay to check if process started successfully
  sleep 0.5
  if ! kill -0 "$pid" 2>/dev/null; then
    log_msg "ERROR: ${name} failed to start (PID ${pid} died immediately)"
    log_msg "Check log file: ${logfile}"
    rm -f "/tmp/camera_${name}.pid"
    return 1
  fi
}

stop_one () {
  local name="$1"
  local pidfile="/tmp/camera_${name}.pid"

  if [[ -f "$pidfile" ]]; then
    local pid=$(cat "$pidfile")
    if kill -0 "$pid" 2>/dev/null; then
      log_msg "Stopping ${name} (PID: ${pid})..."
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
  echo "Recording processes:"
  pgrep -af "gst-launch.*recordings|ffmpeg.*recordings" || echo "  (none)"
  echo ""
}

stop_all () {
  log_msg "Stopping all camera recordings..."

  # Graceful shutdown (both gst-launch and ffmpeg)
  pkill -INT -f "gst-launch.*recordings" 2>/dev/null || true
  pkill -INT -f "ffmpeg.*recordings" 2>/dev/null || true
  sleep 2

  # Force if needed
  if pgrep -af "gst-launch.*recordings|ffmpeg.*recordings" >/dev/null 2>&1; then
    log_msg "Processes still running, sending TERM..."
    pkill -TERM -f "gst-launch.*recordings" 2>/dev/null || true
    pkill -TERM -f "ffmpeg.*recordings" 2>/dev/null || true
    sleep 2
  fi

  if pgrep -af "gst-launch.*recordings|ffmpeg.*recordings" >/dev/null 2>&1; then
    log_msg "Force killing remaining processes..."
    pkill -9 -f "gst-launch.*recordings" 2>/dev/null || true
    pkill -9 -f "ffmpeg.*recordings" 2>/dev/null || true
  fi

  # Clean up PID files
  rm -f /tmp/camera_*.pid

  log_msg "All recordings stopped."
}

start_all () {
  # Create output directories
  mkdir -p "$BASE" "$LOGS"

  log_msg "Recording base: ${BASE}"
  log_msg "Log directory: ${LOGS}"
  log_msg "Platform: ${PLATFORM_DESC}"

  if [[ ! -f "$CONF" ]]; then
    log_msg "ERROR: Config file not found: $CONF"
    echo ""
    echo "Create it with format:"
    echo "  name|rtsp_url|fps|bitrate|encoder"
    echo ""
    echo "The encoder field is optional (jetson, vaapi, ffmpeg, software)."
    echo "If omitted, uses auto-detected encoder (prefers ffmpeg for quality)."
    exit 1
  fi

  log_msg "Loading cameras from: ${CONF}"

  # Read config lines: name|url|fps|bitrate|encoder
  while IFS='|' read -r name url fps bitrate encoder; do
    # Skip empty lines and comments
    [[ -z "${name// }" ]] && continue
    [[ "$name" =~ ^# ]] && continue
    [[ -z "${url// }" ]] && continue

    # Use defaults if not specified
    fps="${fps:-30}"
    bitrate="${bitrate:-$DEFAULT_BITRATE}"

    start_one "$name" "$url" "$fps" "$bitrate" "$encoder"
  done < "$CONF"

  sleep 2
  show_status

  log_msg "Monitor with: ${MONITOR_CMD}"
  log_msg "Check logs in: ${LOGS}/"
}

# =============================================================================
# Daemon mode - monitor and restart crashed recordings
# =============================================================================

MONITOR_INTERVAL=30  # seconds between health checks

monitor_and_restart() {
  log_msg "Starting daemon mode - monitoring recordings..."
  log_msg "Monitor interval: ${MONITOR_INTERVAL}s"
  echo "Press Ctrl+C to stop"

  # Trap SIGTERM/SIGINT for graceful shutdown
  trap 'log_msg "Shutting down..."; stop_all; exit 0' SIGTERM SIGINT

  # Initial start
  start_all

  while true; do
    sleep "$MONITOR_INTERVAL"

    # Check each camera from config
    while IFS='|' read -r name url fps bitrate encoder; do
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
          log_msg "${name} died (PID ${pid}), restarting..."
          rm -f "$pidfile"
          needs_restart=true
        fi
      else
        log_msg "${name} not running, starting..."
        needs_restart=true
      fi

      if [[ "$needs_restart" == "true" ]]; then
        start_one "$name" "$url" "$fps" "$bitrate" "$encoder"
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
    echo "Global override: ENCODER_PLATFORM=jetson|vaapi|ffmpeg|software $0 start"
    echo ""
    echo "Per-camera override: Add 5th field to cameras.conf"
    echo "  Format: name|url|fps|bitrate|encoder"
    echo "  Valid encoders: jetson, vaapi, ffmpeg, software"
    echo ""
    echo "Encoder notes:"
    echo "  ffmpeg   - Best quality for fast motion (recommended)"
    echo "  jetson   - NVIDIA Jetson hardware encoding"
    echo "  vaapi    - Intel/AMD hardware encoding"
    echo "  software - GStreamer x264 (fallback)"
    echo ""
    echo "Debug mode: DEBUG=1 $0 start"
    echo "  Shows detailed platform detection and encoder selection"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|daemon|info}"
    echo ""
    echo "  start   - Start recording all cameras in config"
    echo "  stop    - Stop all recordings gracefully"
    echo "  restart - Stop then start all recordings"
    echo "  status  - Show running recordings"
    echo "  daemon  - Run in foreground, monitor and auto-restart crashed recordings"
    echo "  info    - Show detected platform and encoder info"
    echo ""
    echo "Config format: name|rtsp_url|fps|bitrate|encoder"
    echo "  The encoder field is optional (jetson, vaapi, ffmpeg, software)."
    echo "  If omitted, uses auto-detected encoder (prefers ffmpeg for quality)."
    exit 1
    ;;
esac
