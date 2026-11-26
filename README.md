# webcam-fx

Webcam effects that you control with your hands, for macOS.

Make a rectangle with the thumbs and index fingers of both hands. The picture
inside the rectangle gets an effect: pixel art, thermal, comic, kaleidoscope
and nine more. Pinch to change the effect. Meeting apps can show the result as
a camera called **HandFX**.

The repository has two parts:

| Part | What it is |
|------|------------|
| **HandFX.app** (`mac/`) | The Mac app, in Swift. It has all the effects, a toolbar, mouse control and its own camera for meeting apps. Start here. |
| **Python scripts** (root) | The first versions, with MediaPipe in Python. They use the OBS Virtual Camera. |

## Install HandFX

HandFX runs on Macs with Apple Silicon and macOS 14 or later.

1. Download the DMG from [Releases](https://github.com/dakl/webcam-fx/releases).
2. Open the DMG and drag **HandFX** to **Applications**. Then open HandFX.
3. Allow camera access when macOS asks.
4. Open System Settings > General > Login Items & Extensions > Camera
   Extensions, and switch on **HandFX Camera**.
5. In your meeting app (Slack, Teams, Zoom, FaceTime), select the camera
   **HandFX**.

The HandFX camera shows a grey picture while HandFX.app is closed. After you
install an update, restart the meeting app if HandFX is not in its camera list.

## Use HandFX

The window shows your picture mirrored, like the preview in a meeting app. The
HandFX camera sends the picture not mirrored, with the effect, and without the
help drawings.

### With your hands

- **Frame:** hold up both hands. The thumb and index tips of both hands make
  the frame. The frame stays still while you pinch.
- **Blue hand, quick pinch:** next effect, when you open your fingers.
- **Blue hand, pinch and hold (0.4 s):** a list of effects opens. Move your
  hand down or up to select an effect. Open your fingers to keep it.
- **Pink hand, pinch:** make the picture outside the frame black, or normal.

A pinch starts when the thumb and index tips are less than 3.5 cm apart, and
the next pinch counts after they are more than 5.5 cm apart. The distances are
in real-world centimetres, so a pinch works near the camera and far from it.
The gap is measured across the picture only, because the hand model estimates
depth badly. The window shows a gauge for each hand, for example
"next effect: pinch 1.5 cm more".

### With the mouse

- Drag in the picture to draw a frame. A drawn frame has priority over the
  frame from your hands.
- Drag an edge or a corner to change the size of the frame. Drag inside the
  frame to move it.
- Click outside the frame to remove it.

### Toolbar

| Control | What it does |
|---------|--------------|
| Effect | Selects the effect. For **pixel art**, two more menus select the palette (ENDESGA 32, Sweetie 16, PICO-8, Game Boy, 1-bit) and the block size (32 to 128 blocks across). |
| Black outside | Makes the picture outside the frame black. |
| Hand gestures | Off: hands are not tracked, and pinches change nothing. |
| Help | Shows or hides the hand drawings and hints in the window. |
| Lock frame | Stops the mouse from changing the drawn frame. |
| Remove frame | Removes the drawn frame. |

The right side of the toolbar shows the frame rate, the number of hands, and
the state of the HandFX camera ("sending" when it works).

HandFX keeps the effect, the toolbar settings, the drawn frame and the lock
when you quit.

### Keys

| Key | Action |
|-----|--------|
| `n` | Next effect |
| `b` | Black outside on or off |
| `g` | Hand gestures on or off |
| `h` | Help on or off |
| `s` | Save the camera picture to `mac/captures/` in the source folder (for builds made on this Mac) |
| `q` | Quit |

## How HandFX works

- **Hand tracking:** MediaPipe's two hand models (palm detector and hand
  landmarks), converted to ONNX, run with ONNX Runtime. The landmark model runs
  on Core ML. The detector runs on the CPU, because Core ML cannot load it. The
  Swift code does MediaPipe's other steps: anchors, box merging, rotated crops,
  hand tracking between frames and smoothing.
- **Effects:** Core Image filters. Pixel art uses Vision's person segmentation
  for the outline, and the `PixelGrid` module keeps block colours steady between
  frames and removes single stray blocks.
- **Camera:** a Core Media I/O camera extension inside the app. The app sends
  each finished frame to the extension, and meeting apps read it from there.

| Folder | Contents |
|--------|----------|
| `mac/Sources/HandTracking` | Hand tracking on ONNX Runtime, pinch logic, the effect list logic. |
| `mac/Sources/PixelGrid` | Palettes and block-colour logic for pixel art. |
| `mac/Sources/HandFX` | The app: window, toolbar, effects, settings, camera output. |
| `mac/CameraExtension` | The HandFX camera extension. |
| `mac/Tests` | Unit tests. |

## Build HandFX

You need Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) and an Apple developer account in Xcode > Settings >
Accounts.

```bash
cd mac && ./fetch-onnxruntime.sh
```

This downloads ONNX Runtime 1.32.0 from Microsoft's NuGet package, checks its
SHA-256, and puts the library and headers in `mac/Vendor/`. The app carries
this library inside it.

```bash
cd mac && swift run -c release HandFX
```

This runs the window without the camera extension.

```bash
cd mac && ./make-app.sh
```

This builds HandFX.app with the camera extension, signs it for development and
installs it in `/Applications`.

`swift run -c release HandFX` also takes these options:

- `--camera iPhone`: use another camera (any part of its name).
- `--cpu`: run ONNX Runtime on the CPU only.
- `--check a.png b.png`: print the hands found in pictures, as JSON.
- `--effects a.png out/`: write every effect, applied to a picture.

## Make a release

`make-release.sh` builds a DMG that runs on other Macs. It signs the app with
Developer ID, sends the DMG to Apple for notarisation, and staples the result.

1. Store your notarisation credentials once. Make an app-specific password at
   account.apple.com, then run this command (with your Apple ID and team ID)
   and type the password when it asks:

   ```bash
   xcrun notarytool store-credentials handfx-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --sync
   ```

   `--sync` puts the profile in iCloud Keychain, so your other Macs can use it.

2. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `mac/project.yml`.
3. Run the script:

   ```bash
   cd mac && ./make-release.sh
   ```

4. Upload `mac/build/HandFX-<version>.dmg` to a GitHub release.

## Checks

```bash
make lint
make test
make format
```

`make lint` runs swift-format and ruff. `make test` builds the Swift code with
strict concurrency checks and warnings as errors, runs the Swift tests, and
runs the Python tests. `make format` fixes the formatting.

GitHub Actions runs the same checks: `app` on macOS when `mac/` changes, and
`python` on Linux when the Python files change.

## Python scripts

The first versions. They use Google's MediaPipe Hand Landmarker
(`hand_landmarker.task`) in Python.

| Script | What it does |
|--------|--------------|
| `frame_fx.py` | The finger frame with 12 effects (HandFX without pixel art). |
| `relight.py` | A coloured glow on each fingertip. |
| `screen_zoom.py` | Frame part of the screen with your hands to zoom the Mac screen there (macOS Zoom). |

```bash
uv run frame_fx.py
```

The first run asks for camera access for your terminal app.

`frame_fx.py` uses the same gestures as HandFX: the hand drawn in blue picks
effects, and the hand drawn in pink turns black-outside on or off. Keys: `n`
next effect, `b` black outside, `h` help, `q` quit. `--log pinches.csv` writes
the finger gap of each hand in each frame.

### Meeting camera with OBS

`frame_fx.py` and `relight.py` take `--cam`. This sends the picture to the OBS
Virtual Camera.

1. Install OBS once with `brew install --cask obs`. Open OBS, click **Start
   Virtual Camera**, allow the camera extension in System Settings, then quit
   OBS.
2. Keep OBS closed while you use `--cam`. If OBS is open, the meeting gets its
   empty scene, which is black.
3. Run `uv run frame_fx.py --cam`, and select **OBS Virtual Camera** in your
   meeting app.

### Camera choice

The scripts open the camera by name (default "MacBook Pro Camera"). OpenCV
numbers cameras by device ID, and that order changes when an iPhone or the OBS
camera appears. `frame_fx.py` and `relight.py` take `--camera iPhone` (any part
of a name) to select another camera.

### Screen zoom setup

`screen_zoom.py` needs two settings:

1. In System Settings > Accessibility > Zoom, switch on "Use scroll gesture
   with modifier keys to zoom", with Control.
2. Give your terminal app Accessibility permission.

## Licence

MIT, see [LICENSE](LICENSE). The hand models, ONNX Runtime and the palettes
come from others: see [THIRD_PARTY.md](THIRD_PARTY.md).
