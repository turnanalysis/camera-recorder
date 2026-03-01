#!/usr/bin/env python3
"""
Interactive calibration tool for mapping ski course gate positions.
Connects to the Axis PTZ camera, lets you jog to each gate, and records
the (pan, tilt, zoom) waypoints into course_config.json.

Usage:
    python3 calibrate_course.py --camera 192.168.0.100
    python3 calibrate_course.py --camera 192.168.0.100 --validate course_config.json
    python3 calibrate_course.py --camera 192.168.0.100 --output my_course.json

Controls (in live preview window):
    Arrow keys     Pan/Tilt camera
    +/-            Zoom in/out
    Page Up/Down   Adjust movement speed
    g              Record current position as gate
    s              Mark last gate as START trigger
    f              Mark last gate as FINISH
    d              Delete last gate
    l              List all recorded gates
    p              Preview: cycle through all gates
    v              View current PTZ position
    q              Save and quit
    Esc            Quit without saving
"""

import cv2
import json
import time
import os
import sys
import argparse

# Add parent dir so we can import from auto_tracker
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from auto_tracker import AxisPTZController, load_credentials

# Movement speed presets
SPEED_PRESETS = [10, 25, 50, 75, 100]
DEFAULT_SPEED_INDEX = 2  # start at 50

# Jog step sizes for absolute moves
PAN_STEP = 2.0
TILT_STEP = 1.0
ZOOM_STEP = 200


class CourseCalibrator:
    def __init__(self, camera_ip, user, password):
        self.ptz = AxisPTZController(camera_ip, user, password, timeout=1.0)
        self.gates = []
        self.speed_index = DEFAULT_SPEED_INDEX
        self.camera_ip = camera_ip
        self.user = user
        self.password = password

        # RTSP stream for preview
        profile = "h264-60fps"
        self.rtsp_url = f"rtsp://{user}:{password}@{camera_ip}/axis-media/media.amp?profile={profile}"

    def connect_preview(self):
        """Connect to RTSP stream for live preview"""
        print(f"Connecting to camera preview at {self.camera_ip}...")
        self.cap = cv2.VideoCapture(self.rtsp_url, cv2.CAP_FFMPEG)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        if self.cap.isOpened():
            w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            print(f"Preview connected: {w}x{h}")
            return True
        else:
            print("Failed to connect to camera preview")
            return False

    def grab_frame(self):
        """Grab latest frame"""
        if not self.cap or not self.cap.isOpened():
            return None
        for _ in range(3):
            self.cap.grab()
        ret, frame = self.cap.read()
        return frame if ret else None

    def jog_pan(self, direction):
        """Jog camera pan by step amount"""
        pos = self.ptz.get_position()
        if pos:
            new_pan = pos['pan'] + (PAN_STEP * direction * (self.speed_index + 1) / 3)
            self.ptz.move_absolute(new_pan, pos['tilt'], pos['zoom'],
                                  speed=SPEED_PRESETS[self.speed_index])

    def jog_tilt(self, direction):
        """Jog camera tilt by step amount"""
        pos = self.ptz.get_position()
        if pos:
            new_tilt = pos['tilt'] + (TILT_STEP * direction * (self.speed_index + 1) / 3)
            self.ptz.move_absolute(pos['pan'], new_tilt, pos['zoom'],
                                  speed=SPEED_PRESETS[self.speed_index])

    def jog_zoom(self, direction):
        """Jog camera zoom"""
        pos = self.ptz.get_position()
        if pos:
            new_zoom = max(1, pos['zoom'] + int(ZOOM_STEP * direction * (self.speed_index + 1) / 3))
            self.ptz.set_zoom(new_zoom)

    def record_gate(self):
        """Record current PTZ position as a gate"""
        pos = self.ptz.get_position()
        if not pos:
            print("  ERROR: Could not read PTZ position")
            return

        gate_id = len(self.gates) + 1
        gate = {
            'id': gate_id,
            'name': f'Gate {gate_id}',
            'pan': round(pos['pan'], 1),
            'tilt': round(pos['tilt'], 1),
            'zoom': pos['zoom'],
            'trigger_zone': None
        }
        self.gates.append(gate)
        print(f"  GATE #{gate_id} recorded: pan={gate['pan']} tilt={gate['tilt']} zoom={gate['zoom']}")

    def mark_start(self):
        """Mark last gate as start trigger"""
        if not self.gates:
            print("  No gates recorded yet")
            return

        gate = self.gates[-1]
        gate['name'] = 'Start'
        gate['trigger_zone'] = {
            'enabled': True,
            'bbox_pct': [0.3, 0.2, 0.7, 0.8],
            'direction': 'exit'
        }
        print(f"  Gate #{gate['id']} marked as START trigger")
        print("  Default trigger zone: [0.3, 0.2, 0.7, 0.8]")
        print("  Adjust trigger zone in config file after saving if needed")

    def mark_finish(self):
        """Mark last gate as finish"""
        if not self.gates:
            print("  No gates recorded yet")
            return

        gate = self.gates[-1]
        gate['name'] = 'Finish'
        print(f"  Gate #{gate['id']} marked as FINISH")

    def delete_last_gate(self):
        """Delete last recorded gate"""
        if self.gates:
            removed = self.gates.pop()
            print(f"  Deleted gate #{removed['id']} ({removed['name']})")
        else:
            print("  No gates to delete")

    def list_gates(self):
        """Print all recorded gates"""
        if not self.gates:
            print("  No gates recorded")
            return
        print(f"  {'ID':>3}  {'Name':<10}  {'Pan':>8}  {'Tilt':>8}  {'Zoom':>6}  Trigger")
        print(f"  {'---':>3}  {'----':<10}  {'---':>8}  {'----':>8}  {'----':>6}  -------")
        for g in self.gates:
            trigger = "START" if g.get('trigger_zone') and g['trigger_zone'].get('enabled') else ""
            if g['name'] == 'Finish':
                trigger = "FINISH"
            print(f"  {g['id']:>3}  {g['name']:<10}  {g['pan']:>8.1f}  {g['tilt']:>8.1f}  {g['zoom']:>6}  {trigger}")

    def preview_gates(self):
        """Cycle through all gates, showing view at each"""
        if not self.gates:
            print("  No gates to preview")
            return
        print("  Previewing all gates (3s each)...")
        for gate in self.gates:
            print(f"  -> Gate #{gate['id']} ({gate['name']})")
            self.ptz.move_absolute(gate['pan'], gate['tilt'], gate['zoom'], speed=50)
            time.sleep(3)
        print("  Preview complete")

    def draw_overlay(self, frame):
        """Draw calibration HUD on frame"""
        h, w = frame.shape[:2]

        # Get current position
        pos = self.ptz.get_position()
        if pos:
            pos_text = f"Pan: {pos['pan']:.1f}  Tilt: {pos['tilt']:.1f}  Zoom: {pos['zoom']}"
        else:
            pos_text = "PTZ: N/A"

        speed = SPEED_PRESETS[self.speed_index]
        info = f"{pos_text}  |  Speed: {speed}  |  Gates: {len(self.gates)}"

        # Background bar
        cv2.rectangle(frame, (0, 0), (w, 35), (0, 0, 0), -1)
        cv2.putText(frame, info, (10, 25),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1)

        # Controls help at bottom
        controls = "Arrows:Pan/Tilt  +/-:Zoom  PgUp/Dn:Speed  g:Gate  s:Start  f:Finish  d:Del  l:List  p:Preview  q:Save"
        cv2.rectangle(frame, (0, h - 30), (w, h), (0, 0, 0), -1)
        cv2.putText(frame, controls, (10, h - 10),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.4, (200, 200, 200), 1)

        # Crosshair
        cx, cy = w // 2, h // 2
        cv2.drawMarker(frame, (cx, cy), (0, 0, 255), cv2.MARKER_CROSS, 40, 1)

        return frame

    def save_config(self, output_path):
        """Save course configuration to JSON file"""
        config = {
            'version': 1,
            'course_name': 'Unnamed Course',
            'camera': {
                'ip': self.camera_ip,
                'stream_profile': 'h264-60fps',
                'frame_width': 1920,
                'frame_height': 1080
            },
            'model': {
                'path': 'yolov8n.engine',
                'confidence': 0.45,
                'imgsz': 640
            },
            'gates': self.gates,
            'tracking': {
                'gates_ahead': 2,
                'zoom_margin': 1.2,
                'pan_dead_zone_pct': 0.05,
                'tilt_dead_zone_pct': 0.08,
                'max_pan_speed': 70,
                'max_tilt_speed': 40,
                'ptz_update_hz': 15,
                'smoothing_factor': 0.3,
                'gate_advance_threshold_pct': 0.15,
                'lost_racer_timeout_s': 3.0,
                'anticipation_factor': 0.2,
                'racer_frame_position': 0.4
            },
            'digital_stabilization': {
                'enabled': True,
                'overscan_pct': 0.15,
                'smoothing_alpha': 0.25,
                'racer_frame_position': 0.4
            },
            'output': {
                'rtmp_url': None,
                'record_path': None,
                'debug_display': True
            }
        }

        with open(output_path, 'w') as f:
            json.dump(config, f, indent=2)
        print(f"\nConfig saved to: {output_path}")
        print(f"  {len(self.gates)} gates recorded")

    def run_interactive(self, output_path='course_config.json'):
        """Main interactive calibration loop"""
        if not self.ptz.test_connection():
            print("ERROR: Cannot connect to PTZ camera")
            return

        if not self.connect_preview():
            print("ERROR: Cannot connect to camera preview stream")
            return

        print("\n" + "=" * 60)
        print("  COURSE CALIBRATION MODE")
        print("=" * 60)
        print("  Jog camera to each gate and press 'g' to record")
        print("  Press 's' after recording the start gate")
        print("  Press 'f' after recording the finish gate")
        print("  Press 'q' to save and quit")
        print("=" * 60 + "\n")

        window_name = "Course Calibration"
        cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(window_name, 960, 540)

        try:
            while True:
                frame = self.grab_frame()
                if frame is None:
                    time.sleep(0.1)
                    continue

                display = self.draw_overlay(frame.copy())
                cv2.imshow(window_name, display)

                key = cv2.waitKey(30) & 0xFF

                if key == 255:  # no key pressed
                    continue

                # Arrow keys (OpenCV key codes)
                elif key == 81 or key == 2:  # Left arrow
                    self.jog_pan(-1)
                elif key == 83 or key == 3:  # Right arrow
                    self.jog_pan(1)
                elif key == 82 or key == 0:  # Up arrow
                    self.jog_tilt(1)
                elif key == 84 or key == 1:  # Down arrow
                    self.jog_tilt(-1)

                # Zoom
                elif key == ord('+') or key == ord('='):
                    self.jog_zoom(1)
                elif key == ord('-') or key == ord('_'):
                    self.jog_zoom(-1)

                # Speed
                elif key == 85:  # Page Up
                    self.speed_index = min(len(SPEED_PRESETS) - 1, self.speed_index + 1)
                    print(f"  Speed: {SPEED_PRESETS[self.speed_index]}")
                elif key == 86:  # Page Down
                    self.speed_index = max(0, self.speed_index - 1)
                    print(f"  Speed: {SPEED_PRESETS[self.speed_index]}")

                # Gate operations
                elif key == ord('g'):
                    self.record_gate()
                elif key == ord('s'):
                    self.mark_start()
                elif key == ord('f'):
                    self.mark_finish()
                elif key == ord('d'):
                    self.delete_last_gate()
                elif key == ord('l'):
                    self.list_gates()
                elif key == ord('p'):
                    self.preview_gates()
                elif key == ord('v'):
                    pos = self.ptz.get_position()
                    if pos:
                        print(f"  Position: pan={pos['pan']:.1f} tilt={pos['tilt']:.1f} zoom={pos['zoom']}")

                # Save and quit
                elif key == ord('q'):
                    if self.gates:
                        self.save_config(output_path)
                    else:
                        print("No gates recorded, nothing to save")
                    break

                # Quit without saving
                elif key == 27:  # ESC
                    print("Quitting without saving")
                    break

        finally:
            if self.cap:
                self.cap.release()
            cv2.destroyAllWindows()

    def validate_config(self, config_path):
        """Load and validate an existing config by visiting each gate"""
        if not os.path.exists(config_path):
            print(f"ERROR: Config file not found: {config_path}")
            return

        with open(config_path) as f:
            config = json.load(f)

        gates = config.get('gates', [])
        if not gates:
            print("No gates in config")
            return

        if not self.ptz.test_connection():
            print("ERROR: Cannot connect to PTZ camera")
            return

        if not self.connect_preview():
            print("ERROR: Cannot connect to preview stream")
            return

        print(f"\nValidating {len(gates)} gates from {config_path}")
        print("Press any key to advance to next gate, 'q' to quit\n")

        window_name = "Gate Validation"
        cv2.namedWindow(window_name, cv2.WINDOW_NORMAL)
        cv2.resizeWindow(window_name, 960, 540)

        try:
            for gate in gates:
                print(f"  Gate #{gate['id']} ({gate['name']}): "
                      f"pan={gate['pan']} tilt={gate['tilt']} zoom={gate['zoom']}")
                self.ptz.move_absolute(gate['pan'], gate['tilt'], gate['zoom'], speed=50)
                time.sleep(1.5)  # wait for camera to arrive

                # Show a few frames at this position
                while True:
                    frame = self.grab_frame()
                    if frame is not None:
                        h, w = frame.shape[:2]
                        label = f"Gate #{gate['id']}: {gate['name']} | pan={gate['pan']} tilt={gate['tilt']} zoom={gate['zoom']}"
                        cv2.rectangle(frame, (0, 0), (w, 35), (0, 0, 0), -1)
                        cv2.putText(frame, label, (10, 25),
                                   cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 1)
                        cv2.putText(frame, "Press any key for next gate, 'q' to quit",
                                   (10, h - 15), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)
                        cv2.imshow(window_name, frame)

                    key = cv2.waitKey(30) & 0xFF
                    if key != 255:
                        break

                if key == ord('q') or key == 27:
                    break

            print("\nValidation complete")

        finally:
            if self.cap:
                self.cap.release()
            cv2.destroyAllWindows()


def main():
    parser = argparse.ArgumentParser(description="Course calibration tool for auto-tracker")
    parser.add_argument("--camera", type=str, default="192.168.0.100",
                        help="Axis camera IP address")
    parser.add_argument("--output", type=str, default="course_config.json",
                        help="Output config file path")
    parser.add_argument("--validate", type=str, default=None,
                        help="Validate an existing config file")
    args = parser.parse_args()

    # Load credentials
    creds = load_credentials()
    user = creds.get('AXIS_USER', 'root')
    password = creds.get('AXIS_PASS', '')

    calibrator = CourseCalibrator(args.camera, user, password)

    if args.validate:
        calibrator.validate_config(args.validate)
    else:
        calibrator.run_interactive(args.output)


if __name__ == "__main__":
    main()
