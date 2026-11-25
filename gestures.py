"""Pinch detection on MediaPipe hands, measured in real-world centimetres.

The tracker's world landmarks estimate each hand in metres, so a pinch means
the same finger gap whether the hand is near the camera or far from it.
"""

from dataclasses import dataclass

import numpy as np

THUMB_TIP, INDEX_TIP = 4, 8
PINCH_ON_CM = 3.5  # thumb and index tips closer than this start a pinch
PINCH_OFF_CM = 5.5  # they must open wider than this before the next pinch counts
GAUGE_START_CM = 10.0  # the on-screen gauge starts filling here
PINCH_FRAMES = 2  # frames in a row under PINCH_ON_CM, so one noisy frame does not trigger


def pinch_gap_cm(world_hand) -> float:
    """Distance between the thumb and index tips, in centimetres."""
    a, b = world_hand[THUMB_TIP], world_hand[INDEX_TIP]
    return float(np.linalg.norm([a.x - b.x, a.y - b.y, a.z - b.z])) * 100


def pinch_progress(gap_cm: float) -> float:
    """0 when the fingers are far apart, 1 when they are close enough to pinch."""
    return float(np.clip((GAUGE_START_CM - gap_cm) / (GAUGE_START_CM - PINCH_ON_CM), 0, 1))


@dataclass
class PinchState:
    """One hand's pinch: closed while pinched, so holding a pinch triggers once."""

    closed: bool = False
    frames_under: int = 0

    def update(self, gap_cm: float) -> bool:
        """Feed one frame's finger gap; return True on the frame a new pinch starts."""
        if self.closed:
            if gap_cm > PINCH_OFF_CM:
                self.closed = False
            return False
        self.frames_under = self.frames_under + 1 if gap_cm < PINCH_ON_CM else 0
        if self.frames_under >= PINCH_FRAMES:
            self.closed, self.frames_under = True, 0
            return True
        return False

    def hand_lost(self) -> None:
        """Forget a pinch in progress; a pinch held while out of view stays closed."""
        self.frames_under = 0
