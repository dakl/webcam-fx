"""On-screen help for the local window: hand skeletons, pinch gauges, hints and the effect list.

It is drawn only on what you see, never on the picture sent to the virtual camera.
Positions are given in the processed frame; `mirror` flips them to match a
mirrored window, so text is drawn the right way round. Sizes are for a 1080 px
tall picture and scale with the real height.
"""

import time
from dataclasses import dataclass
from functools import lru_cache

import cv2
import numpy as np
from mediapipe.tasks.python import vision
from PIL import Image, ImageDraw, ImageFont

from gestures import PINCH_ON_CM, pinch_progress

CONNECTIONS = [(c.start, c.end) for c in vision.HandLandmarksConnections.HAND_CONNECTIONS]
FONT_PATH, FONT_INDEX = "/System/Library/Fonts/MarkerFelt.ttc", 1  # Marker Felt Wide
FLASH_S = 0.7

# BGR colours
WHITE = (245, 245, 245)
MUTED = (175, 175, 180)
GREY = (120, 120, 125)
GREEN = (120, 235, 110)
INK = (30, 25, 25)  # dark text on the green highlight
PANEL = (34, 28, 28)
PANEL_OPACITY = 0.72


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


def _px(img, size_at_1080: float) -> int:
    return max(1, round(size_at_1080 * img.shape[0] / 1080))


@lru_cache(maxsize=8)
def _font(size: int) -> ImageFont.FreeTypeFont:
    try:
        return ImageFont.truetype(FONT_PATH, size, index=FONT_INDEX)
    except OSError:
        return ImageFont.load_default(size)


@lru_cache(maxsize=1024)
def _text_sprite(text: str, size: int, colour: tuple[int, int, int]) -> tuple[np.ndarray, np.ndarray]:
    """The text rendered once: a BGR image and its 0–1 coverage, tightly cropped."""
    font = _font(size)
    left, top, right, bottom = font.getbbox(text)
    mask = Image.new("L", (max(right - left, 1), max(bottom - top, 1)), 0)
    ImageDraw.Draw(mask).text((-left, -top), text, font=font, fill=255)
    alpha = np.asarray(mask, np.float32)[..., None] / 255
    return np.broadcast_to(np.array(colour, np.float32), alpha.shape[:2] + (3,)), alpha


def _blend(img, x: int, y: int, colour_img: np.ndarray, alpha: np.ndarray) -> None:
    """Paint `colour_img` at (x, y) top-left, weighted by `alpha`, clipped to the picture."""
    h, w = alpha.shape[:2]
    x0, y0, x1, y1 = max(x, 0), max(y, 0), min(x + w, img.shape[1]), min(y + h, img.shape[0])
    if x0 >= x1 or y0 >= y1:
        return
    a = alpha[y0 - y : y1 - y, x0 - x : x1 - x]
    region = img[y0:y1, x0:x1].astype(np.float32)
    img[y0:y1, x0:x1] = (region * (1 - a) + colour_img[y0 - y : y1 - y, x0 - x : x1 - x] * a).astype(np.uint8)


def text_size(img, text: str, size_at_1080: float) -> tuple[int, int]:
    _, alpha = _text_sprite(text, _px(img, size_at_1080), WHITE)
    return alpha.shape[1], alpha.shape[0]


def draw_text(img, text: str, x: int, y: int, size_at_1080: float, colour=WHITE) -> None:
    """Text with its top-left corner at (x, y)."""
    colour_img, alpha = _text_sprite(text, _px(img, size_at_1080), tuple(colour))
    _blend(img, x, y, colour_img, alpha)


@lru_cache(maxsize=256)
def _rounded_alpha(w: int, h: int, radius: int) -> np.ndarray:
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius, fill=255)
    return np.asarray(mask, np.float32)[..., None] / 255


def draw_panel(img, x: int, y: int, w: int, h: int, colour=PANEL, opacity=PANEL_OPACITY, radius=None) -> None:
    """A see-through rounded rectangle."""
    if w <= 0 or h <= 0:
        return
    radius = min(radius if radius is not None else h // 2, h // 2, w // 2)
    alpha = _rounded_alpha(w, h, radius) * opacity
    _blend(img, x, y, np.broadcast_to(np.array(colour, np.float32), (h, w, 3)), alpha)


def draw_pill(
    img, text: str, x: int, y: int, size_at_1080: float, colour=WHITE, background=PANEL, opacity=PANEL_OPACITY
) -> tuple[int, int]:
    """Text in a rounded pill; (x, y) is the pill's left edge and vertical middle. Returns its size."""
    tw, th = text_size(img, text, size_at_1080)
    pad_x, pad_y = _px(img, size_at_1080 * 0.55), _px(img, size_at_1080 * 0.3)
    w, h = tw + 2 * pad_x, th + 2 * pad_y
    draw_panel(img, x, y - h // 2, w, h, background, opacity)
    draw_text(img, text, x + pad_x, y - th // 2, size_at_1080, colour)
    return w, h


def draw_hand(img, hand: HandDrawing, mirror: bool) -> None:
    """Skeleton, plus a gauge between thumb and index tips that fills as they close."""
    width = img.shape[1]
    pts = [_to_view(x, y, width, mirror) for x, y in hand.points]
    line = _px(img, 3)
    for a, b in CONNECTIONS:
        cv2.line(img, pts[a], pts[b], hand.colour, line, cv2.LINE_AA)
    for p in pts:
        cv2.circle(img, p, _px(img, 5), WHITE, -1, cv2.LINE_AA)
        cv2.circle(img, p, _px(img, 5), hand.colour, max(1, line // 2), cv2.LINE_AA)

    progress = pinch_progress(hand.gap_cm)
    gauge_colour = GREEN if hand.pinched else tuple(int(g + (c - g) * progress) for g, c in zip(GREY, hand.colour))
    thumb, index = pts[4], pts[8]
    cv2.line(img, thumb, index, gauge_colour, line + int(4 * progress), cv2.LINE_AA)
    centre = ((thumb[0] + index[0]) // 2, (thumb[1] + index[1]) // 2)
    r = _px(img, 24)
    cv2.circle(img, centre, r, GREY, _px(img, 3), cv2.LINE_AA)
    if hand.pinched:
        cv2.circle(img, centre, r, GREEN, -1, cv2.LINE_AA)
    elif progress > 0:
        cv2.ellipse(img, centre, (r, r), -90, 0, 360 * progress, gauge_colour, _px(img, 6), cv2.LINE_AA)

    if hand.pinched:
        text = hand.pinched_text
    else:
        to_go = max(hand.gap_cm - PINCH_ON_CM, 0)
        text = f"{hand.action}: pinch {to_go:.1f} cm more"
    if text:
        draw_pill(img, text, centre[0] + r + _px(img, 14), centre[1], 26, colour=GREEN if hand.pinched else WHITE)


def draw_flash(img, flash: Flash | None, mirror: bool) -> None:
    """An expanding ring and the new state at the pinch, for a moment after it triggers."""
    if flash is None:
        return
    age = time.time() - flash.started
    if age > FLASH_S:
        return
    centre = _to_view(*flash.at, img.shape[1], mirror)
    cv2.circle(img, centre, int(_px(img, 28) + _px(img, 110) * age / FLASH_S), GREEN, _px(img, 4), cv2.LINE_AA)
    w, _ = text_size(img, flash.text, 44)
    draw_pill(
        img, flash.text, centre[0] - w // 2, centre[1] - _px(img, 70), 44, colour=INK, background=GREEN, opacity=0.92
    )


def draw_hint(img, text: str) -> None:
    """One line of advice at the bottom centre."""
    w, _ = text_size(img, text, 30)
    draw_pill(img, text, (img.shape[1] - w) // 2, img.shape[0] - _px(img, 50), 30)


def draw_status(img, text: str) -> None:
    """A small status pill in the top-left corner."""
    draw_pill(img, text, _px(img, 16), _px(img, 34), 24, colour=MUTED)


def hint_for(hands_seen: int, frame_ok: bool) -> str:
    """What to do next, from how many hands are visible and whether a frame is showing."""
    if hands_seen == 0:
        return "Show both hands, palms to the camera"
    if hands_seen == 1:
        return "Show your other hand too, to make a frame"
    if not frame_ok:
        return "Spread thumbs and index fingers to make a bigger frame"
    return "Right pinch: next effect (hold: list)  ·  Left pinch: black outside  ·  h hides help"


def draw_menu(
    img, names: list[str], selected: int, anchor: int, at: tuple[float, float], step_px: float, mirror: bool
) -> None:
    """The effect list beside the pinch: it stays put, and the highlight follows the hand.

    Item `anchor` sits level with `at`, where the hold started; the others are
    one `step_px` apart, the distance the hand moves per item.
    """
    height, width = img.shape[:2]
    hand_x, y = _to_view(*at, width, mirror)
    size = min(30, step_px * 1080 / height * 0.6)
    pad = _px(img, 18)
    box_w = max(text_size(img, name, size)[0] for name in names) + 2 * pad
    gap = _px(img, 70)
    left = hand_x + gap if hand_x + gap + box_w <= width else hand_x - gap - box_w  # keep it on screen
    rows = [int(y + (i - anchor) * step_px) for i in range(len(names))]
    half = int(step_px / 2)
    top = rows[0] - half - pad // 2
    draw_panel(img, left, top, box_w, rows[-1] + half + pad // 2 - top, radius=_px(img, 22))

    inset = _px(img, 6)
    for i, (name, row) in enumerate(zip(names, rows)):
        tw, th = text_size(img, name, size)
        if i == selected:
            draw_panel(
                img,
                left + inset,
                row - half + inset // 2,
                box_w - 2 * inset,
                2 * half - inset,
                colour=GREEN,
                opacity=0.95,
            )
        draw_text(img, name, left + pad, row - th // 2, size, INK if i == selected else WHITE)
