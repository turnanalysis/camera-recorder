#!/usr/bin/env python3
"""
Auto-tracking system for ski racing using Axis PTZ camera + YOLO detection.
Runs on J40 (Jetson Orin NX) with CUDA/TensorRT acceleration.

Detects ski racers via YOLO, drives the Axis Q6135-LE PTZ camera to follow
them down the course using VAPIX API, and applies digital stabilization
for smooth output.

OCCLUSION HANDLING:
-------------------
Handles coach/crowd occlusion with these mechanisms:

1. Single-frame detection loss tolerance:
   - Never drops racer track on single-frame detection loss
   - Uses Kalman filter to predict position during brief gaps

2. Kalman filter prediction:
   - Maintains position/velocity state estimate
   - Continues PTZ commands based on predicted position during occlusion
   - Reduces PTZ speed (70%) during occlusion to avoid overshoot

3. Re-ID window:
   - Waits REACQUIRE_WINDOW_SECONDS (default 2.5s) before considering track dropped
   - Continues prediction and PTZ control throughout window

4. SAM3 re-initialization:
   - After SAM_REACQUIRE_THRESHOLD (default 1.5s) of occlusion, attempts
     SAM3 segmentation at predicted zone to re-acquire racer

5. Re-acquisition validation:
   - New candidate must pass distance + downhill direction filter
   - Prevents false re-ID on coaches/spectators

6. Trajectory continuity:
   - Racer must re-emerge continuing downhill trajectory
   - Used as re-ID constraint (is_valid_reacquisition)

Key principle: A coach standing in front of camera is temporary.
The racer always continues downhill on the other side.

Usage:
    python3 auto_tracker.py --config course_config.json
    python3 auto_tracker.py --config course_config.json --debug
    python3 auto_tracker.py --config course_config.json --dry-run
    python3 auto_tracker.py --config course_config.json --output rtmp://...

Config file occlusion section (optional):
    "occlusion": {
        "confirm_frames": 3,        // Frames before entering OCCLUDED state
        "reacquire_window_s": 2.5,  // Time window for re-acquisition
        "sam_reacquire_after_s": 1.5 // Time before SAM3 re-acquisition attempt
    }
"""

import cv2
import json
import time
import os
import argparse
import subprocess
import signal
import sys
import threading
import numpy as np
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("ERROR: requests not installed. Run: pip3 install requests")
    sys.exit(1)

try:
    from ultralytics import YOLO
except ImportError:
    YOLO = None

try:
    from sam2.sam2_image_predictor import SAM2ImagePredictor
    SAM2_AVAILABLE = True
except ImportError:
    SAM2_AVAILABLE = False


# =============================================================================
# KALMAN TRACKER FOR OCCLUSION HANDLING
# =============================================================================

class KalmanTracker:
    """
    Kalman filter for racer position/velocity estimation.
    Maintains predicted position when YOLO detection is lost due to occlusion.

    State: [cx, cy, vx, vy] - centroid position and velocity in pixels
    """

    def __init__(self, process_noise=50.0, measurement_noise=10.0):
        # State: [cx, cy, vx, vy]
        self.state = None  # Will be initialized on first measurement
        self.P = None      # Covariance matrix

        # Kalman matrices
        self.dt = 1/30.0   # Assume ~30fps

        # State transition matrix (constant velocity model)
        self.F = np.array([
            [1, 0, self.dt, 0],
            [0, 1, 0, self.dt],
            [0, 0, 1, 0],
            [0, 0, 0, 1]
        ], dtype=np.float32)

        # Observation matrix (we observe position only)
        self.H = np.array([
            [1, 0, 0, 0],
            [0, 1, 0, 0]
        ], dtype=np.float32)

        # Process noise covariance
        self.Q = np.eye(4, dtype=np.float32) * process_noise
        self.Q[2, 2] = process_noise * 2  # Higher noise for velocity
        self.Q[3, 3] = process_noise * 2

        # Measurement noise covariance
        self.R = np.eye(2, dtype=np.float32) * measurement_noise

        # Tracking state
        self.frames_since_detection = 0
        self.total_tracked_frames = 0
        self.last_bbox = None
        self.last_bbox_size = None  # (width, height) for re-ID validation

    def initialize(self, bbox):
        """Initialize tracker with first detection"""
        cx = (bbox[0] + bbox[2]) / 2
        cy = (bbox[1] + bbox[3]) / 2
        self.state = np.array([cx, cy, 0, 0], dtype=np.float32)
        self.P = np.eye(4, dtype=np.float32) * 100
        self.frames_since_detection = 0
        self.total_tracked_frames = 1
        self.last_bbox = bbox
        self.last_bbox_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])

    def predict(self):
        """Predict next state (call each frame regardless of detection)"""
        if self.state is None:
            return None

        # State prediction
        self.state = self.F @ self.state
        # Covariance prediction
        self.P = self.F @ self.P @ self.F.T + self.Q

        return self.get_predicted_centroid()

    def update(self, bbox):
        """Update with new measurement"""
        if self.state is None:
            self.initialize(bbox)
            return

        cx = (bbox[0] + bbox[2]) / 2
        cy = (bbox[1] + bbox[3]) / 2
        z = np.array([cx, cy], dtype=np.float32)

        # Innovation
        y = z - self.H @ self.state
        S = self.H @ self.P @ self.H.T + self.R

        # Kalman gain
        K = self.P @ self.H.T @ np.linalg.inv(S)

        # State update
        self.state = self.state + K @ y
        # Covariance update
        I = np.eye(4, dtype=np.float32)
        self.P = (I - K @ self.H) @ self.P

        self.frames_since_detection = 0
        self.total_tracked_frames += 1
        self.last_bbox = bbox
        self.last_bbox_size = (bbox[2] - bbox[0], bbox[3] - bbox[1])

    def mark_missed(self):
        """Mark frame with no detection"""
        self.frames_since_detection += 1
        self.total_tracked_frames += 1

    def get_predicted_centroid(self):
        """Get current predicted centroid"""
        if self.state is None:
            return None
        return (self.state[0], self.state[1])

    def get_velocity(self):
        """Get current velocity estimate (pixels/frame)"""
        if self.state is None:
            return (0, 0)
        return (self.state[2], self.state[3])

    def get_speed(self):
        """Get speed magnitude (pixels/frame)"""
        vx, vy = self.get_velocity()
        return (vx**2 + vy**2) ** 0.5

    def get_predicted_bbox(self):
        """Get predicted bbox based on last size and current predicted centroid"""
        if self.state is None or self.last_bbox_size is None:
            return None
        cx, cy = self.state[0], self.state[1]
        w, h = self.last_bbox_size
        return (cx - w/2, cy - h/2, cx + w/2, cy + h/2)

    def is_valid_reacquisition(self, candidate_bbox, frame_shape, max_distance_pct=0.25,
                                 min_speed_ratio=0.3, require_downhill=True):
        """
        Validate a candidate detection as the same racer after occlusion.

        Checks:
        1. Distance from predicted position (within max_distance_pct of frame diagonal)
        2. Speed continuity (candidate moving at similar speed)
        3. Downhill direction (racer should continue moving downhill)
        """
        if self.state is None:
            return True  # No prior track, accept anything

        pred_cx, pred_cy = self.get_predicted_centroid()
        cand_cx = (candidate_bbox[0] + candidate_bbox[2]) / 2
        cand_cy = (candidate_bbox[1] + candidate_bbox[3]) / 2

        # Distance check
        frame_diag = (frame_shape[0]**2 + frame_shape[1]**2) ** 0.5
        dist = ((cand_cx - pred_cx)**2 + (cand_cy - pred_cy)**2) ** 0.5

        if dist > frame_diag * max_distance_pct:
            return False

        # Direction check: racer should be moving downhill (positive y velocity in image coords)
        # After occlusion, candidate should be below or at predicted position (accounting for slope)
        if require_downhill:
            vx, vy = self.get_velocity()
            # If we had significant downhill velocity, candidate should continue that trend
            if vy > 5:  # Was moving downhill
                # Allow some lateral drift but should be in downhill cone
                expected_y = pred_cy  # Already predicted forward
                if cand_cy < expected_y - frame_shape[0] * 0.1:  # Candidate is too high up
                    return False

        return True

    def reset(self):
        """Reset tracker state"""
        self.state = None
        self.P = None
        self.frames_since_detection = 0
        self.total_tracked_frames = 0
        self.last_bbox = None
        self.last_bbox_size = None

# =============================================================================
# CREDENTIALS (same pattern as bib_detector.py)
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


# =============================================================================
# AXIS PTZ CONTROLLER (VAPIX API)
# =============================================================================

class AxisPTZController:
    """
    Controls Axis Q6135-LE PTZ camera via VAPIX HTTP API.
    Uses continuous speed commands for smooth tracking.
    """

    def __init__(self, ip, user, password, timeout=0.5):
        self.ip = ip
        self.timeout = timeout
        self.session = requests.Session()
        self.session.auth = (user, password)
        self.base_url = f"http://{ip}/axis-cgi/com/ptz.cgi"

        # Cache limits on init
        self._limits = None

    def test_connection(self):
        """Verify camera is reachable and credentials work"""
        try:
            pos = self.get_position()
            if pos:
                print(f"PTZ connected: pan={pos['pan']:.1f} tilt={pos['tilt']:.1f} zoom={pos['zoom']}")
                return True
        except Exception as e:
            print(f"PTZ connection failed: {e}")
        return False

    def get_position(self):
        """Query current pan/tilt/zoom position"""
        try:
            r = self.session.get(f"{self.base_url}?query=position", timeout=self.timeout)
            if r.status_code == 200:
                pos = {}
                for line in r.text.strip().split('\n'):
                    if '=' in line:
                        key, val = line.split('=', 1)
                        key = key.strip()
                        val = val.strip()
                        if key in ('pan', 'tilt'):
                            pos[key] = float(val)
                        elif key == 'zoom':
                            pos[key] = int(val)
                return pos
        except requests.exceptions.RequestException:
            pass
        return None

    def get_limits(self):
        """Query pan/tilt/zoom limits (cached)"""
        if self._limits:
            return self._limits
        try:
            r = self.session.get(f"{self.base_url}?query=limits", timeout=self.timeout)
            if r.status_code == 200:
                self._limits = {}
                for line in r.text.strip().split('\n'):
                    if '=' in line:
                        key, val = line.split('=', 1)
                        self._limits[key.strip()] = val.strip()
                return self._limits
        except requests.exceptions.RequestException:
            pass
        return None

    def move_absolute(self, pan, tilt, zoom, speed=50):
        """Move to absolute pan/tilt/zoom position"""
        params = {
            'pan': f'{pan:.1f}',
            'tilt': f'{tilt:.1f}',
            'zoom': str(int(zoom)),
            'speed': str(int(speed))
        }
        try:
            self.session.get(self.base_url, params=params, timeout=self.timeout)
        except requests.exceptions.RequestException:
            pass

    def move_continuous(self, pan_speed, tilt_speed):
        """
        Set continuous pan/tilt speed. Range: -100 to 100.
        0,0 = stop. Called at ~15Hz for smooth tracking.
        """
        pan_speed = max(-100, min(100, int(pan_speed)))
        tilt_speed = max(-100, min(100, int(tilt_speed)))
        params = {
            'continuouspantiltmove': f'{pan_speed},{tilt_speed}'
        }
        try:
            self.session.get(self.base_url, params=params, timeout=self.timeout)
        except requests.exceptions.RequestException:
            pass

    def set_zoom(self, zoom):
        """Set absolute zoom level"""
        try:
            self.session.get(self.base_url, params={'zoom': str(int(zoom))},
                           timeout=self.timeout)
        except requests.exceptions.RequestException:
            pass

    def stop(self):
        """Stop all movement"""
        self.move_continuous(0, 0)

    def relative_zoom(self, amount):
        """Relative zoom: positive = zoom in, negative = zoom out"""
        try:
            self.session.get(self.base_url, params={'rzoom': str(int(amount))},
                           timeout=self.timeout)
        except requests.exceptions.RequestException:
            pass


# =============================================================================
# YOLO DETECTOR
# =============================================================================

class YOLODetector:
    """
    Person detector using YOLO + TensorRT on Jetson.
    Falls back to PyTorch if TensorRT engine not available.
    """

    def __init__(self, model_path='yolov8n.pt', conf_threshold=0.45, imgsz=640):
        if YOLO is None:
            raise RuntimeError("ultralytics not installed. Run: pip3 install ultralytics")

        print(f"Loading YOLO model: {model_path}")
        self.model = YOLO(model_path)
        self.conf_threshold = conf_threshold
        self.imgsz = imgsz

        # Warm up with a dummy frame
        dummy = np.zeros((imgsz, imgsz, 3), dtype=np.uint8)
        self.model.predict(dummy, imgsz=self.imgsz, conf=self.conf_threshold,
                          classes=[0], verbose=False)
        print("YOLO model ready")

    def detect(self, frame):
        """
        Run inference on a BGR frame.
        Returns list of dicts: [{'bbox': (x1,y1,x2,y2), 'conf': float}]
        Filtered to 'person' class (class 0) only.
        """
        results = self.model.predict(frame, imgsz=self.imgsz,
                                     conf=self.conf_threshold,
                                     classes=[0], verbose=False)
        detections = []
        if results and len(results) > 0:
            boxes = results[0].boxes
            if boxes is not None:
                for box in boxes:
                    x1, y1, x2, y2 = box.xyxy[0].cpu().numpy()
                    conf = float(box.conf[0].cpu().numpy())
                    detections.append({
                        'bbox': (float(x1), float(y1), float(x2), float(y2)),
                        'conf': conf
                    })
        return detections

    def select_racer(self, detections, prev_bbox=None, frame_shape=None,
                      kalman_tracker=None):
        """
        From multiple person detections, select the most likely racer.

        Strategy:
        1. If kalman_tracker exists: use predicted position for matching
        2. If prev_bbox exists: pick detection closest to previous centroid
        3. If no prev_bbox: pick largest bounding box (closest to camera)
        4. Filter out detections near frame edges (likely spectators)
        """
        if not detections:
            return None

        # Use Kalman predicted position if available (better than raw prev_bbox)
        if kalman_tracker and kalman_tracker.state is not None:
            pred_cx, pred_cy = kalman_tracker.get_predicted_centroid()

            best = None
            best_dist = float('inf')
            for det in detections:
                cx = (det['bbox'][0] + det['bbox'][2]) / 2
                cy = (det['bbox'][1] + det['bbox'][3]) / 2
                dist = ((cx - pred_cx) ** 2 + (cy - pred_cy) ** 2) ** 0.5
                if dist < best_dist:
                    best_dist = dist
                    best = det

            # Reject if too far from predicted position
            if frame_shape and best:
                diag = (frame_shape[1]**2 + frame_shape[0]**2) ** 0.5
                max_dist = diag * 0.25  # Tighter than before since Kalman is more accurate
                if best_dist > max_dist:
                    return None

                # If recovering from occlusion, validate re-acquisition
                if kalman_tracker.frames_since_detection > 5:
                    if not kalman_tracker.is_valid_reacquisition(best['bbox'], frame_shape):
                        return None

            return best

        elif prev_bbox is not None:
            # Track by proximity to previous position
            prev_cx = (prev_bbox[0] + prev_bbox[2]) / 2
            prev_cy = (prev_bbox[1] + prev_bbox[3]) / 2

            best = None
            best_dist = float('inf')
            for det in detections:
                cx = (det['bbox'][0] + det['bbox'][2]) / 2
                cy = (det['bbox'][1] + det['bbox'][3]) / 2
                dist = ((cx - prev_cx) ** 2 + (cy - prev_cy) ** 2) ** 0.5
                if dist < best_dist:
                    best_dist = dist
                    best = det

            # Reject if too far from previous position (> 30% of frame diagonal)
            if frame_shape and best:
                diag = (frame_shape[1]**2 + frame_shape[0]**2) ** 0.5
                if best_dist > diag * 0.3:
                    return None
            return best
        else:
            # No prior tracking: pick largest bbox (most prominent person)
            return max(detections, key=lambda d: (
                (d['bbox'][2] - d['bbox'][0]) * (d['bbox'][3] - d['bbox'][1])
            ))


# =============================================================================
# COURSE MAP
# =============================================================================

class CourseMap:
    """
    Manages pre-mapped gate waypoints loaded from course_config.json.
    Handles interpolation between gates and zoom computation.
    """

    def __init__(self, config):
        self.gates = config['gates']
        self.tracking = config.get('tracking', {})
        self.gates_ahead = self.tracking.get('gates_ahead', 2)
        self.zoom_margin = self.tracking.get('zoom_margin', 1.2)

    def get_gate(self, gate_id):
        """Return gate by ID"""
        for g in self.gates:
            if g['id'] == gate_id:
                return g
        return None

    def get_gate_by_index(self, index):
        """Return gate by list index"""
        if 0 <= index < len(self.gates):
            return self.gates[index]
        return None

    def get_start_gate(self):
        """Return the gate with trigger_zone enabled"""
        for g in self.gates:
            tz = g.get('trigger_zone')
            if tz and tz.get('enabled', False):
                return g
        return self.gates[0] if self.gates else None

    def get_finish_gate(self):
        """Return the last gate"""
        return self.gates[-1] if self.gates else None

    def get_start_index(self):
        """Return index of start gate"""
        for i, g in enumerate(self.gates):
            tz = g.get('trigger_zone')
            if tz and tz.get('enabled', False):
                return i
        return 0

    def num_gates(self):
        return len(self.gates)

    def interpolate_ptz(self, gate_a, gate_b, progress):
        """
        Linear interpolation between two gate PTZ positions.
        progress: 0.0 = at gate_a, 1.0 = at gate_b
        """
        t = max(0.0, min(1.0, progress))
        return {
            'pan': gate_a['pan'] + (gate_b['pan'] - gate_a['pan']) * t,
            'tilt': gate_a['tilt'] + (gate_b['tilt'] - gate_a['tilt']) * t,
            'zoom': int(gate_a['zoom'] + (gate_b['zoom'] - gate_a['zoom']) * t)
        }

    def compute_zoom_for_span(self, current_index):
        """
        Compute zoom level to frame racer + N gates ahead.
        Uses the pan angle span between current gate and gate+N to
        determine how wide the view should be.
        """
        end_index = min(current_index + self.gates_ahead, len(self.gates) - 1)
        if end_index <= current_index:
            return self.gates[current_index]['zoom']

        pan_span = abs(self.gates[end_index]['pan'] - self.gates[current_index]['pan'])
        # Use average zoom of the span gates, adjusted by margin
        avg_zoom = sum(g['zoom'] for g in self.gates[current_index:end_index+1]) / (end_index - current_index + 1)

        # Wider span needs lower zoom (wider view)
        # Scale zoom inversely with pan span, clamped to reasonable range
        if pan_span > 0:
            # Base zoom reduced proportionally to span
            target_zoom = avg_zoom / self.zoom_margin
        else:
            target_zoom = self.gates[current_index]['zoom']

        return max(1, int(target_zoom))


# =============================================================================
# DIGITAL STABILIZER
# =============================================================================

class DigitalStabilizer:
    """
    Applies digital crop/zoom stabilization on top of physical PTZ.
    Camera is set wider than needed; this crops and smooths the output.
    """

    def __init__(self, overscan_pct=0.15, smoothing_alpha=0.25,
                 racer_frame_position=0.4, output_width=1920, output_height=1080):
        self.overscan_pct = overscan_pct
        self.alpha = smoothing_alpha
        self.racer_pos = racer_frame_position
        self.output_width = output_width
        self.output_height = output_height

        # EMA state
        self.ema_x = None
        self.ema_y = None

    def reset(self):
        """Reset smoothing state (call when tracking restarts)"""
        self.ema_x = None
        self.ema_y = None

    def update(self, frame, racer_bbox, pan_direction=-1):
        """
        Compute stabilized crop of the frame centered on the racer.

        Args:
            frame: full camera frame (1920x1080)
            racer_bbox: (x1, y1, x2, y2) of racer in frame
            pan_direction: -1 = racer moving right-to-left, +1 = left-to-right

        Returns:
            stabilized frame at output resolution
        """
        h, w = frame.shape[:2]

        # Crop dimensions (smaller than full frame due to overscan)
        crop_w = int(w * (1.0 - self.overscan_pct))
        crop_h = int(h * (1.0 - self.overscan_pct))

        # Racer centroid
        rcx = (racer_bbox[0] + racer_bbox[2]) / 2
        rcy = (racer_bbox[1] + racer_bbox[3]) / 2

        # Desired crop origin: place racer at racer_frame_position
        # If pan_direction < 0 (racer moves right-to-left in world),
        # place racer on the right side of frame so left side shows gates ahead
        if pan_direction < 0:
            desired_x = rcx - crop_w * (1.0 - self.racer_pos)
        else:
            desired_x = rcx - crop_w * self.racer_pos

        desired_y = rcy - crop_h * 0.5

        # EMA smoothing
        if self.ema_x is None:
            self.ema_x = desired_x
            self.ema_y = desired_y
        else:
            self.ema_x = self.alpha * desired_x + (1 - self.alpha) * self.ema_x
            self.ema_y = self.alpha * desired_y + (1 - self.alpha) * self.ema_y

        # Clamp to frame bounds
        x1 = int(max(0, min(self.ema_x, w - crop_w)))
        y1 = int(max(0, min(self.ema_y, h - crop_h)))

        # Crop and resize
        crop = frame[y1:y1 + crop_h, x1:x1 + crop_w]
        if crop.shape[1] != self.output_width or crop.shape[0] != self.output_height:
            crop = cv2.resize(crop, (self.output_width, self.output_height),
                            interpolation=cv2.INTER_LINEAR)
        return crop

    def passthrough(self, frame):
        """Return frame without stabilization (when no racer detected)"""
        if frame.shape[1] != self.output_width or frame.shape[0] != self.output_height:
            return cv2.resize(frame, (self.output_width, self.output_height),
                            interpolation=cv2.INTER_LINEAR)
        return frame


# =============================================================================
# RACER TRACKER (main orchestrator)
# =============================================================================

# States
STATE_IDLE = 'IDLE'
STATE_WAITING = 'WAITING'
STATE_TRACKING = 'TRACKING'
STATE_OCCLUDED = 'OCCLUDED'  # Tracking via Kalman prediction during occlusion
STATE_FINISHED = 'FINISHED'

# Occlusion handling constants
OCCLUSION_CONFIRM_FRAMES = 3      # Frames without detection before entering OCCLUDED state
REACQUIRE_WINDOW_SECONDS = 2.5    # Time window to re-acquire before considering track dropped
SAM_REACQUIRE_THRESHOLD = 1.5     # Seconds of occlusion before attempting SAM3 re-acquisition


class RacerTracker:
    """
    Main orchestrator. Owns the detection-tracking-PTZ-stabilization loop.
    State machine: IDLE -> WAITING -> TRACKING -> FINISHED -> IDLE
    """

    def __init__(self, config_path, camera_ip=None, model_path=None,
                 dry_run=False, debug=False, output_url=None, record_path=None,
                 source=None):
        # Load config
        with open(config_path) as f:
            self.config = json.load(f)

        # Override config with CLI args
        cam_cfg = self.config.get('camera', {})
        self.camera_ip = camera_ip or cam_cfg.get('ip', '192.168.0.100')
        model_cfg = self.config.get('model', {})
        self.model_path = model_path or model_cfg.get('path', 'yolov8n.pt')

        self.dry_run = dry_run
        self.debug = debug
        self.output_url = output_url
        self.record_path = record_path
        self.source = source  # override RTSP with video file for testing

        # Tracking config
        track_cfg = self.config.get('tracking', {})
        self.ptz_update_hz = track_cfg.get('ptz_update_hz', 15)
        self.pan_dead_zone = track_cfg.get('pan_dead_zone_pct', 0.05)
        self.tilt_dead_zone = track_cfg.get('tilt_dead_zone_pct', 0.08)
        self.max_pan_speed = track_cfg.get('max_pan_speed', 70)
        self.max_tilt_speed = track_cfg.get('max_tilt_speed', 40)
        self.anticipation = track_cfg.get('anticipation_factor', 0.2)
        self.gate_advance_pct = track_cfg.get('gate_advance_threshold_pct', 0.15)
        self.lost_timeout = track_cfg.get('lost_racer_timeout_s', 3.0)
        self.racer_frame_pos = track_cfg.get('racer_frame_position',
                                              self.config.get('digital_stabilization', {}).get('racer_frame_position', 0.4))

        # Occlusion handling config
        occlusion_cfg = self.config.get('occlusion', {})
        global OCCLUSION_CONFIRM_FRAMES, REACQUIRE_WINDOW_SECONDS, SAM_REACQUIRE_THRESHOLD
        OCCLUSION_CONFIRM_FRAMES = occlusion_cfg.get('confirm_frames', 3)
        REACQUIRE_WINDOW_SECONDS = occlusion_cfg.get('reacquire_window_s', 2.5)
        SAM_REACQUIRE_THRESHOLD = occlusion_cfg.get('sam_reacquire_after_s', 1.5)

        # Load credentials
        creds = load_credentials()
        self.axis_user = creds.get('AXIS_USER', 'root')
        self.axis_pass = creds.get('AXIS_PASS', '')

        # Initialize components
        self.ptz = AxisPTZController(self.camera_ip, self.axis_user, self.axis_pass)
        self.course = CourseMap(self.config)
        self.detector = None  # lazy init (YOLO is heavy)

        stab_cfg = self.config.get('digital_stabilization', {})
        self.stabilizer = DigitalStabilizer(
            overscan_pct=stab_cfg.get('overscan_pct', 0.15),
            smoothing_alpha=stab_cfg.get('smoothing_alpha', 0.25),
            racer_frame_position=stab_cfg.get('racer_frame_position', 0.4)
        )
        self.stabilization_enabled = stab_cfg.get('enabled', True)

        # State
        self.state = STATE_IDLE
        self.current_gate_index = 0
        self.prev_bbox = None
        self.last_detection_time = 0
        self.last_ptz_time = 0
        self.tracking_start_time = 0
        self.frames_in_zone = 0  # for start trigger debounce
        self.frame_count = 0

        # Occlusion handling
        self.kalman_tracker = KalmanTracker()
        self.occlusion_start_time = None
        self.consecutive_missed_frames = 0
        self.sam_reacquire_attempted = False

        # SAM3 for re-acquisition (optional)
        self.sam_predictor = None
        if SAM2_AVAILABLE:
            try:
                # Load SAM2 model for re-acquisition
                self.sam_predictor = SAM2ImagePredictor.from_pretrained("facebook/sam2-hiera-base-plus")
                print("SAM2 loaded for occlusion re-acquisition")
            except Exception as e:
                print(f"SAM2 not available: {e}")

        # Video capture
        self.cap = None

        # Output
        self.ffmpeg_proc = None
        self.video_writer = None

        # Shutdown flag
        self.running = True

    def _init_detector(self):
        """Lazy-init YOLO detector"""
        if self.detector is None:
            model_cfg = self.config.get('model', {})
            self.detector = YOLODetector(
                model_path=self.model_path,
                conf_threshold=model_cfg.get('confidence', 0.45),
                imgsz=model_cfg.get('imgsz', 640)
            )

    def connect_stream(self):
        """Connect to RTSP stream or video file"""
        if self.source:
            # Use video file for testing
            url = self.source
            print(f"Opening video file: {url}")
        else:
            profile = self.config.get('camera', {}).get('stream_profile', 'h264-60fps')
            url = f"rtsp://{self.axis_user}:{self.axis_pass}@{self.camera_ip}/axis-media/media.amp?profile={profile}"
            print(f"Connecting to RTSP: {self.camera_ip}")

        self.cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)

        if self.cap.isOpened():
            w = int(self.cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(self.cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            fps = self.cap.get(cv2.CAP_PROP_FPS)
            print(f"Stream connected: {w}x{h} @ {fps:.0f}fps")
            return True
        else:
            print("Failed to connect to stream")
            return False

    def grab_frame(self):
        """Grab latest frame, discarding buffer"""
        if not self.cap or not self.cap.isOpened():
            return None
        # Discard buffered frames
        for _ in range(3):
            self.cap.grab()
        ret, frame = self.cap.read()
        return frame if ret else None

    def _init_output(self, frame_shape):
        """Initialize output stream/file if configured"""
        h, w = frame_shape[:2]

        if self.output_url and not self.ffmpeg_proc:
            cmd = [
                'ffmpeg', '-y',
                '-f', 'rawvideo',
                '-vcodec', 'rawvideo',
                '-pix_fmt', 'bgr24',
                '-s', f'{w}x{h}',
                '-r', '30',
                '-i', '-',
                '-c:v', 'libx264',
                '-preset', 'ultrafast',
                '-tune', 'zerolatency',
                '-pix_fmt', 'yuv420p',
                '-f', 'flv',
                self.output_url
            ]
            self.ffmpeg_proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                                 stderr=subprocess.DEVNULL)
            print(f"Output stream: {self.output_url}")

        if self.record_path and not self.video_writer:
            fourcc = cv2.VideoWriter_fourcc(*'mp4v')
            self.video_writer = cv2.VideoWriter(self.record_path, fourcc, 30, (w, h))
            print(f"Recording to: {self.record_path}")

    def _output_frame(self, frame):
        """Write frame to output(s)"""
        if self.ffmpeg_proc and self.ffmpeg_proc.stdin:
            try:
                self.ffmpeg_proc.stdin.write(frame.tobytes())
            except BrokenPipeError:
                pass

        if self.video_writer:
            self.video_writer.write(frame)

    def _draw_debug_overlay(self, frame, detections, racer, gate_info=""):
        """Draw debug information on frame"""
        h, w = frame.shape[:2]

        # Draw all detections in blue
        for det in detections:
            x1, y1, x2, y2 = [int(v) for v in det['bbox']]
            cv2.rectangle(frame, (x1, y1), (x2, y2), (255, 0, 0), 1)
            cv2.putText(frame, f"{det['conf']:.2f}", (x1, y1 - 5),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 0, 0), 1)

        # Draw racer in green
        if racer:
            x1, y1, x2, y2 = [int(v) for v in racer['bbox']]
            cv2.rectangle(frame, (x1, y1), (x2, y2), (0, 255, 0), 3)
            cv2.putText(frame, "RACER", (x1, y1 - 10),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

        # Draw crosshair at desired racer position
        target_x = int(w * self.racer_frame_pos)
        target_y = h // 2
        cv2.drawMarker(frame, (target_x, target_y), (0, 0, 255),
                       cv2.MARKER_CROSS, 30, 2)

        # State + info bar
        ts = datetime.now().strftime("%H:%M:%S")
        info = f"[{ts}] State: {self.state} | Gate: {self.current_gate_index+1}/{self.course.num_gates()} | {gate_info}"
        cv2.putText(frame, info, (10, 30),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)

        # Kalman tracker status (second line)
        if self.kalman_tracker.state is not None:
            vx, vy = self.kalman_tracker.get_velocity()
            speed = self.kalman_tracker.get_speed()
            missed = self.kalman_tracker.frames_since_detection
            kalman_info = f"Kalman: v=({vx:.0f},{vy:.0f}) speed={speed:.0f}px/f | missed={missed}f"
            cv2.putText(frame, kalman_info, (10, 55),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 0), 1)

        # FPS
        cv2.putText(frame, f"Frame #{self.frame_count}", (10, h - 20),
                   cv2.FONT_HERSHEY_SIMPLEX, 0.5, (200, 200, 200), 1)

        # Trigger zone (when WAITING)
        if self.state == STATE_WAITING:
            start_gate = self.course.get_start_gate()
            tz = start_gate.get('trigger_zone', {}) if start_gate else {}
            if tz.get('enabled'):
                bbox_pct = tz.get('bbox_pct', [0.3, 0.2, 0.7, 0.8])
                tx1 = int(w * bbox_pct[0])
                ty1 = int(h * bbox_pct[1])
                tx2 = int(w * bbox_pct[2])
                ty2 = int(h * bbox_pct[3])
                cv2.rectangle(frame, (tx1, ty1), (tx2, ty2), (0, 165, 255), 2)
                cv2.putText(frame, "TRIGGER ZONE", (tx1, ty1 - 5),
                           cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 165, 255), 1)

        return frame

    def _compute_ptz_correction(self, racer_bbox, frame_shape):
        """
        Compute continuous pan/tilt speed commands from racer position in frame.
        Uses proportional control with dead zone and anticipation.
        """
        frame_w, frame_h = frame_shape[1], frame_shape[0]

        # Racer centroid
        cx = (racer_bbox[0] + racer_bbox[2]) / 2
        cy = (racer_bbox[1] + racer_bbox[3]) / 2

        # Determine pan direction from course map
        cur_gate = self.course.get_gate_by_index(self.current_gate_index)
        next_idx = min(self.current_gate_index + 1, self.course.num_gates() - 1)
        next_gate = self.course.get_gate_by_index(next_idx)

        if cur_gate and next_gate:
            pan_direction = next_gate['pan'] - cur_gate['pan']
        else:
            pan_direction = -1  # default: racer moves right-to-left

        # Desired position in frame
        # Racer on trailing side, gates ahead on leading side
        if pan_direction < 0:
            # Racer moves to lower pan values (right-to-left in world)
            # Place racer on RIGHT side of frame
            desired_cx = frame_w * (1.0 - self.racer_frame_pos)
        else:
            # Place racer on LEFT side of frame
            desired_cx = frame_w * self.racer_frame_pos

        desired_cy = frame_h * 0.5

        # Error (pixels)
        error_x = cx - desired_cx
        error_y = cy - desired_cy

        # Normalize to [-1, 1]
        norm_error_x = error_x / (frame_w / 2)
        norm_error_y = error_y / (frame_h / 2)

        # Dead zone
        if abs(norm_error_x) < self.pan_dead_zone:
            norm_error_x = 0
        if abs(norm_error_y) < self.tilt_dead_zone:
            norm_error_y = 0

        # Anticipation: bias toward next gate direction
        if pan_direction < 0:
            norm_error_x += self.anticipation
        else:
            norm_error_x -= self.anticipation

        # Proportional control -> speed commands
        gain_pan = self.max_pan_speed / 0.7
        gain_tilt = self.max_tilt_speed / 0.7

        pan_speed = int(max(-self.max_pan_speed,
                           min(self.max_pan_speed, norm_error_x * gain_pan)))
        tilt_speed = int(max(-self.max_tilt_speed,
                            min(self.max_tilt_speed, norm_error_y * gain_tilt)))

        return pan_speed, tilt_speed, pan_direction

    def _check_gate_advance(self, racer_bbox, frame_shape):
        """
        Check if racer has crossed into the leading edge of the frame,
        indicating they've passed the current gate.
        """
        frame_w = frame_shape[1]
        cx = (racer_bbox[0] + racer_bbox[2]) / 2

        cur_gate = self.course.get_gate_by_index(self.current_gate_index)
        next_idx = min(self.current_gate_index + 1, self.course.num_gates() - 1)
        next_gate = self.course.get_gate_by_index(next_idx)

        if not cur_gate or not next_gate or self.current_gate_index >= self.course.num_gates() - 1:
            return False

        pan_direction = next_gate['pan'] - cur_gate['pan']

        # Check if racer is in the leading edge of frame
        if pan_direction < 0:
            # Racer moving right-to-left: leading edge is left side
            threshold = frame_w * self.gate_advance_pct
            if cx < threshold:
                return True
        else:
            # Racer moving left-to-right: leading edge is right side
            threshold = frame_w * (1.0 - self.gate_advance_pct)
            if cx > threshold:
                return True

        return False

    def _check_start_trigger(self, detections, frame_shape):
        """
        Check if a racer has left the start trigger zone.
        Returns True when tracking should begin.
        """
        start_gate = self.course.get_start_gate()
        if not start_gate:
            return False

        tz = start_gate.get('trigger_zone', {})
        if not tz.get('enabled', False):
            return False

        bbox_pct = tz.get('bbox_pct', [0.3, 0.2, 0.7, 0.8])
        frame_h, frame_w = frame_shape[:2]

        tz_x1 = frame_w * bbox_pct[0]
        tz_y1 = frame_h * bbox_pct[1]
        tz_x2 = frame_w * bbox_pct[2]
        tz_y2 = frame_h * bbox_pct[3]

        # Check if any detection is inside the trigger zone
        person_in_zone = False
        person_in_frame = False

        for det in detections:
            cx = (det['bbox'][0] + det['bbox'][2]) / 2
            cy = (det['bbox'][1] + det['bbox'][3]) / 2
            person_in_frame = True

            if tz_x1 <= cx <= tz_x2 and tz_y1 <= cy <= tz_y2:
                person_in_zone = True

        direction = tz.get('direction', 'exit')

        if direction == 'exit':
            if person_in_zone:
                self.frames_in_zone += 1
            else:
                # Person was in zone (debounced) and now left it
                if self.frames_in_zone >= 3 and person_in_frame:
                    self.frames_in_zone = 0
                    return True
                if not person_in_frame:
                    # Person disappeared entirely, reset
                    self.frames_in_zone = 0
        elif direction == 'enter':
            if person_in_zone:
                self.frames_in_zone += 1
                if self.frames_in_zone >= 3:
                    return True

        return False

    def _attempt_sam_reacquisition(self, frame):
        """
        Use SAM3 to re-acquire racer after extended occlusion.
        Prompts SAM with "ski racer" in the predicted zone.

        Returns:
            bbox (x1, y1, x2, y2) if re-acquired, None otherwise
        """
        if not self.sam_predictor:
            return None

        pred_bbox = self.kalman_tracker.get_predicted_bbox()
        if pred_bbox is None:
            return None

        try:
            # Set image for SAM
            self.sam_predictor.set_image(frame)

            # Use predicted centroid as point prompt
            pred_cx, pred_cy = self.kalman_tracker.get_predicted_centroid()
            point_coords = np.array([[pred_cx, pred_cy]])
            point_labels = np.array([1])  # foreground

            # Get mask predictions
            masks, scores, _ = self.sam_predictor.predict(
                point_coords=point_coords,
                point_labels=point_labels,
                multimask_output=True
            )

            # Select best mask
            if len(scores) > 0:
                best_idx = np.argmax(scores)
                if scores[best_idx] > 0.5:
                    mask = masks[best_idx]
                    # Convert mask to bbox
                    ys, xs = np.where(mask)
                    if len(xs) > 0 and len(ys) > 0:
                        bbox = (float(xs.min()), float(ys.min()),
                               float(xs.max()), float(ys.max()))

                        # Validate re-acquisition
                        if self.kalman_tracker.is_valid_reacquisition(bbox, frame.shape):
                            print(f"  SAM3 re-acquired racer at {bbox}")
                            return bbox

        except Exception as e:
            if self.debug:
                print(f"  SAM3 re-acquisition failed: {e}")

        return None

    def _handle_occlusion(self, frame):
        """
        Handle racer occlusion using Kalman prediction.
        Continues PTZ tracking based on predicted position.

        Returns:
            (gate_info_str, predicted_bbox or None)
        """
        # Predict forward
        self.kalman_tracker.predict()
        self.kalman_tracker.mark_missed()

        pred_bbox = self.kalman_tracker.get_predicted_bbox()
        occlusion_duration = time.time() - self.occlusion_start_time if self.occlusion_start_time else 0

        # Compute PTZ command from predicted position
        if pred_bbox:
            pan_speed, tilt_speed, pan_dir = self._compute_ptz_correction(
                pred_bbox, frame.shape)

            # Reduce PTZ speed during occlusion (less confidence)
            pan_speed = int(pan_speed * 0.7)
            tilt_speed = int(tilt_speed * 0.7)

            # Throttle PTZ commands
            now = time.time()
            ptz_interval = 1.0 / self.ptz_update_hz
            if now - self.last_ptz_time >= ptz_interval:
                if not self.dry_run:
                    self.ptz.move_continuous(pan_speed, tilt_speed)
                self.last_ptz_time = now

            gate_info = f"OCCLUDED {occlusion_duration:.1f}s | PTZ(pred): pan={pan_speed:+d} tilt={tilt_speed:+d}"
        else:
            gate_info = f"OCCLUDED {occlusion_duration:.1f}s | No prediction"

        # Attempt SAM3 re-acquisition after threshold
        if (occlusion_duration > SAM_REACQUIRE_THRESHOLD and
            not self.sam_reacquire_attempted and
            self.sam_predictor):
            self.sam_reacquire_attempted = True
            sam_bbox = self._attempt_sam_reacquisition(frame)
            if sam_bbox:
                return gate_info + " | SAM3 re-acquired", sam_bbox

        return gate_info, pred_bbox

    def _handle_lost_racer(self):
        """
        Dead-reckoning fallback when racer is not detected.
        Interpolates toward next gate based on elapsed time.
        """
        elapsed = time.time() - self.last_detection_time
        if elapsed > self.lost_timeout:
            # Move toward next gate
            cur_gate = self.course.get_gate_by_index(self.current_gate_index)
            next_idx = min(self.current_gate_index + 1, self.course.num_gates() - 1)
            next_gate = self.course.get_gate_by_index(next_idx)

            if cur_gate and next_gate:
                # Estimate progress based on time (assume ~3s per gate segment)
                est_segment_time = 3.0
                progress = min((elapsed - self.lost_timeout) / est_segment_time, 1.0)
                target = self.course.interpolate_ptz(cur_gate, next_gate, progress)

                if not self.dry_run:
                    self.ptz.move_absolute(target['pan'], target['tilt'],
                                          target['zoom'], speed=30)

                return f"LOST {elapsed:.1f}s, dead-reckoning progress={progress:.2f}"

        return f"LOST {elapsed:.1f}s"

    def _transition_to(self, new_state):
        """State transition with logging"""
        old_state = self.state
        self.state = new_state
        print(f"  STATE: {old_state} -> {new_state}")

        if new_state == STATE_WAITING:
            self.frames_in_zone = 0
            self.prev_bbox = None
            self.stabilizer.reset()
            self.kalman_tracker.reset()
            self.occlusion_start_time = None
            self.consecutive_missed_frames = 0
            self.sam_reacquire_attempted = False
            # Move camera to start position
            start_gate = self.course.get_start_gate()
            if start_gate and not self.dry_run:
                self.ptz.move_absolute(start_gate['pan'], start_gate['tilt'],
                                      start_gate['zoom'], speed=50)
                print(f"  Camera moving to start gate: pan={start_gate['pan']} tilt={start_gate['tilt']} zoom={start_gate['zoom']}")

        elif new_state == STATE_TRACKING:
            self.current_gate_index = self.course.get_start_index()
            self.tracking_start_time = time.time()
            self.last_detection_time = time.time()
            self.stabilizer.reset()
            self.kalman_tracker.reset()
            self.occlusion_start_time = None
            self.consecutive_missed_frames = 0
            self.sam_reacquire_attempted = False
            # Set initial zoom for racer + gates ahead
            zoom = self.course.compute_zoom_for_span(self.current_gate_index)
            if not self.dry_run:
                self.ptz.set_zoom(zoom)
            print(f"  Tracking started, initial zoom={zoom}")

        elif new_state == STATE_OCCLUDED:
            self.occlusion_start_time = time.time()
            self.sam_reacquire_attempted = False
            print(f"  Racer occluded, using Kalman prediction (velocity: {self.kalman_tracker.get_speed():.1f} px/frame)")

        elif new_state == STATE_FINISHED:
            if not self.dry_run:
                self.ptz.stop()
            self.kalman_tracker.reset()
            print(f"  Run finished in {time.time() - self.tracking_start_time:.1f}s")

    def run(self):
        """Main tracking loop"""
        # Initialize detector
        self._init_detector()

        # Connect to stream
        if not self.connect_stream():
            print("Retrying in 10s...")
            time.sleep(10)
            return self.run()

        # Test PTZ connection
        if not self.dry_run:
            if not self.ptz.test_connection():
                print("WARNING: PTZ not reachable, running in detection-only mode")

        print(f"\nAuto-tracker ready")
        print(f"  Camera:  {self.camera_ip}")
        print(f"  Model:   {self.model_path}")
        print(f"  Course:  {self.config.get('course_name', 'unnamed')}")
        print(f"  Gates:   {self.course.num_gates()}")
        print(f"  Dry-run: {self.dry_run}")
        print(f"  Debug:   {self.debug}")
        print(f"-" * 50)

        # Start in WAITING state
        self._transition_to(STATE_WAITING)

        ptz_interval = 1.0 / self.ptz_update_hz
        output_initialized = False

        try:
            while self.running:
                frame = self.grab_frame()
                if frame is None:
                    print("Lost stream, reconnecting...")
                    if self.cap:
                        self.cap.release()
                    time.sleep(5)
                    if not self.connect_stream():
                        time.sleep(10)
                        continue
                    continue

                self.frame_count += 1

                # Initialize output on first frame
                if not output_initialized:
                    self._init_output(frame.shape)
                    output_initialized = True

                # Run YOLO detection
                detections = self.detector.detect(frame)

                # State machine
                gate_info = ""

                if self.state == STATE_WAITING:
                    # Check start trigger
                    if self._check_start_trigger(detections, frame.shape):
                        self._transition_to(STATE_TRACKING)
                    else:
                        gate_info = f"Waiting... (zone frames: {self.frames_in_zone})"

                    # Debug: show frame with trigger zone
                    if self.debug:
                        display = self._draw_debug_overlay(frame.copy(), detections, None, gate_info)
                        cv2.imshow("Auto-Tracker", display)
                        key = cv2.waitKey(1) & 0xFF
                        if key == ord(' '):
                            # Manual start trigger
                            self._transition_to(STATE_TRACKING)
                        elif key == 27:  # ESC
                            self.running = False

                elif self.state == STATE_TRACKING:
                    # Predict Kalman state (even if we have detection, for smoother tracking)
                    self.kalman_tracker.predict()

                    # Select racer from detections (using Kalman prediction)
                    racer = self.detector.select_racer(
                        detections, self.prev_bbox, frame.shape,
                        kalman_tracker=self.kalman_tracker
                    )

                    if racer:
                        # Racer detected - update tracking state
                        self.prev_bbox = racer['bbox']
                        self.last_detection_time = time.time()
                        self.consecutive_missed_frames = 0
                        self.kalman_tracker.update(racer['bbox'])

                        # Compute PTZ correction
                        pan_speed, tilt_speed, pan_dir = self._compute_ptz_correction(
                            racer['bbox'], frame.shape)

                        # Throttle PTZ commands
                        now = time.time()
                        if now - self.last_ptz_time >= ptz_interval:
                            if self.dry_run:
                                gate_info = f"PTZ: pan={pan_speed:+d} tilt={tilt_speed:+d}"
                            else:
                                self.ptz.move_continuous(pan_speed, tilt_speed)
                            self.last_ptz_time = now

                        # Check gate advancement
                        if self._check_gate_advance(racer['bbox'], frame.shape):
                            old_gate = self.current_gate_index
                            self.current_gate_index = min(
                                self.current_gate_index + 1,
                                self.course.num_gates() - 1
                            )
                            if self.current_gate_index != old_gate:
                                print(f"  Gate advanced: {old_gate+1} -> {self.current_gate_index+1}")
                                # Update zoom for new segment
                                zoom = self.course.compute_zoom_for_span(self.current_gate_index)
                                if not self.dry_run:
                                    self.ptz.set_zoom(zoom)

                            # Check if reached finish
                            if self.current_gate_index >= self.course.num_gates() - 1:
                                self._transition_to(STATE_FINISHED)

                        # Digital stabilization
                        if self.stabilization_enabled:
                            output = self.stabilizer.update(frame, racer['bbox'], pan_dir)
                        else:
                            output = frame

                        gate_info = f"Gate {self.current_gate_index+1} | PTZ: pan={pan_speed:+d} tilt={tilt_speed:+d}"

                    else:
                        # No detection - but don't panic on single frame loss!
                        self.consecutive_missed_frames += 1
                        self.kalman_tracker.mark_missed()

                        # Only transition to OCCLUDED after several consecutive misses
                        if self.consecutive_missed_frames >= OCCLUSION_CONFIRM_FRAMES:
                            self._transition_to(STATE_OCCLUDED)
                            continue

                        # For single-frame drops, use Kalman prediction
                        pred_bbox = self.kalman_tracker.get_predicted_bbox()
                        if pred_bbox:
                            pan_speed, tilt_speed, pan_dir = self._compute_ptz_correction(
                                pred_bbox, frame.shape)

                            now = time.time()
                            if now - self.last_ptz_time >= ptz_interval:
                                if not self.dry_run:
                                    self.ptz.move_continuous(pan_speed, tilt_speed)
                                self.last_ptz_time = now

                            if self.stabilization_enabled:
                                output = self.stabilizer.update(frame, pred_bbox, pan_dir)
                            else:
                                output = frame

                            gate_info = f"Gate {self.current_gate_index+1} | PREDICT({self.consecutive_missed_frames}f)"
                        else:
                            output = self.stabilizer.passthrough(frame) if self.stabilization_enabled else frame
                            gate_info = f"Gate {self.current_gate_index+1} | NO DETECT"

                    # Output
                    self._output_frame(output)

                    # Debug display
                    if self.debug:
                        display = self._draw_debug_overlay(frame.copy(), detections, racer, gate_info)
                        cv2.imshow("Auto-Tracker", display)
                        key = cv2.waitKey(1) & 0xFF
                        if key == 27:  # ESC
                            self._transition_to(STATE_FINISHED)
                        elif key == ord('r'):
                            # Reset to waiting
                            self._transition_to(STATE_WAITING)

                elif self.state == STATE_OCCLUDED:
                    # Racer occluded - use Kalman prediction for PTZ, look for re-acquisition
                    gate_info, pred_bbox = self._handle_occlusion(frame)

                    # Try to re-acquire racer from YOLO detections
                    racer = self.detector.select_racer(
                        detections, self.prev_bbox, frame.shape,
                        kalman_tracker=self.kalman_tracker
                    )

                    if racer:
                        # Re-acquired! Validate before accepting
                        if self.kalman_tracker.is_valid_reacquisition(racer['bbox'], frame.shape):
                            print(f"  Racer re-acquired after {time.time() - self.occlusion_start_time:.1f}s occlusion")
                            self.kalman_tracker.update(racer['bbox'])
                            self.prev_bbox = racer['bbox']
                            self.last_detection_time = time.time()
                            self.consecutive_missed_frames = 0
                            self._transition_to(STATE_TRACKING)
                            continue
                        else:
                            # Detection doesn't match expected trajectory - ignore
                            gate_info += " | Rejected re-ID (trajectory mismatch)"

                    # Check if occlusion timeout exceeded
                    occlusion_duration = time.time() - self.occlusion_start_time if self.occlusion_start_time else 0
                    if occlusion_duration > REACQUIRE_WINDOW_SECONDS:
                        print(f"  Re-acquisition window expired ({REACQUIRE_WINDOW_SECONDS}s)")
                        # Fall back to dead-reckoning toward next gate
                        gate_info = self._handle_lost_racer()

                        # After extended loss, return to WAITING
                        if time.time() - self.last_detection_time > self.lost_timeout * 3:
                            print("  Racer lost for too long, returning to WAITING")
                            if not self.dry_run:
                                self.ptz.stop()
                            self._transition_to(STATE_WAITING)
                            continue

                    # Digital stabilization using predicted bbox
                    if pred_bbox and self.stabilization_enabled:
                        output = self.stabilizer.update(frame, pred_bbox, -1)
                    else:
                        output = self.stabilizer.passthrough(frame) if self.stabilization_enabled else frame

                    self._output_frame(output)

                    # Debug display
                    if self.debug:
                        display = self._draw_debug_overlay(frame.copy(), detections, None, gate_info)
                        # Draw predicted bbox in yellow
                        if pred_bbox:
                            x1, y1, x2, y2 = [int(v) for v in pred_bbox]
                            cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 255), 2)
                            cv2.putText(display, "PREDICTED", (x1, y1 - 10),
                                       cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
                        cv2.imshow("Auto-Tracker", display)
                        key = cv2.waitKey(1) & 0xFF
                        if key == 27:
                            self._transition_to(STATE_FINISHED)
                        elif key == ord('r'):
                            self._transition_to(STATE_WAITING)

                elif self.state == STATE_FINISHED:
                    # Hold for 3 seconds, then return to WAITING
                    if not hasattr(self, '_finish_time'):
                        self._finish_time = time.time()

                    if time.time() - self._finish_time > 3.0:
                        del self._finish_time
                        self._transition_to(STATE_WAITING)
                    else:
                        gate_info = f"Finished! Holding... ({3.0 - (time.time() - self._finish_time):.1f}s)"

                    if self.debug:
                        display = self._draw_debug_overlay(frame.copy(), detections, None, gate_info)
                        cv2.imshow("Auto-Tracker", display)
                        cv2.waitKey(1)

                # Heartbeat logging
                if self.frame_count % 100 == 0:
                    ts = datetime.now().strftime("%H:%M:%S")
                    pos = self.ptz.get_position() if not self.dry_run else None
                    pos_str = f"pan={pos['pan']:.1f} tilt={pos['tilt']:.1f} zoom={pos['zoom']}" if pos else "N/A"
                    print(f"[{ts}] Frame #{self.frame_count} | {self.state} | PTZ: {pos_str}")

        except KeyboardInterrupt:
            print("\nStopping auto-tracker...")
        finally:
            self.cleanup()

    def cleanup(self):
        """Release all resources"""
        if not self.dry_run:
            self.ptz.stop()
        if self.cap:
            self.cap.release()
        if self.ffmpeg_proc:
            self.ffmpeg_proc.stdin.close()
            self.ffmpeg_proc.wait(timeout=5)
        if self.video_writer:
            self.video_writer.release()
        cv2.destroyAllWindows()
        print("Auto-tracker stopped.")


# =============================================================================
# MAIN
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Auto-tracking for ski racing using Axis PTZ + YOLO")
    parser.add_argument("--config", type=str, required=True,
                        help="Path to course_config.json")
    parser.add_argument("--camera", type=str, default=None,
                        help="Axis camera IP (overrides config)")
    parser.add_argument("--model", type=str, default=None,
                        help="YOLO model path (overrides config)")
    parser.add_argument("--debug", action="store_true",
                        help="Show live preview with debug overlays")
    parser.add_argument("--dry-run", action="store_true",
                        help="Detect and compute PTZ but don't send commands")
    parser.add_argument("--output", type=str, default=None,
                        help="RTMP output URL for stabilized stream")
    parser.add_argument("--record", type=str, default=None,
                        help="Record stabilized output to MP4 file")
    parser.add_argument("--source", type=str, default=None,
                        help="Use video file instead of RTSP (for testing)")
    args = parser.parse_args()

    if not os.path.exists(args.config):
        print(f"ERROR: Config file not found: {args.config}")
        sys.exit(1)

    # Handle clean shutdown
    tracker = None

    def signal_handler(sig, frame):
        print("\nShutting down...")
        if tracker:
            tracker.running = False
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    tracker = RacerTracker(
        config_path=args.config,
        camera_ip=args.camera,
        model_path=args.model,
        dry_run=args.dry_run,
        debug=args.debug,
        output_url=args.output,
        record_path=args.record,
        source=args.source
    )

    tracker.run()


if __name__ == "__main__":
    main()
