#!/bin/bash
# Start auto-tracking for ski racing on J40
#
# Usage:
#   ./start_auto_tracker.sh                                    # default config
#   ./start_auto_tracker.sh --config my_course.json            # custom course
#   ./start_auto_tracker.sh --debug                            # live preview
#   ./start_auto_tracker.sh --dry-run                          # no PTZ commands
#   ./start_auto_tracker.sh --output rtmp://server/live/key    # stream output
#   ./start_auto_tracker.sh --record output.mp4                # record to file
#   ./start_auto_tracker.sh --source test_video.mp4            # test with video
#
# The tracker:
#   1. Connects to Axis PTZ camera via RTSP + VAPIX API
#   2. Runs YOLO person detection (TensorRT on Jetson GPU)
#   3. Drives PTZ to follow the racer down the course
#   4. Applies digital stabilization for smooth output
#   5. Starts tracking when racer leaves the start gate trigger zone

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Ski Racer Auto-Tracking System                    ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"

if ! python3 -c "import cv2" 2>/dev/null; then
    echo -e "${RED}OpenCV not found. Install with: pip3 install opencv-python${NC}"
    exit 1
fi

if ! python3 -c "from ultralytics import YOLO" 2>/dev/null; then
    echo -e "${RED}ultralytics not found. Install with: pip3 install ultralytics${NC}"
    exit 1
fi

if ! python3 -c "import requests" 2>/dev/null; then
    echo -e "${RED}requests not found. Install with: pip3 install requests${NC}"
    exit 1
fi

if ! python3 -c "import numpy" 2>/dev/null; then
    echo -e "${RED}numpy not found. Install with: pip3 install numpy${NC}"
    exit 1
fi

echo -e "${GREEN}All dependencies OK${NC}"
echo ""

# Check if credentials exist
if [[ ! -f "$SCRIPT_DIR/credentials.local" ]]; then
    echo -e "${RED}credentials.local not found${NC}"
    echo "Copy credentials.template and fill in AXIS_USER and AXIS_PASS"
    exit 1
fi

# Check for config file
CONFIG="${SCRIPT_DIR}/course_config.json"
for arg in "$@"; do
    if [[ "$prev_arg" == "--config" ]]; then
        CONFIG="$arg"
        break
    fi
    prev_arg="$arg"
done

if [[ ! -f "$CONFIG" ]]; then
    echo -e "${RED}Config file not found: $CONFIG${NC}"
    echo "Run calibrate_course.py first to map your course, or specify with --config"
    exit 1
fi

# Check for YOLO model
MODEL_PATH=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c.get('model', {}).get('path', 'yolov8n.pt'))
" 2>/dev/null)

if [[ -n "$MODEL_PATH" && ! -f "$MODEL_PATH" && ! -f "$SCRIPT_DIR/$MODEL_PATH" ]]; then
    echo -e "${YELLOW}YOLO model not found: $MODEL_PATH${NC}"
    echo "Downloading yolov8n.pt..."
    python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt')" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Model downloaded${NC}"
        echo ""
        echo -e "${YELLOW}For best performance on Jetson, export to TensorRT:${NC}"
        echo "  python3 -c \"from ultralytics import YOLO; YOLO('yolov8n.pt').export(format='engine', half=True)\""
        echo ""
    else
        echo -e "${RED}Failed to download model${NC}"
        exit 1
    fi
fi

# Show config info
COURSE_NAME=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c.get('course_name', 'unnamed'))
" 2>/dev/null)

NUM_GATES=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(len(c.get('gates', [])))
" 2>/dev/null)

echo -e "${BOLD}Starting auto-tracker...${NC}"
echo -e "  Config:  $CONFIG"
echo -e "  Course:  $COURSE_NAME"
echo -e "  Gates:   $NUM_GATES"
echo -e "  Model:   $MODEL_PATH"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

# Run the tracker
python3 "$SCRIPT_DIR/auto_tracker.py" --config "$CONFIG" "$@"
