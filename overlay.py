"""On-screen help for the local window: hand skeletons, pinch gauges and hints.

It is drawn only on what you see, never on the picture sent to the virtual camera.
Positions are given in the processed frame; `mirror` flips them to match a
mirrored window, so text is drawn the right way round.
"""

import time
from dataclasses import dataclass

import cv2
import numpy as np
from mediapipe.tasks.python import vision

from gestures import PINCH_ON_CM, pinch_progress

CONNECTIONS = [(c.start, c.end) for c in vision.HandLandmarksConnections.HAND_CONNECTIONS]
GREY = (150, 150, 150)
GREEN = (80, 230, 80)
FONT = cv2.FONT_HERSHEY_SIMPLEX
FLASH_S = 0.7


@dataclass(frozen=True)
class HandDrawing:
    points: np.ndarray  # 21 x 2, px in the processed frame
    colour: tuple[int, int, int]  # BGR
    action: str  # what this hand's pinch does
    gap_cm: float
    pinched: bool
    pinched_text: str  # shown while the pinch is held


@dataclass(frozen=True)
class Flash:
    text: str
    at: tuple[int, int]  # px in the processed frame
    started: float


def _to_view(x: float, y: float, width: int, mirror: bool) -> tuple[int, int]:
    return int(width - 1 - x if mirror else x), int(y)


def _label(img, text, org, colour, scale=0.6):
    (w, h), _ = cv2.getTextSize(text, FONT, scale, 1)
    x, y = org
    cv2.rectangle(img, (x - 4, y - h - 6), (x + w + 4, y + 6), (0, 0, 0), -1)
    cv2.putText(img, text, (x, y), FONT, scale, colour, 1, cv2.LINE_AA)


def draw_hand(img, hand: HandDrawing, mirror: bool) -> None:
    """Skeleton, plus a gauge between thumb and index tips that fills as they close."""
    width = img.shape[1]
    pts = [_to_view(x, y, width, mirror) for x, y in hand.points]
    for a, b in CONNECTIONS:
        cv2.line(img, pts[a], pts[b], hand.colour, 2, cv2.LINE_AA)
    for p in pts:
        cv2.circle(img, p, 3, hand.colour, -1, cv2.LINE_AA)

    progress = pinch_progress(hand.gap_cm)
    gauge_colour = GREEN if hand.pinched else tuple(int(g + (c - g) * progress) for g, c in zip(GREY, hand.colour))
    thumb, index = pts[4], pts[8]
    cv2.line(img, thumb, index, gauge_colour, 1 + int(3 * progress), cv2.LINE_AA)
    centre = ((thumb[0] + index[0]) // 2, (thumb[1] + index[1]) // 2)
    cv2.circle(img, centre, 18, GREY, 2, cv2.LINE_AA)
    if hand.pinched:
        cv2.circle(img, centre, 18, GREEN, -1, cv2.LINE_AA)
    elif progress > 0:
        cv2.ellipse(img, centre, (18, 18), -90, 0, 360 * progress, gauge_colour, 4, cv2.LINE_AA)

    if hand.pinched:
        text = hand.pinched_text
    else:
        to_go = max(hand.gap_cm - PINCH_ON_CM, 0)
        text = f"{hand.action}: pinch {to_go:.1f} cm more"
    if text:
        _label(img, text, (centre[0] + 26, centre[1] + 6), gauge_colour)


def draw_flash(img, flash: Flash | None, mirror: bool) -> None:
    """An expanding ring and the new state at the pinch, for a moment after it triggers."""
    if flash is None:
        return
    age = time.time() - flash.started
    if age > FLASH_S:
        return
    centre = _to_view(*flash.at, img.shape[1], mirror)
    cv2.circle(img, centre, int(20 + 80 * age / FLASH_S), GREEN, 3, cv2.LINE_AA)
    _label(img, flash.text, (centre[0] - 40, centre[1] - 40), GREEN, scale=1.0)


def draw_hint(img, text: str) -> None:
    """One line of advice at the bottom centre."""
    (w, _), _ = cv2.getTextSize(text, FONT, 0.8, 2)
    h, width = img.shape[:2]
    _label(img, text, ((width - w) // 2, h - 30), (255, 255, 255), scale=0.8)


def hint_for(hands_seen: int, frame_ok: bool) -> str:
    """What to do next, from how many hands are visible and whether a frame is showing."""
    if hands_seen == 0:
        return "Show both hands, palms to the camera"
    if hands_seen == 1:
        return "Show your other hand too, to make a frame"
    if not frame_ok:
        return "Spread thumbs and index fingers to make a bigger frame"
    return "Right pinch: next effect (hold: list)   Left pinch: black outside   (h hides help)"


def draw_menu(img, names: list[str], selected: int, anchor: int, at: tuple[float, float], step_px: float,
              mirror: bool) -> None:
    """The effect list beside the pinch: it stays put, and the highlight follows the hand.

    Item `anchor` sits level with `at`, where the hold started; the others are
    one `step_px` apart, the distance the hand moves per item.
    """
    height, width = img.shape[:2]
    hand_x, y = _to_view(*at, width, mirror)
    scale, pad = 0.7, 14
    text_w = max(cv2.getTextSize(name, FONT, scale, 2)[0][0] for name in names)
    box_w = text_w + 2 * pad
    left = hand_x + 60 if hand_x + 60 + box_w <= width else hand_x - 60 - box_w  # keep it on screen
    rows = [int(y + (i - anchor) * step_px) for i in range(len(names))]
    top, bottom = rows[0] - int(step_px / 2), rows[-1] + int(step_px / 2)

    y0, y1, x0, x1 = max(top, 0), min(bottom, height), max(left, 0), min(left + box_w, width)
    if y0 >= y1 or x0 >= x1:
        return
    img[y0:y1, x0:x1] = (img[y0:y1, x0:x1] * 0.25).astype(img.dtype)  # dark, see-through panel
    cv2.rectangle(img, (left, top), (left + box_w, bottom), GREY, 1, cv2.LINE_AA)

    for i, (name, row) in enumerate(zip(names, rows)):
        if i == selected:
            cv2.rectangle(img, (left + 3, row - int(step_px / 2) + 3), (left + box_w - 3, row + int(step_px / 2) - 3),
                          GREEN, -1)
            colour = (0, 0, 0)
        else:
            colour = (230, 230, 230)
        cv2.putText(img, name, (left + pad, row + 8), FONT, scale, colour, 2 if i == selected else 1, cv2.LINE_AA)
