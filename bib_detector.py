#!/usr/bin/env python3
"""
Real-time bib number detection from RTSP camera stream.
Runs on J40 (Jetson Orin NX) alongside the live stream.

Grabs frames from the RTSP camera, crops to a configurable "bib zone",
runs Tesseract OCR to detect numbers, and writes detected bibs to a JSON file
that gets uploaded to S3 for the live page to consume.

Usage:
    python3 bib_detector.py                    # auto-detect camera, use defaults
    python3 bib_detector.py --camera 192.168.0.101
    python3 bib_detector.py --debug            # save debug frames to /tmp/bib_debug/
    python3 bib_detector.py --show-zone        # capture one frame and show the crop zone
"""

import cv2
import pytesseract
import json
import time
import os
import re
import argparse
import subprocess
import signal
import sys
from datetime import datetime
from collections import Counter
from pathlib import Path

# =============================================================================
# CONFIGURATION
# =============================================================================

# RTSP stream path for Reolink (sub-stream = lower res, less CPU)
# Use sub-stream for detection (704x576) - plenty for bib numbers
RTSP_SUB_STREAM = "h264Preview_01_sub"
# Use main stream for higher accuracy if needed (3840x2160)
RTSP_MAIN_STREAM = "h264Preview_01_main"

# Detection zone: percentage crop of the frame where bibs are visible
# Adjust these based on camera angle and position
# Format: (x_start%, y_start%, x_end%, y_end%) as fractions 0.0-1.0
DEFAULT_ZONE = (0.15, 0.20, 0.85, 0.80)

# Detection settings
FRAME_INTERVAL = 1.5       # seconds between frame grabs
MIN_BIB = 1                # minimum valid bib number
MAX_BIB = 200              # maximum valid bib number
CONFIDENCE_WINDOW = 6      # number of recent detections to consider
CONFIDENCE_THRESHOLD = 3   # minimum times a bib must appear in window to be "confirmed"
NO_DETECTION_TIMEOUT = 10  # seconds with no detection before clearing current bib

# Output
OUTPUT_FILE = "/tmp/bib_detected.json"
DEBUG_DIR = "/tmp/bib_debug"

# =============================================================================
# CAMERA CREDENTIALS
# =============================================================================

def load_credentials():
    """Load camera credentials from credentials.local"""
    creds = {}
    cred_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "credentials.local")
    if os.path.exists(cred_file):
        with open(cred_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, val = line.split('=', 1)
                    creds[key.strip()] = val.strip().strip('"').strip("'")
    return creds

def detect_camera():
    """Auto-detect reachable camera IP"""
    for ip in ["192.168.0.101", "192.168.0.103", "192.168.0.102"]:
        try:
            result = subprocess.run(
                ["ping", "-c", "1", "-W", "2", ip],
                capture_output=True, timeout=5
            )
            if result.returncode == 0:
                return ip
        except:
            pass
    return None

# =============================================================================
# IMAGE PREPROCESSING FOR OCR
# =============================================================================

def preprocess_for_ocr(frame):
    """
    Preprocess frame crop for optimal bib number OCR.
    Bib numbers are typically large dark digits on a white/light background.
    """
    results = []

    # Convert to grayscale
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

    # Method 1: Simple threshold (works well for high contrast bibs)
    _, thresh1 = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    results.append(("otsu", thresh1))

    # Method 2: Adaptive threshold (handles varying lighting)
    thresh2 = cv2.adaptiveThreshold(gray, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                                      cv2.THRESH_BINARY, 31, 10)
    results.append(("adaptive", thresh2))

    # Method 3: Enhanced contrast then threshold
    # CLAHE (Contrast Limited Adaptive Histogram Equalization)
    clahe = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8))
    enhanced = clahe.apply(gray)
    _, thresh3 = cv2.threshold(enhanced, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    results.append(("clahe", thresh3))

    # Method 4: Inverted (for light numbers on dark bibs)
    results.append(("inverted", cv2.bitwise_not(thresh1)))

    return results

def extract_numbers(text):
    """Extract valid bib numbers from OCR text"""
    # Find all sequences of 1-3 digits
    numbers = re.findall(r'\b(\d{1,3})\b', text)
    valid = []
    for n in numbers:
        num = int(n)
        if MIN_BIB <= num <= MAX_BIB:
            valid.append(num)
    return valid

# =============================================================================
# BIB DETECTOR
# =============================================================================

class BibDetector:
    def __init__(self, camera_ip, user, password, zone=DEFAULT_ZONE,
                 use_main=False, debug=False):
        self.camera_ip = camera_ip
        self.user = user
        self.password = password
        self.zone = zone
        self.debug = debug
        self.use_main = use_main

        stream = RTSP_MAIN_STREAM if use_main else RTSP_SUB_STREAM
        self.rtsp_url = f"rtsp://{user}:{password}@{camera_ip}:554/{stream}"

        # Detection state
        self.recent_detections = []  # list of (timestamp, bib_number)
        self.current_bib = None
        self.last_detection_time = 0
        self.frame_count = 0

        # Video capture
        self.cap = None

        if debug:
            os.makedirs(DEBUG_DIR, exist_ok=True)

        # Tesseract config for digit-only recognition
        self.tess_config = '--oem 3 --psm 7 -c tessedit_char_whitelist=0123456789'
        # psm 7 = treat the image as a single text line
        # whitelist = only look for digits

    def connect(self):
        """Connect to RTSP stream"""
        print(f"Connecting to camera at {self.camera_ip}...")
        self.cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
        # Set buffer size to 1 to always get latest frame
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        if self.cap.isOpened():
            w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            print(f"Connected: {w}x{h}")
            return True
        else:
            print("Failed to connect to camera")
            return False

    def grab_frame(self):
        """Grab the latest frame, discarding buffered ones"""
        if not self.cap or not self.cap.isOpened():
            return None

        # Discard buffered frames to get the latest
        for _ in range(3):
            self.cap.grab()

        ret, frame = self.cap.read()
        return frame if ret else None

    def crop_zone(self, frame):
        """Crop frame to the detection zone"""
        h, w = frame.shape[:2]
        x1 = int(w * self.zone[0])
        y1 = int(h * self.zone[1])
        x2 = int(w * self.zone[2])
        y2 = int(h * self.zone[3])
        return frame[y1:y2, x1:x2]

    def detect_bib(self, frame):
        """Run OCR on frame and return detected bib numbers"""
        crop = self.crop_zone(frame)
        preprocessed = preprocess_for_ocr(crop)

        all_numbers = []

        for method_name, img in preprocessed:
            try:
                text = pytesseract.image_to_string(img, config=self.tess_config)
                numbers = extract_numbers(text)
                all_numbers.extend(numbers)

                if self.debug and numbers:
                    ts = datetime.now().strftime("%H%M%S_%f")
                    cv2.imwrite(f"{DEBUG_DIR}/{ts}_{method_name}_{'_'.join(str(n) for n in numbers)}.jpg", img)
            except Exception as e:
                pass

        return all_numbers

    def update_state(self, detected_numbers):
        """Update detection state with new numbers, using voting/confidence"""
        now = time.time()

        if detected_numbers:
            self.last_detection_time = now
            for num in detected_numbers:
                self.recent_detections.append((now, num))

        # Trim old detections outside the confidence window
        cutoff = now - (CONFIDENCE_WINDOW * FRAME_INTERVAL)
        self.recent_detections = [(t, n) for t, n in self.recent_detections if t >= cutoff]

        # Count occurrences in recent window
        if self.recent_detections:
            counts = Counter(n for _, n in self.recent_detections)
            most_common_bib, count = counts.most_common(1)[0]

            if count >= CONFIDENCE_THRESHOLD:
                if most_common_bib != self.current_bib:
                    print(f"  >>> BIB DETECTED: #{most_common_bib} (seen {count}x in last {CONFIDENCE_WINDOW} frames)")
                    self.current_bib = most_common_bib
                    self.write_output()

        # Clear if no detection for a while
        elif self.current_bib and (now - self.last_detection_time) > NO_DETECTION_TIMEOUT:
            print(f"  No detection for {NO_DETECTION_TIMEOUT}s, clearing bib")
            self.current_bib = None
            self.write_output()

    def write_output(self):
        """Write current detected bib to JSON file"""
        data = {
            "bib": self.current_bib,
            "timestamp": datetime.now().isoformat(),
            "camera": self.camera_ip,
            "confidence": self._get_confidence()
        }
        tmp = OUTPUT_FILE + ".tmp"
        with open(tmp, 'w') as f:
            json.dump(data, f)
        os.rename(tmp, OUTPUT_FILE)

    def _get_confidence(self):
        """Get confidence score for current detection"""
        if not self.current_bib or not self.recent_detections:
            return 0
        counts = Counter(n for _, n in self.recent_detections)
        total = len(self.recent_detections)
        if self.current_bib in counts:
            return round(counts[self.current_bib] / max(total, 1), 2)
        return 0

    def show_zone(self):
        """Capture one frame and display the crop zone for calibration"""
        if not self.connect():
            return

        frame = self.grab_frame()
        if frame is None:
            print("Could not grab frame")
            return

        h, w = frame.shape[:2]
        x1 = int(w * self.zone[0])
        y1 = int(h * self.zone[1])
        x2 = int(w * self.zone[2])
        y2 = int(h * self.zone[3])

        # Draw zone rectangle on frame
        cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
        cv2.putText(frame, f"Detection Zone ({x2-x1}x{y2-y1})",
                     (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 1, (0, 255, 0), 2)

        # Save full frame with zone overlay
        out_path = "/tmp/bib_zone_preview.jpg"
        cv2.imwrite(out_path, frame)

        # Save cropped zone
        crop = frame[y1:y2, x1:x2]
        crop_path = "/tmp/bib_zone_crop.jpg"
        cv2.imwrite(crop_path, crop)

        print(f"Frame: {w}x{h}")
        print(f"Zone:  ({x1},{y1}) to ({x2},{y2}) = {x2-x1}x{y2-y1}")
        print(f"Preview saved: {out_path}")
        print(f"Crop saved:    {crop_path}")

        # Also try OCR on the crop
        preprocessed = preprocess_for_ocr(crop)
        for method_name, img in preprocessed:
            try:
                text = pytesseract.image_to_string(img, config=self.tess_config).strip()
                numbers = extract_numbers(text)
                if text or numbers:
                    print(f"  OCR [{method_name}]: raw='{text}' numbers={numbers}")
            except:
                pass

        self.cap.release()

    def run(self):
        """Main detection loop"""
        if not self.connect():
            print("Retrying in 10s...")
            time.sleep(10)
            return self.run()

        print(f"Starting bib detection (interval: {FRAME_INTERVAL}s)")
        print(f"Zone: {self.zone}")
        print(f"Output: {OUTPUT_FILE}")
        print(f"Valid bibs: {MIN_BIB}-{MAX_BIB}")
        print(f"Debug: {self.debug}")
        print(f"Stream: {'main' if self.use_main else 'sub'}")
        print("-" * 50)

        # Write initial state
        self.write_output()

        try:
            while True:
                frame = self.grab_frame()
                if frame is None:
                    print("Lost connection, reconnecting...")
                    self.cap.release()
                    time.sleep(5)
                    if not self.connect():
                        time.sleep(10)
                        continue
                    continue

                self.frame_count += 1
                detected = self.detect_bib(frame)

                ts = datetime.now().strftime("%H:%M:%S")
                if detected:
                    print(f"[{ts}] Frame #{self.frame_count}: detected {detected} | current: #{self.current_bib}")
                elif self.frame_count % 10 == 0:
                    # Print heartbeat every 10 frames
                    print(f"[{ts}] Frame #{self.frame_count}: no detection | current: #{self.current_bib}")

                self.update_state(detected)

                if self.debug and self.frame_count % 20 == 0:
                    # Save periodic debug frame
                    crop = self.crop_zone(frame)
                    ts_file = datetime.now().strftime("%H%M%S")
                    cv2.imwrite(f"{DEBUG_DIR}/periodic_{ts_file}.jpg", crop)

                time.sleep(FRAME_INTERVAL)

        except KeyboardInterrupt:
            print("\nStopping bib detector...")
        finally:
            if self.cap:
                self.cap.release()
            # Clear output on exit
            self.current_bib = None
            self.write_output()
            print("Bib detector stopped.")


# =============================================================================
# S3 UPLOADER (runs as background thread)
# =============================================================================

def start_s3_uploader(interval=3):
    """
    Periodically upload bib_detected.json to S3.
    Runs as a separate process started by the wrapper script.
    """
    import threading

    S3_DEST = "s3://avillachlab-netm/config/bib-detected.json"
    last_content = None

    def upload_loop():
        nonlocal last_content
        while True:
            try:
                if os.path.exists(OUTPUT_FILE):
                    with open(OUTPUT_FILE) as f:
                        content = f.read()

                    # Only upload if changed
                    if content != last_content:
                        subprocess.run(
                            ["aws", "s3", "cp", OUTPUT_FILE, S3_DEST,
                             "--cache-control", "no-cache, max-age=0",
                             "--content-type", "application/json"],
                            capture_output=True, timeout=10
                        )
                        last_content = content
            except Exception as e:
                print(f"S3 upload error: {e}")

            time.sleep(interval)

    t = threading.Thread(target=upload_loop, daemon=True)
    t.start()
    return t


# =============================================================================
# MAIN
# =============================================================================

def main():
    global FRAME_INTERVAL

    parser = argparse.ArgumentParser(description="Real-time bib number detection from RTSP camera")
    parser.add_argument("--camera", type=str, help="Camera IP address")
    parser.add_argument("--zone", type=str, default=None,
                        help="Detection zone as x1,y1,x2,y2 (0.0-1.0). e.g. 0.15,0.20,0.85,0.80")
    parser.add_argument("--main-stream", action="store_true",
                        help="Use main stream (4K) instead of sub-stream")
    parser.add_argument("--debug", action="store_true",
                        help="Save debug frames to /tmp/bib_debug/")
    parser.add_argument("--show-zone", action="store_true",
                        help="Capture one frame and show detection zone, then exit")
    parser.add_argument("--interval", type=float, default=FRAME_INTERVAL,
                        help=f"Seconds between frame grabs (default: {FRAME_INTERVAL})")
    parser.add_argument("--upload", action="store_true",
                        help="Also upload detected bibs to S3")
    parser.add_argument("--upload-interval", type=int, default=3,
                        help="S3 upload interval in seconds (default: 3)")
    args = parser.parse_args()

    FRAME_INTERVAL = args.interval

    # Load credentials
    creds = load_credentials()
    user = creds.get("CAMERA_USER", creds.get("REOLINK_USER", "admin"))
    password = creds.get("CAMERA_PASS", creds.get("REOLINK_PASS", ""))

    # Detect or use specified camera
    camera_ip = args.camera
    if not camera_ip:
        camera_ip = detect_camera()
        if not camera_ip:
            print("ERROR: No camera reachable. Specify with --camera IP")
            sys.exit(1)
    print(f"Camera: {camera_ip}")

    # Parse zone
    zone = DEFAULT_ZONE
    if args.zone:
        parts = [float(x) for x in args.zone.split(",")]
        if len(parts) == 4:
            zone = tuple(parts)
        else:
            print("ERROR: Zone must be 4 comma-separated values")
            sys.exit(1)

    # Create detector
    detector = BibDetector(
        camera_ip=camera_ip,
        user=user,
        password=password,
        zone=zone,
        use_main=args.main_stream,
        debug=args.debug
    )

    if args.show_zone:
        detector.show_zone()
        return

    # Start S3 uploader if requested
    if args.upload:
        print("Starting S3 uploader...")
        start_s3_uploader(args.upload_interval)

    # Handle clean shutdown
    def signal_handler(sig, frame):
        print("\nShutting down...")
        sys.exit(0)
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Run detector
    detector.run()


if __name__ == "__main__":
    main()
