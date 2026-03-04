#!/usr/bin/env python3
"""
Simulated occlusion test for autotracker.

Loads a video, runs YOLO detection, and simulates occlusion by:
1. Masking the racer bbox for N frames (simulates coach blocking view)
2. Verifying Kalman prediction continues correctly
3. Verifying re-acquisition after occlusion ends

Usage:
    python3 test_occlusion_sim.py ../videos-examples/20260125_100223_8E8E.mkv
    python3 test_occlusion_sim.py ../videos-examples/20260125_100223_8E8E.mkv --occlusion-frames 30
"""

import cv2
import numpy as np
import argparse
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from auto_tracker import KalmanTracker, YOLODetector


def run_occlusion_test(video_path, occlusion_start=60, occlusion_frames=45, show_video=True):
    """
    Run occlusion simulation test.

    Args:
        video_path: Path to test video
        occlusion_start: Frame number to start simulated occlusion
        occlusion_frames: Duration of simulated occlusion in frames
        show_video: Whether to display video during test
    """
    print(f"Loading video: {video_path}")
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        print(f"ERROR: Could not open video: {video_path}")
        return False

    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

    print(f"Video: {w}x{h} @ {fps:.0f}fps, {total_frames} frames")
    print(f"Occlusion: frames {occlusion_start}-{occlusion_start + occlusion_frames}")
    print()

    # Initialize components
    print("Loading YOLO model...")
    detector = YOLODetector(model_path='yolov8n.pt', conf_threshold=0.40)
    kalman = KalmanTracker()

    # Test state
    frame_num = 0
    tracking_active = False
    occlusion_active = False
    last_real_bbox = None
    predictions_during_occlusion = []
    reacquired = False

    # Metrics
    prediction_errors = []

    print("\nRunning test...")
    print("-" * 60)

    while True:
        ret, frame = cap.read()
        if not ret:
            break

        frame_num += 1
        display = frame.copy()

        # Determine if we're in simulated occlusion period
        in_occlusion = occlusion_start <= frame_num < occlusion_start + occlusion_frames

        # Run YOLO detection
        detections = detector.detect(frame)

        # Select racer (using Kalman if tracking)
        racer = detector.select_racer(
            detections,
            last_real_bbox,
            frame.shape,
            kalman_tracker=kalman if tracking_active else None
        )

        # Simulate occlusion: pretend we didn't detect anything
        if in_occlusion and racer:
            # Store the real detection for measuring prediction accuracy
            last_real_bbox = racer['bbox']
            # But pretend we didn't see it
            racer = None
            if not occlusion_active:
                occlusion_active = True
                print(f"[Frame {frame_num}] OCCLUSION START - hiding racer detection")

        if not in_occlusion and occlusion_active:
            occlusion_active = False
            print(f"[Frame {frame_num}] OCCLUSION END")

        # Process detection/prediction
        if racer:
            # Update Kalman with real detection
            kalman.predict()
            kalman.update(racer['bbox'])
            last_real_bbox = racer['bbox']

            if not tracking_active:
                tracking_active = True
                print(f"[Frame {frame_num}] Tracking started")

            if kalman.frames_since_detection == 1 and predictions_during_occlusion:
                # Just re-acquired after occlusion
                reacquired = True
                print(f"[Frame {frame_num}] RE-ACQUIRED after {len(predictions_during_occlusion)} frames")

                # Calculate prediction accuracy
                if predictions_during_occlusion and last_real_bbox:
                    final_pred = predictions_during_occlusion[-1]
                    real_cx = (last_real_bbox[0] + last_real_bbox[2]) / 2
                    real_cy = (last_real_bbox[1] + last_real_bbox[3]) / 2
                    error = ((final_pred[0] - real_cx)**2 + (final_pred[1] - real_cy)**2)**0.5
                    print(f"           Final prediction error: {error:.1f} pixels")
                    prediction_errors.append(error)

                predictions_during_occlusion = []

            # Draw detection in green
            x1, y1, x2, y2 = [int(v) for v in racer['bbox']]
            cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 0), 3)
            cv2.putText(display, "RACER", (x1, y1-10),
                       cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)

        elif tracking_active:
            # No detection - use Kalman prediction
            kalman.predict()
            kalman.mark_missed()

            pred = kalman.get_predicted_centroid()
            pred_bbox = kalman.get_predicted_bbox()

            if pred:
                predictions_during_occlusion.append(pred)

                # Calculate error if we have ground truth (during simulated occlusion)
                if in_occlusion and last_real_bbox:
                    real_cx = (last_real_bbox[0] + last_real_bbox[2]) / 2
                    real_cy = (last_real_bbox[1] + last_real_bbox[3]) / 2
                    error = ((pred[0] - real_cx)**2 + (pred[1] - real_cy)**2)**0.5
                    prediction_errors.append(error)

                # Draw prediction in yellow
                if pred_bbox:
                    x1, y1, x2, y2 = [int(v) for v in pred_bbox]
                    cv2.rectangle(display, (x1, y1), (x2, y2), (0, 255, 255), 2)
                    cv2.putText(display, f"PREDICTED (miss:{kalman.frames_since_detection})",
                               (x1, y1-10), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)

        # Draw all detections in blue (including ones we're ignoring during occlusion)
        for det in detections:
            x1, y1, x2, y2 = [int(v) for v in det['bbox']]
            cv2.rectangle(display, (x1, y1), (x2, y2), (255, 0, 0), 1)

        # Status bar
        vx, vy = kalman.get_velocity() if kalman.state is not None else (0, 0)
        speed = kalman.get_speed() if kalman.state is not None else 0
        status = "OCCLUDED" if in_occlusion else ("TRACKING" if tracking_active else "WAITING")

        info = f"Frame {frame_num}/{total_frames} | {status} | v=({vx:.0f},{vy:.0f}) speed={speed:.0f}"
        cv2.putText(display, info, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)

        if in_occlusion:
            occ_frame = frame_num - occlusion_start + 1
            occ_info = f"SIMULATED OCCLUSION: {occ_frame}/{occlusion_frames}"
            cv2.putText(display, occ_info, (10, 60), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        # Show frame
        if show_video:
            cv2.imshow("Occlusion Test", display)
            key = cv2.waitKey(1) & 0xFF
            if key == 27:  # ESC
                break
            elif key == ord(' '):
                # Pause
                cv2.waitKey(0)

    cap.release()
    cv2.destroyAllWindows()

    # Print results
    print()
    print("=" * 60)
    print("TEST RESULTS")
    print("=" * 60)
    print(f"Tracking started: {'Yes' if tracking_active else 'No'}")
    print(f"Re-acquired after occlusion: {'Yes' if reacquired else 'No'}")

    if prediction_errors:
        avg_error = sum(prediction_errors) / len(prediction_errors)
        max_error = max(prediction_errors)
        print(f"Prediction errors during occlusion:")
        print(f"  Average: {avg_error:.1f} pixels")
        print(f"  Maximum: {max_error:.1f} pixels")
        print(f"  Samples: {len(prediction_errors)}")

        # Pass/fail based on prediction accuracy
        if avg_error < 100 and reacquired:
            print("\n[PASS] Occlusion handling working correctly")
            return True
        else:
            print("\n[FAIL] Prediction error too high or failed to re-acquire")
            return False
    else:
        print("\n[SKIP] No occlusion predictions to evaluate")
        return None


def main():
    parser = argparse.ArgumentParser(description="Simulated occlusion test")
    parser.add_argument("video", help="Path to test video")
    parser.add_argument("--occlusion-start", type=int, default=60,
                       help="Frame to start simulated occlusion (default: 60)")
    parser.add_argument("--occlusion-frames", type=int, default=45,
                       help="Duration of occlusion in frames (default: 45 = ~1.5s)")
    parser.add_argument("--no-display", action="store_true",
                       help="Run without video display")
    args = parser.parse_args()

    result = run_occlusion_test(
        args.video,
        occlusion_start=args.occlusion_start,
        occlusion_frames=args.occlusion_frames,
        show_video=not args.no_display
    )

    sys.exit(0 if result else 1)


if __name__ == "__main__":
    main()
