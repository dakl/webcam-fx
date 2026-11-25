"""Finger-frame webcam effects.

Make a rectangle with the thumbs and index fingers of both hands. The image
inside it gets an effect. A pinch with the right hand switches to the next
effect; a pinch with the left hand turns the picture outside the frame black
or back. Keys: n next effect, b black outside, q quit.
Pass a number of seconds to stop on its own and print fps.
With --cam, the picture also goes to the OBS Virtual Camera, not mirrored,
for use in meetings. The local window stays mirrored and shows the status line.
"""

import argparse
import time

import cv2
import mediapipe as mp
import numpy as np
import pyvirtualcam
from camera import DEFAULT_CAMERA, open_camera
from mediapipe.tasks.python import BaseOptions, vision

THUMB_TIP, INDEX_TIP = 4, 8
MIN_SIDE_PX = 40
PINCH_PX = 25
SMOOTHING = 0.7


def pixelate(c):
    h, w = c.shape[:2]
    s = cv2.resize(c, (max(1, w // 12), max(1, h // 12)))
    return cv2.resize(s, (w, h), interpolation=cv2.INTER_NEAREST)


def thermal(c):
    return cv2.applyColorMap(cv2.cvtColor(c, cv2.COLOR_BGR2GRAY), cv2.COLORMAP_INFERNO)


def edges(c):
    return cv2.cvtColor(cv2.Canny(cv2.cvtColor(c, cv2.COLOR_BGR2GRAY), 80, 160), cv2.COLOR_GRAY2BGR)


def ascii_(c, cell=8, chars=" .:-=+*#%@"):
    out = np.zeros_like(c)
    g = cv2.cvtColor(c, cv2.COLOR_BGR2GRAY)
    for y in range(0, c.shape[0] - cell, cell):
        for x in range(0, c.shape[1] - cell, cell):
            ch = chars[int(g[y : y + cell, x : x + cell].mean()) * (len(chars) - 1) // 255]
            cv2.putText(out, ch, (x, y + cell), cv2.FONT_HERSHEY_PLAIN, 0.6, (0, 255, 0), 1)
    return out


def comic(c):
    smooth = cv2.bilateralFilter(posterize(c, 4), 7, 60, 60)
    lines = cv2.adaptiveThreshold(cv2.medianBlur(cv2.cvtColor(c, cv2.COLOR_BGR2GRAY), 5), 255,
                                  cv2.ADAPTIVE_THRESH_MEAN_C, cv2.THRESH_BINARY, 9, 4)
    return cv2.bitwise_and(smooth, smooth, mask=lines)


def invert(c):
    return cv2.bitwise_not(c)


def rgb_split(c, shift=12):
    b, g, r = cv2.split(c)
    return cv2.merge([np.roll(b, -shift, axis=1), g, np.roll(r, shift, axis=1)])


def blur(c):
    return cv2.GaussianBlur(c, (0, 0), 12)


def night_vision(c):
    g = cv2.equalizeHist(cv2.cvtColor(c, cv2.COLOR_BGR2GRAY))
    noisy = cv2.add(g, np.random.randint(0, 40, g.shape, dtype=np.uint8))
    noisy[::3] //= 2  # scanlines
    return cv2.merge([noisy // 4, noisy, noisy // 4])


def sepia(c):
    m = np.array([[0.131, 0.534, 0.272], [0.168, 0.686, 0.349], [0.189, 0.769, 0.393]])  # BGR in, BGR out
    return cv2.transform(c, m)


def posterize(c, levels=4):
    step = 256 // levels
    return (c // step * step + step // 2).astype(np.uint8)


# Three mirrors in an equilateral triangle, centred on the origin with inradius 1.
# Outward normals of its edges point down, up-right and up-left.
_EDGE_NORMALS = np.array([[0.0, 1.0], [np.cos(np.pi / 6), -0.5], [-np.cos(np.pi / 6), -0.5]], np.float32)
# Reflecting across two neighbouring parallel mirror lines (3 apart) moves a point by 6 along a normal,
# so the pattern repeats on this lattice.
_LATTICE = 6 * _EDGE_NORMALS[:2].T
_LATTICE_INV = np.linalg.inv(_LATTICE)


def fold_into_triangle(px: np.ndarray, py: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Map every point to its mirror image inside the triangle, as three mirrors would."""
    a = _LATTICE_INV[0, 0] * px + _LATTICE_INV[0, 1] * py
    b = _LATTICE_INV[1, 0] * px + _LATTICE_INV[1, 1] * py
    a, b = a - np.round(a), b - np.round(b)
    px, py = _LATTICE[0, 0] * a + _LATTICE[0, 1] * b, _LATTICE[1, 0] * a + _LATTICE[1, 1] * b
    for _ in range(6):
        for nx, ny in _EDGE_NORMALS:
            over = np.maximum(px * nx + py * ny - 1, 0)
            px, py = px - 2 * over * nx, py - 2 * over * ny
    return px, py


def kaleidoscope(c, tiles_across=4, turns_per_second=0.03):
    """A three-mirror kaleidoscope: one triangle of the crop, reflected into a repeating pattern.

    The triangle is taken from the middle of the crop and slowly turns, so the pattern changes.
    """
    h, w = c.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    out_scale = w / (tiles_across * 2 * np.sqrt(3))  # px per unit; a triangle side is 2*sqrt(3) units
    px, py = fold_into_triangle((xs - w / 2) / out_scale, (ys - h / 2) / out_scale)
    src_scale = min(w, h) / 2 / 2  # the triangle's corners (radius 2) reach the crop's inner circle
    turn = time.time() * turns_per_second * 2 * np.pi
    cos_t, sin_t = np.cos(turn), np.sin(turn)
    map_x = (w / 2 + src_scale * (cos_t * px - sin_t * py)).astype(np.float32)
    map_y = (h / 2 + src_scale * (sin_t * px + cos_t * py)).astype(np.float32)
    return cv2.remap(c, map_x, map_y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)


FX = [
    ("pixelate", pixelate), ("thermal", thermal), ("edges", edges), ("ascii", ascii_),
    ("comic", comic), ("invert", invert), ("rgb split", rgb_split), ("blur", blur),
    ("night vision", night_vision), ("sepia", sepia), ("posterize", posterize), ("kaleidoscope", kaleidoscope),
]


def main(run_seconds: float | None, to_cam: bool, camera_name: str) -> None:
    landmarker = vision.HandLandmarker.create_from_options(
        vision.HandLandmarkerOptions(
            base_options=BaseOptions(model_asset_path="hand_landmarker.task"),
            running_mode=vision.RunningMode.VIDEO,
            num_hands=2,
        )
    )
    cap = open_camera(camera_name)
    width, height = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cam = pyvirtualcam.Camera(width, height, 30, fmt=pyvirtualcam.PixelFormat.BGR) if to_cam else None
    if cam:
        print(f"Sending to {cam.device}")

    fx, box, black_outside = 0, None, False
    pinched = {"Left": False, "Right": False}
    # MediaPipe names hands as if the picture is mirrored; --cam sends it unmirrored, so swap.
    effects_hand = "Left" if to_cam else "Right"
    t0 = time.time()
    frames, two_hand_frames, fps = 0, 0, 0.0
    last_tick = t0

    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if not to_cam:
            frame = cv2.flip(frame, 1)
        H, W = frame.shape[:2]
        rgb = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(frame, cv2.COLOR_BGR2RGB))
        res = landmarker.detect_for_video(rgb, int((time.time() - t0) * 1000))
        if len(res.hand_landmarks) == 2:
            two_hand_frames += 1
            pts = np.array(
                [(p.x * W, p.y * H) for hand in res.hand_landmarks for p in (hand[THUMB_TIP], hand[INDEX_TIP])]
            )
            new = np.array([*pts.min(0), *pts.max(0)])
            box = new if box is None else SMOOTHING * box + (1 - SMOOTHING) * new
            for hand, handedness in zip(res.hand_landmarks, res.handedness):
                side = handedness[0].category_name
                a, b = hand[THUMB_TIP], hand[INDEX_TIP]
                is_pinch = np.hypot((a.x - b.x) * W, (a.y - b.y) * H) < PINCH_PX
                if is_pinch and not pinched.get(side, False):
                    if side == effects_hand:
                        fx = (fx + 1) % len(FX)
                    else:
                        black_outside = not black_outside
                pinched[side] = is_pinch
        else:
            box = None

        if box is not None:
            x0, y0, x1, y1 = np.clip(box, 0, [W, H, W, H]).astype(int)
            if x1 - x0 > MIN_SIDE_PX and y1 - y0 > MIN_SIDE_PX:
                inside = FX[fx][1](frame[y0:y1, x0:x1].copy())
                if black_outside:
                    frame[:] = 0
                frame[y0:y1, x0:x1] = inside
                cv2.rectangle(frame, (x0, y0), (x1, y1), (255, 255, 255), 2)

        if cam:
            cam.send(frame)

        frames += 1
        now = time.time()
        fps = 0.9 * fps + 0.1 * (1 / max(now - last_tick, 1e-6))
        last_tick = now
        status = f"{fps:4.1f} fps  hands: {len(res.hand_landmarks)}  {FX[fx][0]}{'  black' if black_outside else ''}"
        if cam:
            frame = cv2.flip(frame, 1)  # your own window is mirrored, like a meeting app's preview
        cv2.putText(frame, status, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)

        cv2.imshow("frame fx", frame)
        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key == ord("n"):
            fx = (fx + 1) % len(FX)
        if key == ord("b"):
            black_outside = not black_outside
        if run_seconds is not None and now - t0 > run_seconds:
            break

    elapsed = time.time() - t0
    print(f"{frames} frames in {elapsed:.1f} s = {frames / elapsed:.1f} fps; two hands seen in {two_hand_frames} frames")
    cap.release()
    if cam:
        cam.close()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", nargs="?", type=float, help="stop after this many seconds")
    parser.add_argument("--cam", action="store_true", help="also send to the OBS Virtual Camera")
    parser.add_argument("--camera", default=DEFAULT_CAMERA, help="part of the input camera name")
    args = parser.parse_args()
    main(args.seconds, args.cam, args.camera)
