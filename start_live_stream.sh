#!/bin/bash

# Flying Yankee Live Streaming Script - Multi-Quality Version
# Usage: ./start_live_stream.sh [quality] [camera_ip]
# Quality options: low, medium, high, ultra, adaptive, passthrough
# Other commands: test, status

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load credentials from config file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.local"

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "Error: credentials.local not found at $CREDENTIALS_FILE"
    echo "Copy credentials.template to credentials.local and fill in your values:"
    echo "  cp credentials.template credentials.local"
    exit 1
fi

source "$CREDENTIALS_FILE"

# Validate required credentials
if [[ -z "$CAMERA_USER" || -z "$CAMERA_PASS" || -z "$RTMP_URL" ]]; then
    echo "Error: Missing required credentials in $CREDENTIALS_FILE"
    echo "Required: CAMERA_USER, CAMERA_PASS, RTMP_URL"
    exit 1
fi

# Camera settings - from config or defaults
PRIMARY_CAMERA="${PRIMARY_CAMERA:-192.168.0.101}"
FALLBACK_CAMERA="${FALLBACK_CAMERA:-192.168.0.103}"
CAMERA_IP="${2:-}"  # Will be auto-detected if not provided

# Quality preset (default: adaptive)
QUALITY="${1:-adaptive}"

# Adaptive mode settings
ADAPTIVE_CHECK_INTERVAL=60  # seconds between bandwidth checks
ADAPTIVE_DROP_THRESHOLD=70  # % of target bitrate that triggers downgrade
ADAPTIVE_RAISE_THRESHOLD=120 # % of target bitrate that allows upgrade

# Live status check - only stream when enabled on skiframes.com
LIVE_CONFIG_URL="https://media.skiframes.com/config/live-banner.json"
LIVE_CHECK_INTERVAL=60  # seconds between live status checks

# Bandwidth test server (uses Cloudflare's speed test)
SPEEDTEST_UPLOAD_URL="https://speed.cloudflare.com/__up"
SPEEDTEST_SIZE=1000000  # 1MB test file (reduced for lower data usage)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Log file for adaptive mode
LOG_FILE="/tmp/flyingyankee_stream.log"

# =============================================================================
# LIVE STATUS CHECK
# =============================================================================

check_live_enabled() {
    # Check if live streaming is enabled on skiframes.com
    # Returns 0 (true) if enabled, 1 (false) if disabled
    local config
    config=$(curl -s --max-time 10 "${LIVE_CONFIG_URL}?t=$(date +%s)" 2>/dev/null)

    if [[ -z "$config" ]]; then
        echo -e "${RED}Could not fetch live config - assuming disabled${NC}" >&2
        return 1
    fi

    # Parse JSON to check enabled field
    local enabled
    enabled=$(echo "$config" | grep -o '"enabled"[[:space:]]*:[[:space:]]*true' | head -1)

    if [[ -n "$enabled" ]]; then
        return 0  # Live is enabled
    else
        return 1  # Live is disabled
    fi
}

wait_for_live_enabled() {
    # Wait until live streaming is enabled, checking every LIVE_CHECK_INTERVAL seconds
    echo -e "${YELLOW}Live streaming is disabled on skiframes.com${NC}"
    echo -e "${YELLOW}Waiting for live to be enabled (checking every ${LIVE_CHECK_INTERVAL}s)...${NC}"
    echo ""

    while true; do
        if check_live_enabled; then
            echo ""
            echo -e "${GREEN}✓ Live streaming is now ENABLED!${NC}"
            return 0
        fi

        local timestamp=$(date '+%H:%M:%S')
        echo -e "${BLUE}[$timestamp]${NC} Live still disabled, waiting..."
        sleep "$LIVE_CHECK_INTERVAL"
    done
}

# =============================================================================
# CAMERA AUTO-DETECTION
# =============================================================================

detect_camera() {
    # If camera IP was provided as argument, use it
    if [[ -n "$CAMERA_IP" ]]; then
        echo "$CAMERA_IP"
        return
    fi
    
    # Try primary camera first
    echo -e "${YELLOW}Checking primary camera ($PRIMARY_CAMERA)...${NC}" >&2
    if ping -c 1 -W 2 "$PRIMARY_CAMERA" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Primary camera reachable${NC}" >&2
        echo "$PRIMARY_CAMERA"
        return
    fi
    
    # Try fallback camera
    echo -e "${YELLOW}Primary not found, trying fallback ($FALLBACK_CAMERA)...${NC}" >&2
    if ping -c 1 -W 2 "$FALLBACK_CAMERA" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Fallback camera reachable${NC}" >&2
        echo "$FALLBACK_CAMERA"
        return
    fi
    
    # Neither camera found
    echo ""
}

# =============================================================================
# QUALITY PRESETS
# =============================================================================

# Arrays to store preset info for adaptive mode
declare -A PRESET_BITRATE
PRESET_BITRATE[low]=400
PRESET_BITRATE[medium]=1200
PRESET_BITRATE[high]=3500
PRESET_BITRATE[ultra]=7000

PRESET_ORDER=("low" "medium" "high")

set_quality_preset() {
    case "$1" in
        low)
            # Low bandwidth / mobile fallback
            # ~500 Kbps total, good for poor LTE
            STREAM_PATH="h264Preview_01_sub"
            VIDEO_BITRATE="400k"
            MAX_BITRATE="500k"
            BUFFER_SIZE="1000k"
            FRAME_RATE="10"
            KEYINT="20"
            PROFILE="baseline"
            LEVEL="3.0"
            PRESET="ultrafast"
            SCALE=""
            AUDIO_BITRATE="64k"
            TOTAL_BITRATE_KBPS=500
            DESC="Low (sub-stream, 400kbps, 10fps) - For poor connectivity"
            ;;
        medium)
            # Balanced quality / bandwidth
            # ~1.5 Mbps total, good for stable LTE
            STREAM_PATH="h264Preview_01_main"
            VIDEO_BITRATE="1200k"
            MAX_BITRATE="1500k"
            BUFFER_SIZE="3000k"
            FRAME_RATE="15"
            KEYINT="30"
            PROFILE="main"
            LEVEL="3.1"
            PRESET="fast"
            SCALE="-vf scale=1280:720"
            AUDIO_BITRATE="96k"
            TOTAL_BITRATE_KBPS=1500
            DESC="Medium (720p, 1.2Mbps, 15fps) - Balanced quality"
            ;;
        high)
            # High quality
            # ~4 Mbps total, needs good WiFi or wired
            STREAM_PATH="h264Preview_01_main"
            VIDEO_BITRATE="3500k"
            MAX_BITRATE="4000k"
            BUFFER_SIZE="8000k"
            FRAME_RATE="25"
            KEYINT="50"
            PROFILE="high"
            LEVEL="4.0"
            PRESET="fast"
            SCALE="-vf scale=1920:1080"
            AUDIO_BITRATE="128k"
            TOTAL_BITRATE_KBPS=4500
            DESC="High (1080p, 3.5Mbps, 25fps) - High quality"
            ;;
        ultra)
            # Maximum quality - native resolution
            # ~8 Mbps total, needs excellent connection
            STREAM_PATH="h264Preview_01_main"
            VIDEO_BITRATE="7000k"
            MAX_BITRATE="8000k"
            BUFFER_SIZE="16000k"
            FRAME_RATE="30"
            KEYINT="60"
            PROFILE="high"
            LEVEL="4.1"
            PRESET="medium"
            SCALE=""  # No scaling - use native resolution
            AUDIO_BITRATE="128k"
            TOTAL_BITRATE_KBPS=8500
            DESC="Ultra (native res, 7Mbps, 30fps) - Maximum quality"
            ;;
        passthrough)
            # Direct passthrough - no re-encoding
            # Lowest CPU, highest quality, bandwidth depends on camera settings
            STREAM_PATH="h264Preview_01_main"
            PASSTHROUGH="yes"
            DESC="Passthrough (no re-encode) - Lowest latency"
            ;;
        adaptive)
            # Will be set dynamically
            DESC="Adaptive (auto-adjusts based on bandwidth)"
            ;;
        *)
            echo -e "${RED}Unknown quality preset: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# =============================================================================
# BANDWIDTH TEST
# =============================================================================

run_bandwidth_test() {
    local test_size=${1:-$SPEEDTEST_SIZE}
    local silent=${2:-false}
    
    if [[ "$silent" != "true" ]]; then
        echo -e "${YELLOW}Running bandwidth test...${NC}"
        echo -e "  Uploading ${test_size} bytes to Cloudflare..."
    fi
    
    # Generate random data and upload, measuring time
    local start_time=$(date +%s.%N)
    
    # Use dd to generate random data and curl to upload
    local result=$(dd if=/dev/urandom bs=$test_size count=1 2>/dev/null | \
        curl -X POST -s -w "%{time_total}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @- \
        "$SPEEDTEST_UPLOAD_URL" 2>/dev/null)
    
    local elapsed=$result
    
    # Calculate speed in Kbps
    if [[ -n "$elapsed" && "$elapsed" != "0" ]]; then
        local speed_kbps=$(echo "scale=0; ($test_size * 8) / ($elapsed * 1000)" | bc 2>/dev/null)
        local speed_mbps=$(echo "scale=2; $speed_kbps / 1000" | bc 2>/dev/null)
        
        if [[ "$silent" != "true" ]]; then
            echo ""
            echo -e "${BOLD}Upload Speed:${NC} ${GREEN}${speed_mbps} Mbps${NC} (${speed_kbps} Kbps)"
            echo ""
            recommend_quality "$speed_kbps"
        fi
        
        echo "$speed_kbps"
    else
        if [[ "$silent" != "true" ]]; then
            echo -e "${RED}Bandwidth test failed${NC}"
        fi
        echo "0"
    fi
}

recommend_quality() {
    local speed_kbps=$1
    
    echo -e "${BOLD}Recommended Quality:${NC}"
    
    if (( speed_kbps >= 12000 )); then
        echo -e "  ${GREEN}● ultra${NC}  - You have plenty of bandwidth (${speed_kbps} Kbps)"
        echo -e "  ${GREEN}● high${NC}   - Recommended for stability"
    elif (( speed_kbps >= 6000 )); then
        echo -e "  ${GREEN}● high${NC}   - Good fit for your bandwidth (${speed_kbps} Kbps)"
        echo -e "  ${YELLOW}● ultra${NC}  - Might work but risky"
    elif (( speed_kbps >= 2500 )); then
        echo -e "  ${GREEN}● medium${NC} - Safe choice for your bandwidth (${speed_kbps} Kbps)"
        echo -e "  ${YELLOW}● high${NC}   - Possible but monitor closely"
    elif (( speed_kbps >= 800 )); then
        echo -e "  ${GREEN}● low${NC}    - Best for your bandwidth (${speed_kbps} Kbps)"
        echo -e "  ${YELLOW}● medium${NC} - Might work with some buffering"
    else
        echo -e "  ${RED}● low${NC}    - Only option at ${speed_kbps} Kbps"
        echo -e "  ${RED}  Warning: Connection may be too slow for streaming${NC}"
    fi
    echo ""
}

quick_bandwidth_check() {
    # Quick 250KB test for adaptive mode checks (reduced for lower data usage)
    local result=$(dd if=/dev/urandom bs=250000 count=1 2>/dev/null | \
        curl -X POST -s -w "%{time_total}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @- \
        "$SPEEDTEST_UPLOAD_URL" 2>/dev/null)
    
    if [[ -n "$result" && "$result" != "0" ]]; then
        echo "scale=0; (250000 * 8) / ($result * 1000)" | bc 2>/dev/null
    else
        echo "0"
    fi
}

# =============================================================================
# ADAPTIVE STREAMING
# =============================================================================

get_preset_index() {
    local preset=$1
    for i in "${!PRESET_ORDER[@]}"; do
        if [[ "${PRESET_ORDER[$i]}" == "$preset" ]]; then
            echo "$i"
            return
        fi
    done
    echo "1"  # default to medium
}

adaptive_stream() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         ADAPTIVE STREAMING MODE                            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Create control pipe for communication
    local control_pipe="/tmp/stream_control_$$"
    mkfifo "$control_pipe" 2>/dev/null

    # Trap to cleanup on exit
    trap "rm -f $control_pipe; kill 0 2>/dev/null" EXIT

    # Outer loop - handles live enable/disable cycling
    while true; do
        # Check if live is enabled before starting
        if ! check_live_enabled; then
            wait_for_live_enabled
        fi

        echo -e "${GREEN}Live is enabled - starting stream...${NC}"
        echo ""

        # Initial bandwidth test
        echo -e "${YELLOW}Running initial bandwidth test to determine starting quality...${NC}"
        local initial_speed=$(run_bandwidth_test 2000000 true)

        # Determine starting quality
        local current_preset="medium"
        if (( initial_speed >= 6000 )); then
            current_preset="high"
        elif (( initial_speed >= 2500 )); then
            current_preset="medium"
        else
            current_preset="low"
        fi

        echo -e "${GREEN}Initial bandwidth: ${initial_speed} Kbps${NC}"
        echo -e "${GREEN}Starting with: ${current_preset}${NC}"
        echo ""

        local live_disabled=false

        # Quality adaptation loop
        while [[ "$live_disabled" == "false" ]]; do
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${BOLD}Starting stream at ${CYAN}${current_preset}${NC} quality${NC}"
            echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            # Set quality preset
            set_quality_preset "$current_preset"

            # Build RTSP URL
            local rtsp_url="rtsp://${CAMERA_USER}:${CAMERA_PASS}@${CAMERA_IP}:554/${STREAM_PATH}"

            # Start ffmpeg in background
            ffmpeg -rtsp_transport tcp \
                -fflags +genpts+igndts \
                -use_wallclock_as_timestamps 1 \
                -i "$rtsp_url" \
                -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 \
                -c:v libx264 -preset $PRESET \
                -profile:v $PROFILE -level $LEVEL \
                -pix_fmt yuv420p \
                -x264-params "keyint=${KEYINT}:min-keyint=${KEYINT}" \
                -b:v $VIDEO_BITRATE -maxrate $MAX_BITRATE -bufsize $BUFFER_SIZE \
                -vsync cfr \
                -r $FRAME_RATE \
                $SCALE \
                -c:a aac -b:a $AUDIO_BITRATE \
                -map 0:v:0 -map 1:a:0 \
                -shortest \
                -f flv \
                "$RTMP_URL" 2>&1 &

            local ffmpeg_pid=$!
            echo -e "${GREEN}Stream started (PID: $ffmpeg_pid)${NC}"
            echo ""

            # Monitor loop
            local check_count=0
            local consecutive_low=0
            local consecutive_high=0

            while kill -0 $ffmpeg_pid 2>/dev/null; do
                sleep $ADAPTIVE_CHECK_INTERVAL
                ((check_count++))

                # Check if live is still enabled
                if ! check_live_enabled; then
                    echo ""
                    echo -e "${RED}⚠ Live streaming DISABLED on skiframes.com${NC}"
                    echo -e "${YELLOW}Stopping stream to save data...${NC}"

                    # Kill current stream
                    kill $ffmpeg_pid 2>/dev/null
                    wait $ffmpeg_pid 2>/dev/null

                    live_disabled=true
                    break  # Break monitor loop
                fi

                # Quick bandwidth check
                local current_speed=$(quick_bandwidth_check)
            local target_speed=${PRESET_BITRATE[$current_preset]}
            local ratio=0
            
            if (( target_speed > 0 )); then
                ratio=$(( (current_speed * 100) / target_speed ))
            fi
            
            local timestamp=$(date '+%H:%M:%S')
            echo -e "${BLUE}[$timestamp]${NC} Bandwidth: ${current_speed} Kbps | Target: ${target_speed} Kbps | Ratio: ${ratio}%"
            
            # Check if we need to adjust quality
            if (( ratio < ADAPTIVE_DROP_THRESHOLD )); then
                ((consecutive_low++))
                consecutive_high=0
                
                if (( consecutive_low >= 2 )); then
                    # Need to drop quality
                    local current_index=$(get_preset_index "$current_preset")
                    if (( current_index > 0 )); then
                        local new_preset="${PRESET_ORDER[$((current_index - 1))]}"
                        echo ""
                        echo -e "${RED}⚠ Bandwidth too low! Dropping from ${current_preset} to ${new_preset}${NC}"
                        
                        # Kill current stream
                        kill $ffmpeg_pid 2>/dev/null
                        wait $ffmpeg_pid 2>/dev/null
                        
                        current_preset=$new_preset
                        consecutive_low=0
                        sleep 2
                        break  # Restart with new quality
                    else
                        echo -e "${RED}  Already at lowest quality${NC}"
                    fi
                fi
            elif (( ratio > ADAPTIVE_RAISE_THRESHOLD )); then
                ((consecutive_high++))
                consecutive_low=0
                
                if (( consecutive_high >= 4 )); then
                    # Can raise quality
                    local current_index=$(get_preset_index "$current_preset")
                    if (( current_index < ${#PRESET_ORDER[@]} - 1 )); then
                        local new_preset="${PRESET_ORDER[$((current_index + 1))]}"
                        echo ""
                        echo -e "${GREEN}✓ Bandwidth stable! Upgrading from ${current_preset} to ${new_preset}${NC}"
                        
                        # Kill current stream
                        kill $ffmpeg_pid 2>/dev/null
                        wait $ffmpeg_pid 2>/dev/null
                        
                        current_preset=$new_preset
                        consecutive_high=0
                        sleep 2
                        break  # Restart with new quality
                    else
                        echo -e "${GREEN}  Already at highest quality${NC}"
                        consecutive_high=0
                    fi
                fi
            else
                consecutive_low=0
                consecutive_high=0
            fi
        done

            # Check if ffmpeg exited on its own (error) - skip if live was disabled
            if [[ "$live_disabled" == "false" ]] && ! kill -0 $ffmpeg_pid 2>/dev/null; then
                wait $ffmpeg_pid
                local exit_code=$?
                if (( exit_code != 0 )); then
                    echo -e "${RED}Stream crashed (exit code: $exit_code)${NC}"
                    echo -e "${YELLOW}Restarting in 5 seconds...${NC}"
                    sleep 5
                fi
            fi
        done  # End quality adaptation loop

        # If we get here because live was disabled, loop back to check live status
        echo ""
    done  # End outer live check loop
}

# =============================================================================
# HELP / USAGE
# =============================================================================

show_help() {
    echo -e "${BOLD}Flying Yankee Live Streaming Script${NC}"
    echo ""
    echo -e "${BOLD}Usage:${NC}"
    echo "  $0 [quality] [camera_ip]"
    echo "  $0 test                    # Run bandwidth test"
    echo ""
    echo -e "${BOLD}Camera Auto-Detection:${NC}"
    echo "  Primary:    $PRIMARY_CAMERA"
    echo "  Fallback:   $FALLBACK_CAMERA"
    echo "  (Automatically uses fallback if primary is unreachable)"
    echo ""
    echo -e "${BOLD}Quality Presets:${NC}"
    echo -e "  ${CYAN}adaptive${NC}    Auto-adjusts quality        - ${GREEN}DEFAULT / RACE DAY${NC}"
    echo -e "  ${CYAN}low${NC}         Sub-stream, 400kbps, 10fps  - For poor LTE/mobile"
    echo -e "  ${CYAN}medium${NC}      720p, 1.2Mbps, 15fps        - Balanced"
    echo -e "  ${CYAN}high${NC}        1080p, 3.5Mbps, 25fps       - High quality"
    echo -e "  ${CYAN}ultra${NC}       Native, 7Mbps, 30fps        - Maximum quality"
    echo -e "  ${CYAN}passthrough${NC} No re-encode                - Direct copy"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo -e "  ${CYAN}test${NC}        Run upload bandwidth test"
    echo -e "  ${CYAN}help${NC}        Show this help"
    echo ""
    echo -e "${BOLD}Examples:${NC}"
    echo "  $0                      # Adaptive quality (default)"
    echo "  $0 high                 # Fixed high quality"
    echo "  $0 test                 # Test your upload speed"
    echo "  $0 medium 192.168.0.104 # Specific camera"
    echo ""
    echo -e "${BOLD}Bandwidth Requirements:${NC}"
    echo "  low:         ~0.5 Mbps upload"
    echo "  medium:      ~1.5 Mbps upload"
    echo "  high:        ~4.5 Mbps upload"
    echo "  ultra:       ~8.5 Mbps upload"
    echo ""
    echo -e "${BOLD}Race Day:${NC}"
    echo "  1. Run '$0 test' to check bandwidth"
    echo "  2. Run '$0' to start (adaptive is default)"
    echo ""
    echo -e "${BOLD}Stream URL:${NC}"
    echo "  https://live.flying-yankee.com/manifest.m3u8"
}

# =============================================================================
# MAIN SCRIPT
# =============================================================================

# Handle special commands
case "$1" in
    -h|--help|help)
        show_help
        exit 0
        ;;
    test|speedtest|bandwidth)
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║         Flying Yankee Bandwidth Test                       ║${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        run_bandwidth_test
        exit 0
        ;;
esac

# Handle adaptive mode (default)
if [[ "$QUALITY" == "adaptive" || "$QUALITY" == "auto" ]]; then
    # Auto-detect camera
    CAMERA_IP=$(detect_camera)
    if [[ -z "$CAMERA_IP" ]]; then
        echo -e "${RED}✗ No camera reachable${NC}"
        echo "  Tried: $PRIMARY_CAMERA (primary)"
        echo "  Tried: $FALLBACK_CAMERA (fallback)"
        exit 1
    fi
    echo -e "${GREEN}Using camera: $CAMERA_IP${NC}"
    echo ""
    adaptive_stream
    exit 0
fi

# Set quality preset for standard mode
set_quality_preset "$QUALITY"

# Header
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Flying Yankee Live Stream                          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show selected quality
echo -e "${BOLD}Quality Preset:${NC} ${CYAN}$QUALITY${NC}"
echo -e "${BOLD}Description:${NC}    $DESC"
echo ""

# Auto-detect camera if not specified
CAMERA_IP=$(detect_camera)
if [[ -z "$CAMERA_IP" ]]; then
    echo -e "${RED}✗ No camera reachable${NC}"
    echo "  Tried: $PRIMARY_CAMERA (primary)"
    echo "  Tried: $FALLBACK_CAMERA (fallback)"
    echo ""
    echo "  Specify camera IP manually:"
    echo "  $0 $QUALITY 192.168.0.XXX"
    exit 1
fi
echo -e "${GREEN}Using camera: $CAMERA_IP${NC}"

# Check if ffmpeg is installed
if ! command -v ffmpeg &> /dev/null; then
    echo -e "${RED}✗ ffmpeg not found${NC}"
    exit 1
fi

# Build RTSP URL
RTSP_URL="rtsp://${CAMERA_USER}:${CAMERA_PASS}@${CAMERA_IP}:554/${STREAM_PATH}"

echo ""
echo -e "${BOLD}Stream Configuration:${NC}"
echo -e "  Camera:     $CAMERA_IP (${STREAM_PATH})"
echo -e "  Output:     $RTMP_URL"
if [[ "$PASSTHROUGH" != "yes" ]]; then
    echo -e "  Video:      ${VIDEO_BITRATE} @ ${FRAME_RATE}fps (${PROFILE} profile)"
    echo -e "  Audio:      ${AUDIO_BITRATE} AAC"
    if [[ -n "$SCALE" ]]; then
        echo -e "  Resolution: Scaled (see -vf)"
    else
        echo -e "  Resolution: Native"
    fi
fi
echo ""
echo -e "${BOLD}Watch at:${NC} ${CYAN}https://live.flying-yankee.com/manifest.m3u8${NC}"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop streaming${NC}"
echo ""
echo -e "${GREEN}Starting stream...${NC}"
echo ""

# Build and run ffmpeg command
if [[ "$PASSTHROUGH" == "yes" ]]; then
    # Passthrough mode - no re-encoding
    ffmpeg -rtsp_transport tcp \
        -fflags +genpts+igndts \
        -use_wallclock_as_timestamps 1 \
        -i "$RTSP_URL" \
        -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 \
        -c:v copy \
        -c:a aac -b:a 128k \
        -map 0:v:0 -map 1:a:0 \
        -shortest \
        -f flv \
        "$RTMP_URL"
else
    # Re-encoding mode with quality settings
    ffmpeg -rtsp_transport tcp \
        -fflags +genpts+igndts \
        -use_wallclock_as_timestamps 1 \
        -i "$RTSP_URL" \
        -f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000 \
        -c:v libx264 -preset $PRESET \
        -profile:v $PROFILE -level $LEVEL \
        -pix_fmt yuv420p \
        -x264-params "keyint=${KEYINT}:min-keyint=${KEYINT}" \
        -b:v $VIDEO_BITRATE -maxrate $MAX_BITRATE -bufsize $BUFFER_SIZE \
        -vsync cfr \
        -r $FRAME_RATE \
        $SCALE \
        -c:a aac -b:a $AUDIO_BITRATE \
        -map 0:v:0 -map 1:a:0 \
        -shortest \
        -f flv \
        "$RTMP_URL"
fi

echo ""
echo -e "${RED}Stream stopped${NC}"
