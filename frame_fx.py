"""Finger-frame webcam effects.

Make a rectangle with the thumbs and index fingers of both hands. The image
inside it gets an effect. A pinch with the right hand switches to the next
effect; pinch and hold to open a list of effects, move the hand down or up to
pick one, and let go to keep it. A pinch with the left hand turns the picture
outside the frame black or back. Keys: n next effect, b black outside, h hide or show help, q quit.
Your own window shows the tracked hands and a gauge for each pinch; the
virtual camera gets the picture without them.
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
from gestures import INDEX_TIP, MENU_STEP, THUMB_TIP, PinchMenu, PinchState, pinch_gap_cm
from mediapipe.tasks.python import BaseOptions, vision
from overlay import Flash, HandDrawing, draw_flash, draw_hand, draw_hint, draw_menu, hint_for

MIN_SIDE_PX = 40
SMOOTHING = 0.7
FREEZE_BELOW_CM = 7.0  # the frame holds still while a hand's thumb and index are this close
BOX_HOLD_S = 0.3  # keep the frame this long when tracking drops a hand for a moment
EFFECTS_COLOUR = (255, 200, 0)  # BGR, light blue
BLACK_COLOUR = (220, 80, 255)  # BGR, pink


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


def main(run_seconds: float | None, to_cam: bool, camera_name: str, log_path: str | None = None) -> None:
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

    log = open(log_path, "w", encoding="utf-8") if log_path else None
    if log:
        log.write("t,side,side_score,gap_cm,triggered,hands\n")
    menu, box, black_outside, menu_at = PinchMenu(count=len(FX)), None, False, (0.0, 0.0)
    pinches = {"Left": PinchState(), "Right": PinchState()}
    # MediaPipe names hands as if the picture is mirrored; --cam sends it unmirrored, so swap.
    effects_hand = "Left" if to_cam else "Right"
    show_help, flash, box_seen = True, None, 0.0
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
        now = time.time()

        drawings, closing = [], False
        seen_sides = set()
        if log and not res.hand_landmarks:
            log.write(f"{now - t0:.3f},none,,,,0\n")
        for hand, world, handedness in zip(res.hand_landmarks, res.hand_world_landmarks, res.handedness):
            side = handedness[0].category_name
            seen_sides.add(side)
            gap = pinch_gap_cm(world)
            closing |= gap < FREEZE_BELOW_CM
            is_effects = side == effects_hand
            triggered = pinches[side].update(gap)
            pinch_x = (hand[THUMB_TIP].x + hand[INDEX_TIP].x) / 2
            pinch_y = (hand[THUMB_TIP].y + hand[INDEX_TIP].y) / 2
            if log:
                log.write(f"{now - t0:.3f},{side},{handedness[0].score:.2f},{gap:.2f},{int(triggered)},{len(res.hand_landmarks)}\n")
            if is_effects:
                event = menu.update(pinches[side].closed, pinch_y, now)
                if menu.is_open:
                    menu_at = (pinch_x * W, menu.start_y * H)
                if event:
                    flash = Flash(FX[menu.selected][0], (pinch_x * W, pinch_y * H), now)
            elif triggered:
                black_outside = not black_outside
                flash = Flash(f"black {'on' if black_outside else 'off'}", (pinch_x * W, pinch_y * H), now)
            drawings.append(HandDrawing(
                points=np.array([(p.x * W, p.y * H) for p in hand]),
                colour=EFFECTS_COLOUR if is_effects else BLACK_COLOUR,
                action="next effect" if is_effects else "black outside",
                gap_cm=gap,
                pinched=pinches[side].closed,
                pinched_text=("" if menu.is_open else "let go: next, hold: list")
                if is_effects else "black outside - open to pinch again",
            ))
        for side in pinches.keys() - seen_sides:
            pinches[side].hand_lost()

        if len(res.hand_landmarks) == 2:
            two_hand_frames += 1
            box_seen = now
            if not (closing and box is not None):  # hold the frame still during a pinch
                pts = np.array(
                    [(p.x * W, p.y * H) for hand in res.hand_landmarks for p in (hand[THUMB_TIP], hand[INDEX_TIP])]
                )
                new = np.array([*pts.min(0), *pts.max(0)])
                box = new if box is None else SMOOTHING * box + (1 - SMOOTHING) * new
        elif now - box_seen > BOX_HOLD_S:
            box = None

        frame_ok = False
        if box is not None:
            x0, y0, x1, y1 = np.clip(box, 0, [W, H, W, H]).astype(int)
            if x1 - x0 > MIN_SIDE_PX and y1 - y0 > MIN_SIDE_PX:
                frame_ok = True
                inside = FX[menu.selected][1](frame[y0:y1, x0:x1].copy())
                if black_outside:
                    frame[:] = 0
                frame[y0:y1, x0:x1] = inside
                cv2.rectangle(frame, (x0, y0), (x1, y1), (255, 255, 255), 2)

        if cam:
            cam.send(frame)

        frames += 1
        fps = 0.9 * fps + 0.1 * (1 / max(now - last_tick, 1e-6))
        last_tick = now
        status = f"{fps:4.1f} fps  hands: {len(res.hand_landmarks)}  {FX[menu.selected][0]}{'  black' if black_outside else ''}"
        if cam:
            frame = cv2.flip(frame, 1)  # your own window is mirrored, like a meeting app's preview
        if show_help:
            for drawing in drawings:
                draw_hand(frame, drawing, mirror=bool(cam))
            draw_flash(frame, flash, mirror=bool(cam))
            if menu.is_open:
                draw_menu(frame, [name for name, _ in FX], menu.selected, menu.start_index, menu_at,
                          MENU_STEP * H, mirror=bool(cam))
            hint = "Move the pinch down or up to pick, open your fingers to keep it" if menu.is_open \
                else hint_for(len(res.hand_landmarks), frame_ok)
            draw_hint(frame, hint)
        cv2.putText(frame, status, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)

        cv2.imshow("frame fx", frame)
        key = cv2.waitKey(1) & 0xFF
        if key == ord("q"):
            break
        if key == ord("n"):
            menu.selected = (menu.selected + 1) % len(FX)
        if key == ord("b"):
            black_outside = not black_outside
        if key == ord("h"):
            show_help = not show_help
        if run_seconds is not None and now - t0 > run_seconds:
            break

    elapsed = time.time() - t0
    print(f"{frames} frames in {elapsed:.1f} s = {frames / elapsed:.1f} fps; two hands seen in {two_hand_frames} frames")
    cap.release()
    if log:
        log.close()
        print(f"Pinch log: {log_path}")
    if cam:
        cam.close()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", nargs="?", type=float, help="stop after this many seconds")
    parser.add_argument("--cam", action="store_true", help="also send to the OBS Virtual Camera")
    parser.add_argument("--camera", default=DEFAULT_CAMERA, help="part of the input camera name")
    parser.add_argument("--log", metavar="CSV", help="write each frame's pinch gap per hand to this file")
    args = parser.parse_args()
    main(args.seconds, args.cam, args.camera, args.log)
