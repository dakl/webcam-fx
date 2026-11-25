"""A coloured light on each fingertip.

The hand tracker finds the five fingertips of each hand, and a soft glow is
drawn on top of the picture at each one, with "screen" blending so the glow
brightens without washing out. Nothing else in the picture changes.
Press q to quit. With --cam, the picture also goes to the OBS Virtual Camera,
not mirrored; the local window stays mirrored.
"""

import argparse
import time

import cv2
import mediapipe as mp
import numpy as np
import pyvirtualcam
from mediapipe.tasks.python import BaseOptions, vision

from camera import DEFAULT_CAMERA, open_camera

FINGERTIPS = [4, 8, 12, 16, 20]  # thumb, index, middle, ring, little
FINGER_COLOURS = [  # BGR, 0–1, one per finger
    (0.35, 0.35, 1.0),  # red
    (0.25, 0.65, 1.0),  # orange
    (0.35, 0.95, 1.0),  # yellow
    (0.45, 1.0, 0.45),  # green
    (1.0, 0.6, 0.35),  # blue
]
WORK_WIDTH = 480  # the glow is drawn at this width, then scaled up; it is soft, so this costs no detail
GLOW_RADIUS = 18.0  # px at WORK_WIDTH
CORE_RADIUS = 3.0  # the small bright centre
STRENGTH = 0.9


def glow_map(tips: list[tuple[float, float, int]], width: int, height: int) -> np.ndarray:
    """Light per pixel (BGR, 0–1) from glows at `tips`: (x, y) in px and a finger number."""
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float32)
    light = np.zeros((height, width, 3), np.float32)
    for x, y, finger in tips:
        d2 = (xs - x) ** 2 + (ys - y) ** 2
        glow = np.exp(-d2 / (2 * GLOW_RADIUS**2)) + np.exp(-d2 / (2 * CORE_RADIUS**2))
        light += glow[..., None] * np.array(FINGER_COLOURS[finger], np.float32)
    return np.clip(light * STRENGTH, 0, 1)


def screen_blend(frame: np.ndarray, light: np.ndarray) -> np.ndarray:
    """Brighten `frame` by `light` the way two projected images add: 1 - (1 - a)(1 - b)."""
    light8 = (light * 255 + 0.5).astype(np.uint8)
    return cv2.bitwise_not(cv2.multiply(cv2.bitwise_not(frame), cv2.bitwise_not(light8), scale=1 / 255))


def main(to_cam: bool, camera_name: str) -> None:
    hands_tracker = vision.HandLandmarker.create_from_options(
        vision.HandLandmarkerOptions(
            base_options=BaseOptions(model_asset_path="hand_landmarker.task"),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
        )
    )
    cap = open_camera(camera_name)
    W, H = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    w, h = WORK_WIDTH, round(H * WORK_WIDTH / W)
    cam = pyvirtualcam.Camera(W, H, 30, fmt=pyvirtualcam.PixelFormat.BGR) if to_cam else None
    if cam:
        print(f"Sending to {cam.device}")

    t0, fps, last_tick = time.time(), 0.0, time.time()
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if not to_cam:
            frame = cv2.flip(frame, 1)
        image = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        hands = hands_tracker.detect_for_video(image, int((time.time() - t0) * 1000)).hand_landmarks
        tips = [(hand[t].x * w, hand[t].y * h, i) for hand in hands for i, t in enumerate(FINGERTIPS)]
        if tips:
            frame = screen_blend(frame, cv2.resize(glow_map(tips, w, h), (W, H)))

        if cam:
            cam.send(frame)
        now = time.time()
        fps, last_tick = 0.9 * fps + 0.1 / max(now - last_tick, 1e-6), now
        if cam:
            frame = cv2.flip(frame, 1)  # your own window is mirrored, like a meeting app's preview
        cv2.putText(frame, f"{fps:4.1f} fps", (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
        cv2.imshow("finger lights", frame)
        if cv2.waitKey(1) & 0xFF == ord("q"):
            break

    cap.release()
    if cam:
        cam.close()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cam", action="store_true", help="also send to the OBS Virtual Camera")
    parser.add_argument("--camera", default=DEFAULT_CAMERA, help="part of the input camera name")
    args = parser.parse_args()
    main(args.cam, args.camera)
