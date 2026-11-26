# Third-party parts

webcam-fx is MIT licensed (see `LICENSE`). It uses these parts from others.

| Part | Where | Licence |
|------|-------|---------|
| MediaPipe Hand Landmarker models (palm detector and hand landmarks), by Google | `hand_landmarker.task`, and the ONNX copies in `mac/Sources/HandTracking/Models/` | The MediaPipe project is Apache 2.0. See Google's model card for the hand landmarker models: <https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker> |
| ONNX Runtime 1.32.0, by Microsoft | Inside HandFX.app (`Contents/Frameworks`); fetched by `mac/fetch-onnxruntime.sh`, not kept in this repository | MIT. The app carries its `LICENSE` and `ThirdPartyNotices.txt` in `Contents/Resources/notices/`. |

The pixel art palettes are colour lists by their authors: ENDESGA 32 by
Endesga, Sweetie 16 by GrafxKid, PICO-8 by Lexaloffle Games, and the Game Boy
colours by Nintendo.

The Python scripts use MediaPipe, OpenCV, NumPy, Pillow, PyObjC and
pyvirtualcam, installed by `uv` under their own licences.
