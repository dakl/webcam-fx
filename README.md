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

- Right-hand pinch: next effect. Left-hand pinch: picture outside the frame black, or back.
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

## Camera choice

The scripts open the camera by name (default "MacBook Pro Camera"), because
OpenCV numbers cameras by device ID and the order changes when an iPhone or
the OBS camera appears. `frame_fx.py` and `relight.py` take `--camera iPhone`
(any part of a name) to pick another one.
