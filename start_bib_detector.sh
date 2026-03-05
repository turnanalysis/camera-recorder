#!/bin/bash
# Start bib detection alongside the live stream on J40
#
# Usage:
#   ./start_bib_detector.sh                 # auto-detect camera, default zone
#   ./start_bib_detector.sh --show-zone     # preview detection zone and exit
#   ./start_bib_detector.sh --debug         # save debug frames
#   ./start_bib_detector.sh --zone 0.2,0.3,0.8,0.7   # custom crop zone
#
# The detector:
#   1. Grabs frames from the RTSP camera sub-stream every ~1.5s
#   2. Runs Tesseract OCR to detect bib numbers
#   3. Writes detected bib to /tmp/bib_detected.json
#   4. Uploads that JSON to S3 every 3s (only when changed)
#   5. The live page at skiframes.com/live polls the JSON to auto-update

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
echo -e "${CYAN}║         Bib Number Auto-Detection                          ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"

if ! python3 -c "import cv2" 2>/dev/null; then
    echo -e "${RED}OpenCV not found. Install with: pip3 install opencv-python${NC}"
    exit 1
fi

if ! python3 -c "import pytesseract" 2>/dev/null; then
    echo -e "${RED}pytesseract not found. Install with: pip3 install pytesseract${NC}"
    exit 1
fi

if ! command -v tesseract &>/dev/null; then
    echo -e "${RED}tesseract not found. Install with: sudo apt install tesseract-ocr${NC}"
    exit 1
fi

echo -e "${GREEN}All dependencies OK${NC}"
echo ""

# Check if credentials exist
if [[ ! -f "$SCRIPT_DIR/credentials.local" ]]; then
    echo -e "${RED}credentials.local not found${NC}"
    echo "Copy credentials.template and fill in camera credentials"
    exit 1
fi

# Run the detector with S3 upload enabled
echo -e "${BOLD}Starting bib detector...${NC}"
echo -e "  Output: /tmp/bib_detected.json"
echo -e "  S3:     s3://avillachlab-netm/config/bib-detected.json"
echo -e "  Live:   https://media.skiframes.com/config/bib-detected.json"
echo ""
echo -e "${YELLOW}Press Ctrl+C to stop${NC}"
echo ""

python3 "$SCRIPT_DIR/bib_detector.py" --upload --zone 0.05,0.02,0.22,0.28 --interval 0.5 "$@"
