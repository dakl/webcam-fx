"""Open a camera by name, because macOS camera numbers change as devices come and go."""

import cv2

DEFAULT_CAMERA = "MacBook Pro Camera"


def open_camera(name: str = DEFAULT_CAMERA, width: int = 1920, height: int = 1080) -> cv2.VideoCapture:
    """Open the first AVFoundation camera whose name contains `name` (case-insensitive).

    Asks for `width` x `height`; the camera picks its nearest mode, which is printed.
    """
    devices = cv2.videoio_registry.enumerateDevices(cv2.CAP_AVFOUNDATION)
    names = [d.cam_name for d in devices]
    match = next((d for d in devices if name.lower() in d.cam_name.lower()), None)
    if match is None:
        raise SystemExit(f"No camera named {name!r}. Cameras: {names}")
    cap = cv2.VideoCapture(match.cam_idx, cv2.CAP_AVFOUNDATION)
    if not cap.isOpened():
        raise SystemExit(f"Cannot open {match.cam_name!r}. Allow camera access for this app in System Settings.")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    actual = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)), int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    print(f"Camera: {match.cam_name}, {actual[0]}x{actual[1]}")
    return cap
