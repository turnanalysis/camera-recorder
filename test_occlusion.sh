#!/bin/bash
# Test script for autotracker occlusion handling
# Usage:
#   ./test_occlusion.sh                    # Run with default MKV video
#   ./test_occlusion.sh g10_d001.mp4       # Run with specific clip
#   ./test_occlusion.sh --record           # Record output to test_output.mp4

cd "$(dirname "$0")"

VIDEO_DIR="../videos-examples"
DEFAULT_VIDEO="20260125_100223_8E8E.mkv"
CONFIG="course_config_test.json"
RECORD_FLAG=""

# Parse arguments
VIDEO="$DEFAULT_VIDEO"
for arg in "$@"; do
    case $arg in
        --record)
            RECORD_FLAG="--record test_output_$(date +%H%M%S).mp4"
            ;;
        *.mp4|*.mkv|*.mov)
            VIDEO="$arg"
            ;;
    esac
done

VIDEO_PATH="$VIDEO_DIR/$VIDEO"

if [ ! -f "$VIDEO_PATH" ]; then
    echo "Video not found: $VIDEO_PATH"
    echo "Available videos:"
    ls -1 "$VIDEO_DIR"
    exit 1
fi

echo "=============================================="
echo "Autotracker Occlusion Test"
echo "=============================================="
echo "Video:  $VIDEO"
echo "Config: $CONFIG"
echo ""
echo "Controls:"
echo "  SPACE  - Manual start trigger (bypass waiting)"
echo "  R      - Reset to WAITING state"
echo "  ESC    - Exit"
echo ""
echo "Watch for:"
echo "  - Kalman prediction (yellow bbox) during occlusion"
echo "  - STATE: TRACKING -> OCCLUDED -> TRACKING transitions"
echo "  - Velocity/speed shown in debug overlay"
echo "=============================================="
echo ""

# Check if YOLO model exists
if [ ! -f "yolov8n.pt" ]; then
    echo "Downloading YOLOv8n model..."
    python3 -c "from ultralytics import YOLO; YOLO('yolov8n.pt')"
fi

# Run the tracker
python3 auto_tracker.py \
    --config "$CONFIG" \
    --source "$VIDEO_PATH" \
    --debug \
    --dry-run \
    $RECORD_FLAG
