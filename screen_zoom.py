"""Zoom the Mac screen with a finger frame.

Make a rectangle with the thumbs and index fingers of both hands. The pointer
moves to the matching spot on the screen. Make the frame smaller to zoom in and
larger to zoom out. Take your hands away to zoom fully out.

It drives the macOS Zoom accessibility feature with Control + scroll, so it
needs, in System Settings → Accessibility → Zoom:
  - "Use scroll gesture with modifier keys to zoom" on, with Control
  - Zoom style: Full Screen
and Accessibility permission for the terminal app, to send scroll events.
It shows no window, so it stays out of a screen share. Stop it with Ctrl-C.
"""

import math
import time

import cv2
import mediapipe as mp
import numpy as np
import Quartz
from mediapipe.tasks.python import BaseOptions, vision

from camera import open_camera

THUMB_TIP, INDEX_TIP = 4, 8
SMOOTHING = 0.7
ZOOM_GAIN = 40.0  # scroll lines per doubling of frame size; tune by hand
CAMERA_MARGIN = 0.15  # the middle 70% of the camera picture covers the whole screen
HANDS_GONE_S = 0.6
ZOOM_OUT_LINES = -500  # more than enough to reach 1x; macOS stops there


def scroll_with_control(lines: int) -> None:
    event = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, lines)
    Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskControl)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)


def move_pointer(x: float, y: float) -> None:
    Quartz.CGWarpMouseCursorPosition((x, y))


def camera_to_screen(u: float, v: float, screen_w: float, screen_h: float) -> tuple[float, float]:
    """Map a 0–1 camera position to screen points, with a margin so the edges are reachable."""
    span = 1 - 2 * CAMERA_MARGIN
    u = min(max((u - CAMERA_MARGIN) / span, 0.0), 1.0)
    v = min(max((v - CAMERA_MARGIN) / span, 0.0), 1.0)
    return u * screen_w, v * screen_h


def frame_corners(hands, width: int, height: int) -> np.ndarray:
    pts = np.array([(p.x * width, p.y * height) for hand in hands for p in (hand[THUMB_TIP], hand[INDEX_TIP])])
    return np.array([*pts.min(0), *pts.max(0)])


def main() -> None:
    landmarker = vision.HandLandmarker.create_from_options(
        vision.HandLandmarkerOptions(
            base_options=BaseOptions(model_asset_path="hand_landmarker.task"),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
        )
    )
    cap = open_camera()
    bounds = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
    screen_w, screen_h = bounds.size.width, bounds.size.height

    box, last_size, owed_lines = None, None, 0.0
    last_seen, zoomed = 0.0, False
    t0 = time.time()
    print("Running. Frame the screen area with both hands. Ctrl-C to stop.")
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break
            frame = cv2.flip(frame, 1)
            H, W = frame.shape[:2]
            rgb = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
            res = landmarker.detect_for_video(rgb, int((time.time() - t0) * 1000))
            now = time.time()

            if len(res.hand_landmarks) == 2:
                new = frame_corners(res.hand_landmarks, W, H)
                box = new if box is None else SMOOTHING * box + (1 - SMOOTHING) * new
                x0, y0, x1, y1 = box
                size = math.hypot(x1 - x0, y1 - y0)
                move_pointer(*camera_to_screen((x0 + x1) / 2 / W, (y0 + y1) / 2 / H, screen_w, screen_h))
                if last_size is not None and size > 1:
                    owed_lines += -math.log2(size / last_size) * ZOOM_GAIN
                    whole = int(owed_lines)
                    if whole:
                        scroll_with_control(whole)
                        owed_lines -= whole
                        zoomed = True
                last_size, last_seen = size, now
            elif now - last_seen > HANDS_GONE_S:
                if zoomed:
                    scroll_with_control(ZOOM_OUT_LINES)
                    zoomed = False
                box, last_size, owed_lines = None, None, 0.0
    except KeyboardInterrupt:
        pass
    finally:
        if zoomed:
            scroll_with_control(ZOOM_OUT_LINES)
        cap.release()


if __name__ == "__main__":
    main()
