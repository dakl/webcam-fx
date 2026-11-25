import AppKit
import AVFoundation
import CoreImage
import HandTracking

// HandFX: the camera picture with each tracked hand drawn on it, and the thumb–index gap in cm.
//
//   swift run -c release HandFX                       window, MacBook Pro Camera
//   swift run -c release HandFX --camera iPhone       another camera, by part of its name
//   swift run -c release HandFX --cpu                 ONNX Runtime on the CPU instead of Core ML
//   swift run -c release HandFX --check a.jpg b.jpg   print the hands found in pictures, as JSON lines
//
// In the window, press s to save the camera picture to mac/captures/.

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
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

// MARK: - Picture check

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

// MARK: - Live window

final class FrameView: NSView {
    var image: CGImage?
    var hands: [Hand] = []
    var pinched: [Bool] = []
    var fps: Double = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// `s` saves the camera picture (without drawings) to mac/captures/, for `--check`.
    override func keyDown(with event: NSEvent) {
        guard event.charactersIgnoringModifiers == "s", let image else { return super.keyDown(with: event) }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../captures").standardized
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "frame-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name))
        print("saved captures/\(name)")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        bounds.fill()
        guard let image else { return }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        // Mirrored, like a meeting app's own preview.
        func view(_ p: SIMD3<Float>) -> CGPoint {
            CGPoint(x: origin.x + size.width - CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
        }
        ctx.saveGState()
        ctx.translateBy(x: origin.x + size.width, y: origin.y + size.height)
        ctx.scaleBy(x: -1, y: -1)  // in this flipped view: upright and mirrored
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()

        for (i, hand) in hands.enumerated() {
            let colour = hand.isRight ? NSColor.systemTeal : NSColor.systemPink
            let pts = hand.landmarks.map(view)
            let path = NSBezierPath()
            for (a, b) in Self.bones {
                path.move(to: pts[a]); path.line(to: pts[b])
            }
            colour.setStroke(); path.lineWidth = 3; path.stroke()
            for p in pts {
                let dot = NSBezierPath(ovalIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
                NSColor.white.setFill(); dot.fill()
            }
            let gap = Pinch.gapCm(hand)
            let isPinched = i < pinched.count && pinched[i]
            let gapLine = NSBezierPath()
            gapLine.move(to: pts[4]); gapLine.line(to: pts[8])
            (isPinched ? NSColor.systemGreen : NSColor.systemGray).setStroke()
            gapLine.lineWidth = isPinched ? 8 : 3; gapLine.stroke()
            let label = String(format: "%@  %.1f cm%@", hand.isRight ? "R" : "L", gap, isPinched ? "  pinch" : "")
            pill(label, at: CGPoint(x: (pts[4].x + pts[8].x) / 2 + 30, y: (pts[4].y + pts[8].y) / 2),
                 colour: isPinched ? .systemGreen : .white)
        }
        pill(String(format: "%.0f fps · %d hands", fps, hands.count), at: CGPoint(x: 16, y: 24), colour: .lightGray)
    }

    private func pill(_ text: String, at p: CGPoint, colour: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Marker Felt Wide", size: 22) ?? .boldSystemFont(ofSize: 22), .foregroundColor: colour,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        let box = CGRect(x: p.x, y: p.y - size.height / 2 - 4, width: size.width + 24, height: size.height + 8)
        NSColor(white: 0.12, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        s.draw(at: CGPoint(x: p.x + 12, y: p.y - size.height / 2))
    }

    static let bones = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11),
                        (11, 12), (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)]
}

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let view: FrameView
    private let queue = DispatchQueue(label: "camera")
    private let ci = CIContext()
    private var pinches: [Bool: PinchState] = [:]  // by isRight
    private var smoothers: [Bool: HandSmoother] = [:]  // by isRight
    private var last = CACurrentMediaTime()

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

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let image = PixelImage(base: CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self),
                               width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        let raw = (try? tracker.process(image)) ?? []
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let hands = raw.map { smoothers[$0.isRight, default: HandSmoother()]($0, at: time) }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)

        var pinched: [Bool] = []
        for side in [true, false] where !hands.contains(where: { $0.isRight == side }) {
            pinches[side, default: .init()].handLost()
            smoothers[side] = nil  // start fresh when the hand comes back
        }
        for hand in hands {
            _ = pinches[hand.isRight, default: .init()].update(Pinch.gapCm(hand))
            pinched.append(pinches[hand.isRight]!.closed)
        }
        let cg = ci.createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent)
        let now = CACurrentMediaTime()
        let fps = 1 / (now - last)
        last = now
        DispatchQueue.main.async { [view] in
            view.image = cg
            view.hands = hands
            view.pinched = pinched
            view.fps = view.fps * 0.9 + fps * 0.1
            view.needsDisplay = true
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
window.title = "HandFX"
let frameView = FrameView()
window.contentView = frameView
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
AVCaptureDevice.requestAccess(for: .video) { ok in
    guard ok else { print("Camera access denied. Allow it for your terminal app in System Settings."); exit(1) }
    camera.session.startRunning()
}
app.run()
