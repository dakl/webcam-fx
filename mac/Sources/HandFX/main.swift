import AppKit
import AVFoundation
import CoreImage
import HandTracking

// HandFX: make a rectangle with the thumbs and index fingers of both hands; the picture inside
// gets an effect. The blue hand's pinch switches to the next effect; pinch and hold it to open
// the effect list, move down or up to pick, and open the fingers to keep it. The pink hand's
// pinch turns the picture outside the frame black, or back.
//
//   swift run -c release HandFX                          window, MacBook Pro Camera
//   swift run -c release HandFX --camera iPhone          another camera, by part of its name
//   swift run -c release HandFX --cpu                    ONNX Runtime on the CPU instead of Core ML
//   swift run -c release HandFX --check a.png b.png      print the hands found in pictures, as JSON lines
//   swift run -c release HandFX --effects a.png out/     render every effect on a picture, for a look
//
// Keys in the window: n next effect, b black outside, h hide or show help, s save the camera
// picture to mac/captures/, q quit.

setvbuf(stdout, nil, _IOLBF, 0)  // print each line at once, also into a pipe or file
let args = CommandLine.arguments
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
}

let ciContext = CIContext()
let effects = Effects(context: ciContext)
let virtualCamera = VirtualCamera()

if let i = args.firstIndex(of: "--effects"), i + 2 < args.count {
    renderEffects(picture: args[i + 1], into: args[i + 2])
    exit(0)
}

let tracker: HandTracker
do {
    tracker = try HandTracker(coreML: !args.contains("--cpu"))
} catch {
    FileHandle.standardError.write("Cannot load the hand models: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if let first = args.firstIndex(of: "--check") {
    for path in args[(first + 1)...] { checkPicture(path) }
    exit(0)
}

// MARK: - Picture checks

/// Print `{"file", "hands": [{"right", "presence", "landmarks", "world"}]}` for one picture.
func checkPicture(_ path: String) {
    guard let cg = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("{\"file\": \"\(path)\", \"error\": \"cannot read\"}")
        return
    }
    let (w, h) = (cg.width, cg.height)
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))  // BGRA in memory
    let hands = pixels.withUnsafeBufferPointer { buf in
        try! tracker.detectOnly(PixelImage(base: buf.baseAddress!, width: w, height: h, bytesPerRow: w * 4))
    }
    let json = hands.map { hand in
        [
            "right": hand.rightScore, "presence": hand.presence,
            "landmarks": hand.landmarks.map { [$0.x, $0.y, $0.z] }, "world": hand.world.map { [$0.x, $0.y, $0.z] },
        ] as [String: Any]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["file": path, "hands": json])
    print(String(data: data, encoding: .utf8)!)
}

/// Write `<effect>.png` for each effect, applied to the middle half of the picture.
func renderEffects(picture: String, into folder: String) {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: picture)) else { return print("cannot read \(picture)") }
    let e = image.extent
    let box = SIMD4(Float(e.width * 0.25), Float(e.height * 0.25), Float(e.width * 0.75), Float(e.height * 0.75))
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for (name, apply) in effects.all {
        let out = compose(image, frame: box, effect: apply, blackOutside: name == "ascii", time: 3)
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        try! ciContext.writePNGRepresentation(of: out, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        print("wrote \(url.path)")
    }
}

// MARK: - Live window

/// Hand tracking, gestures and effects for each camera frame. Runs on its own queue.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let view: FrameView
    private let queue = DispatchQueue(label: "camera")
    private var pinches: [Bool: PinchState] = [:]  // by isRight
    private var smoothers: [Bool: HandSmoother] = [:]  // by isRight
    private var menu = PinchMenu(count: effects.all.count)
    private var frame = FingerFrame()
    private var blackOutside = false
    private var gesturesOn = true  // off: hands are not tracked and change nothing
    private var mouseBox: SIMD4<Float>?  // a frame drawn with the mouse wins over the hands' frame
    private var showHelp = true
    private var flash: FlashHelp?
    private var menuAt = CGPoint.zero
    private var lastPicture: CIImage?
    private var fps = 0.0
    private var last = CACurrentMediaTime()

    // MediaPipe's handedness label; with this unmirrored picture, "Left" is the user's left hand.
    private let effectsHandIsRight = false

    init(view: FrameView, name: String) throws {
        self.view = view
        super.init()
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                                       mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) else {
            throw NSError(domain: "HandFX", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "No camera matches \"\(name)\". Cameras: \(devices.map(\.localizedName).joined(separator: ", "))"])
        }
        print("Camera: \(device.localizedName)")
        session.sessionPreset = .hd1280x720
        session.addInput(try AVCaptureDeviceInput(device: device))
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    /// The effect chosen with the mouse.
    func select(_ index: Int) {
        queue.async { [self] in
            menu.selected = index
            publishControls()
        }
    }

    /// The settings as of the last change, for the toolbar. It reads this copy and never waits for
    /// the camera queue, which can be busy for a while with a slow effect.
    struct Controls { var selected = 0, blackOutside = false, gesturesOn = true, showHelp = true }
    var controls: Controls { controlsLock.withLock { published } }
    private var published = Controls()
    private let controlsLock = NSLock()

    /// Call on the camera queue after changing a setting.
    private func publishControls() {
        let c = Controls(selected: menu.selected, blackOutside: blackOutside, gesturesOn: gesturesOn,
                         showHelp: showHelp)
        controlsLock.withLock { published = c }
    }

    /// A frame drawn with the mouse, in image pixels; nil removes it.
    func setMouseBox(_ box: SIMD4<Float>?) {
        queue.async { [self] in
            mouseBox = box
            publishControls()
        }
    }

    func setBlackOutside(_ on: Bool) { change { $0.blackOutside = on } }
    func setShowHelp(_ on: Bool) { change { $0.showHelp = on } }
    func setGestures(_ on: Bool) { change { $0.applyGestures(on) } }

    private func change(_ apply: @escaping (Camera) -> Void) {
        queue.async { [self] in
            apply(self)
            publishControls()
        }
    }

    /// Off: hands are not tracked, and pinches, the hands' frame and the list are dropped.
    private func applyGestures(_ on: Bool) {
        gesturesOn = on
        if !on { (pinches, smoothers, frame, flash) = ([:], [:], FingerFrame(), nil) }
    }

    func key(_ key: String) {
        queue.async { [self] in
            switch key {
            case "n": menu.selected = (menu.selected + 1) % menu.count
            case "b": blackOutside.toggle()
            case "g": applyGestures(!gesturesOn)
            case "h": showHelp.toggle()
            case "s": save()
            case "q": DispatchQueue.main.async { NSApp.terminate(nil) }
            default: break
            }
            publishControls()
        }
    }

    /// The camera picture, without effects or help, to mac/captures/ (for `--check`).
    private func save() {
        guard let picture = lastPicture else { return }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../captures").standardized
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "frame-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        try? ciContext.writePNGRepresentation(of: picture, to: folder.appendingPathComponent(name), format: .RGBA8,
                                              colorSpace: CGColorSpaceCreateDeviceRGB())
        print("saved captures/\(name)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let image = PixelImage(base: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self),
                               width: width, height: height, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        let raw = gesturesOn ? (try? tracker.process(image)) ?? [] : []
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let now = CACurrentMediaTime()
        let hands = raw.map { smoothers[$0.isRight, default: HandSmoother()]($0, at: time) }

        let help = gestures(hands, imageHeight: Float(height), now: now)
        publishControls()
        let handBox = gesturesOn ? frame.update(hands, now: time) : nil
        let box = mouseBox ?? handBox
        let picture = CIImage(cvPixelBuffer: buffer)
        lastPicture = picture
        let effect = effects.all[menu.selected]
        let composed = compose(picture, frame: box, effect: effect.apply, blackOutside: blackOutside, time: now)
        virtualCamera.send(composed, context: ciContext)  // effects, no help, not mirrored
        guard let cg = ciContext.createCGImage(composed, from: picture.extent) else { return }

        fps = 0.9 * fps + 0.1 / max(now - last, 1e-6)
        last = now
        var scene = Scene(image: cg, hands: help, flash: flash, showHelp: showHelp)
        if menu.isOpen {
            scene.menu = MenuHelp(names: effects.all.map(\.name), selected: menu.selected, anchor: menu.startIndex,
                                  at: menuAt, stepPx: CGFloat(PinchMenu.step) * CGFloat(height))
            scene.hint = "Move the pinch down or up to pick, open your fingers to keep it"
        } else {
            scene.hint = gesturesOn ? hint(handsSeen: hands.count, frameOK: box != nil) : ""
        }
        scene.status = String(format: "%.0f fps · %@ · camera: %@", fps,
                              gesturesOn ? "hands: \(hands.count)" : "gestures off", virtualCamera.status)
        DispatchQueue.main.async { [view] in
            view.scene = scene
            view.needsDisplay = true
        }
    }

    /// Pinch states, the effect list and black-outside; returns each hand's help.
    private func gestures(_ hands: [Hand], imageHeight: Float, now: Double) -> [HandHelp] {
        for side in [true, false] where !hands.contains(where: { $0.isRight == side }) {
            pinches[side, default: .init()].handLost()
            smoothers[side] = nil  // start fresh when the hand comes back
        }
        return hands.map { hand in
            let gap = Pinch.gapCm(hand)
            let triggered = pinches[hand.isRight, default: .init()].update(gap)
            let closed = pinches[hand.isRight]!.closed
            let tip = (hand.landmarks[4] + hand.landmarks[8]) / 2
            let at = CGPoint(x: CGFloat(tip.x), y: CGFloat(tip.y))
            let isEffects = hand.isRight == effectsHandIsRight
            if isEffects {
                let event = menu.update(pinched: closed, y: tip.y / imageHeight, now: now)
                if menu.isOpen { menuAt = CGPoint(x: at.x, y: CGFloat(menu.startY * imageHeight)) }
                if event != nil { flash = FlashHelp(text: effects.all[menu.selected].name, at: at, started: now) }
            } else if triggered {
                blackOutside.toggle()
                flash = FlashHelp(text: "black \(blackOutside ? "on" : "off")", at: at, started: now)
            }
            return HandHelp(points: hand.landmarks.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                            colour: isEffects ? Palette.effects : Palette.black,
                            action: isEffects ? "next effect" : "black outside", gapCm: gap, pinched: closed,
                            pinchedText: isEffects ? (menu.isOpen ? "" : "let go: next, hold: list")
                                                   : "black outside - open to pinch again")
        }
    }

    private func hint(handsSeen: Int, frameOK: Bool) -> String {
        switch (handsSeen, frameOK) {
        case (0, _): "Show both hands, palms to the camera"
        case (1, _): "Show your other hand too, to make a frame"
        case (_, false): "Spread thumbs and index fingers to make a bigger frame"
        default: "Blue pinch: next effect (hold: list)  ·  Pink pinch: black outside  ·  h hides help"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "HandFX"
let frameView = FrameView()
window.center()
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(frameView)
app.activate(ignoringOtherApps: true)

final class Quitter: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
let quitter = Quitter()
window.delegate = quitter

let camera: Camera
do {
    camera = try Camera(view: frameView, name: option("--camera") ?? "MacBook Pro Camera")
} catch {
    print(error.localizedDescription)
    exit(1)
}
frameView.onKey = { camera.key($0) }
frameView.onDrawBox = { camera.setMouseBox($0) }

let toolbar = Toolbar(camera: camera, frameView: frameView)
let content = NSView()
for v in [frameView, toolbar] as [NSView] {
    v.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(v)
}
NSLayoutConstraint.activate([
    frameView.topAnchor.constraint(equalTo: content.topAnchor),
    frameView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
    frameView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    toolbar.topAnchor.constraint(equalTo: frameView.bottomAnchor),
    toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
    toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
    toolbar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
])
window.contentView = content
window.makeFirstResponder(frameView)

let mainMenu = NSMenu()
let appItem = NSMenuItem()
appItem.submenu = NSMenu()
appItem.submenu!.addItem(withTitle: "Quit HandFX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
mainMenu.items = [appItem]
app.mainMenu = mainMenu
virtualCamera.install()
// The flash and list animate between frames too.
Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
    frameView.needsDisplay = true
    toolbar.refresh()
}
AVCaptureDevice.requestAccess(for: .video) { ok in
    guard ok else { return print("Camera access denied. Allow it in System Settings > Privacy & Security > Camera.") }
    camera.session.startRunning()
}
app.run()
