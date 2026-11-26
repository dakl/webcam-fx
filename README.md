# webcam-fx

Webcam effects you control with your hands, for macOS. Hand tracking is
Google's MediaPipe Hand Landmarker (`hand_landmarker.task`, about 8 MB, on the CPU).

| Script | What it does |
|--------|--------------|
| `frame_fx.py` | Make a rectangle with the thumbs and index fingers of both hands. The picture inside gets an effect (pixelate, thermal, edges, ASCII, comic, invert, RGB split, blur, night vision, sepia, posterize, kaleidoscope). |
| `relight.py` | A coloured glow on each fingertip. |
| `screen_zoom.py` | Frame part of the screen with your hands to zoom the Mac screen there (macOS Zoom). |

## Run

```bash
uv run frame_fx.py
```

`frame_fx.py` controls:

- Right-hand pinch: next effect, when you let go. Pinch and hold for 0.4 s to
  open a list of effects; move the pinch down or up to pick, and open your
  fingers to keep it.
- Left-hand pinch: picture outside the frame black, or back.
- `--log pinches.csv` writes each frame's finger gap per hand, to tune the pinch limits.
- Keys: `n` next effect, `b` black outside, `h` hide or show help, `q` quit.

A pinch is the thumb and index tips closer than 3.5 cm, measured in real-world
centimetres, so it works near the camera and far from it. Open them past 5.5 cm
before the next pinch counts. Your own window shows each tracked hand, a gauge
that fills as you pinch ("pinch 1.5 cm more") and a hint for what to do next.
The virtual camera gets the picture without this help.

The first run asks for camera access for your terminal app.

## Use it as your meeting camera

`frame_fx.py` and `relight.py` take `--cam`, which sends the picture to the
OBS Virtual Camera. Pick **OBS Virtual Camera** in Slack, Teams or Zoom.

1. Install OBS once: `brew install --cask obs`. Open it, click **Start Virtual
   Camera**, allow the camera extension in System Settings, then quit OBS.
2. Keep OBS closed while you use `--cam`. With OBS open, its own empty scene
   reaches the meeting as a black picture.
3. Run `uv run frame_fx.py --cam`. Others see the true picture; your own
   window is mirrored, like a meeting app's preview.

## Screen zoom setup

`screen_zoom.py` needs, in System Settings → Accessibility → Zoom, "Use scroll
gesture with modifier keys to zoom" on with Control, and Accessibility
permission for your terminal app.

## Swift app (`mac/`)

A native start on the same hand tracking, without Python: MediaPipe's two
hand models, converted to ONNX, run through ONNX Runtime (the landmark model
on Core ML). It has the finger frame, 13 effects (on Core Image; "pixel art" cuts you out
with Vision and redraws you in steady, cleaned-up blocks, with a choice of
palette and block size), the
pinch picker and black-outside, with the same on-screen help. The blue hand
picks effects, the pink hand turns black-outside on or off. As HandFX.app it
is also a camera, "HandFX", for meeting apps.

HandFX.app runs on Apple Silicon Macs with macOS 14 or later. Download the
DMG from the GitHub releases, or build it:

```bash
brew install xcodegen
cd mac && ./fetch-onnxruntime.sh        # ONNX Runtime from Microsoft's NuGet package
cd mac && swift run -c release HandFX   # window only
cd mac && ./make-app.sh                 # HandFX.app with the camera, into /Applications
cd mac && ./make-release.sh             # notarised build/HandFX-<version>.dmg for other Macs
```

The app carries ONNX Runtime inside it. `make-app.sh` and `make-release.sh`
sign with the first team in Xcode > Settings > Accounts; `make-release.sh`
signs with Developer ID and notarises with the keychain profile
`handfx-notary` (see the script for the one-time `notarytool store-credentials`).
The first time, open HandFX.app, switch on HandFX Camera in System Settings >
General > Login Items & Extensions > Camera Extensions, and allow camera
access. Then pick the "HandFX" camera in your meeting app; it shows grey while
HandFX.app is closed.

With the mouse: drag in the picture to draw a frame; drag its edges or corners
to resize it, inside it to move it, and click outside it to remove it. The
toolbar under the picture picks the effect, turns black-outside, hand gestures
and the help on or off, locks the frame against the mouse, and shows fps,
hands and the camera state.

- Keys: `n` next effect, `b` black outside, `g` hand gestures on or off,
  `h` help, `s` save the camera picture to `mac/captures/`, `q` quit.
- `HandFX --check a.png` prints the hands found in a picture as JSON.
- `HandFX --effects a.png out/` renders every effect on a picture.
- The pinch gap leaves out depth: the model guesses it poorly, and a closed
  pinch facing the camera can read 3–6 cm apart in depth.

## Camera choice

The scripts open the camera by name (default "MacBook Pro Camera"), because
OpenCV numbers cameras by device ID and the order changes when an iPhone or
the OBS camera appears. `frame_fx.py` and `relight.py` take `--camera iPhone`
(any part of a name) to pick another one.
