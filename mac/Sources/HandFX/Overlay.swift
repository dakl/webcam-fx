import AppKit
import HandTracking

/// What one hand's help shows: skeleton, pinch gauge and a label.
struct HandHelp {
    var points: [CGPoint]  // image pixels
    var colour: NSColor
    var action: String  // what this hand's pinch does
    var gapCm: Float
    var pinched: Bool
    var pinchedText: String  // shown while the pinch is held
}

struct FlashHelp {
    var text: String
    var at: CGPoint  // image pixels
    var started: Double  // CACurrentMediaTime
}

struct MenuHelp {
    var names: [String]
    var selected: Int
    var anchor: Int  // the item level with `at`, where the hold started
    var at: CGPoint  // image pixels
    var stepPx: CGFloat  // image pixels the hand moves per item
}

/// Everything the window draws for one frame.
struct Scene {
    var image: CGImage
    var hands: [HandHelp] = []
    var flash: FlashHelp?
    var menu: MenuHelp?
    var hint = ""
    var status = ""  // shown in the toolbar
    var showHelp = true
}

enum Palette {
    static let effects = NSColor(red: 0, green: 0.78, blue: 1, alpha: 1)  // light blue
    static let black = NSColor(red: 1, green: 0.31, blue: 0.86, alpha: 1)  // pink
    static let green = NSColor(red: 0.43, green: 0.92, blue: 0.47, alpha: 1)
    static let grey = NSColor(white: 0.48, alpha: 1)
    static let muted = NSColor(white: 0.7, alpha: 1)
    static let ink = NSColor(white: 0.11, alpha: 1)
    static let panel = NSColor(white: 0.12, alpha: 0.72)
}

private let flashSeconds = 0.7
private let bones = [(0, 1), (1, 2), (2, 3), (3, 4), (0, 5), (5, 6), (6, 7), (7, 8), (5, 9), (9, 10), (10, 11),
                     (11, 12), (9, 13), (13, 14), (14, 15), (15, 16), (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)]

/// The window: the picture mirrored, like a meeting app's preview, and the help on top.
final class FrameView: NSView {
    var scene: Scene?
    var onKey: ((String) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Told each change of the frame drawn with the mouse (image pixels; nil: none).
    var onDrawBox: ((SIMD4<Float>?) -> Void)?

    /// The frame drawn with the mouse, in image pixels: xmin, ymin, xmax, ymax.
    var drawnBox: SIMD4<Float>? {
        didSet {
            onDrawBox?(drawnBox)
            if let size = pictureSize {
                let scale = SIMD4(Float(size.width), Float(size.height), Float(size.width), Float(size.height))
                Settings.frame = drawnBox.map { $0 / scale }
            }
        }
    }

    /// The saved frame, waiting for the first picture to give it a size.
    private var savedFrame = Settings.frame
    private var pictureSize: CGSize?

    /// Locked: the mouse cannot draw, move, resize or remove the frame, and the handles are hidden.
    var frameLocked = Settings.bool("frameLocked", or: false) {
        didSet { Settings.set("frameLocked", frameLocked) }
    }

    /// What a mouse drag does: draw a new frame, move the frame, or move some of its edges.
    private enum Drag {
        case draw(from: CGPoint)
        case move(from: CGPoint, box: SIMD4<Float>)
        case resize(from: CGPoint, box: SIMD4<Float>, left: Bool, right: Bool, top: Bool, bottom: Bool)
    }
    private var drag: Drag?
    private var dragged = false
    private static let grab: CGFloat = 10  // view points from an edge that still grab it

    /// A view point's place in the picture: the inverse of `view(_:)`.
    private func picture(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (origin.x + size.width - p.x) / scale, y: (p.y - origin.y) / scale)
    }

    private func mousePoint(_ event: NSEvent) -> CGPoint { picture(convert(event.locationInWindow, from: nil)) }

    /// What a press at picture point `p` would do: near an edge resizes, inside moves, outside draws.
    private func drag(at p: CGPoint) -> Drag {
        guard let b = drawnBox else { return .draw(from: p) }
        let reach = Float(Self.grab / max(scale, 0.01)), x = Float(p.x), y = Float(p.y)
        let alongX = x > b.x - reach && x < b.z + reach, alongY = y > b.y - reach && y < b.w + reach
        let left = alongY && abs(x - b.x) < reach, right = alongY && abs(x - b.z) < reach
        let top = alongX && abs(y - b.y) < reach, bottom = alongX && abs(y - b.w) < reach
        if left || right || top || bottom {
            return .resize(from: p, box: b, left: left, right: right, top: top, bottom: bottom)
        }
        if x > b.x, x < b.z, y > b.y, y < b.w { return .move(from: p, box: b) }
        return .draw(from: p)
    }

    override func mouseDown(with event: NSEvent) {
        drag = frameLocked ? nil : drag(at: mousePoint(event))
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        dragged = true
        let p = mousePoint(event)
        switch drag {
        case .draw(let from):
            drawnBox = ordered(SIMD4(Float(from.x), Float(from.y), Float(p.x), Float(p.y)))
        case .move(let from, let box):
            let d = SIMD2(Float(p.x - from.x), Float(p.y - from.y))
            drawnBox = box + SIMD4(d.x, d.y, d.x, d.y)
        case .resize(let from, var box, let left, let right, let top, let bottom):
            let dx = Float(p.x - from.x), dy = Float(p.y - from.y)
            if left { box.x += dx }
            if right { box.z += dx }
            if top { box.y += dy }
            if bottom { box.w += dy }
            drawnBox = ordered(box)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard drag != nil else { return }
        if !dragged, case .draw = drag { drawnBox = nil }  // a click outside the frame removes it
    }

    private func ordered(_ b: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(min(b.x, b.z), min(b.y, b.w), max(b.x, b.z), max(b.y, b.w))
    }

    // The cursor shows what a press would do.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !frameLocked else { return NSCursor.arrow.set() }
        switch drag(at: mousePoint(event)) {
        case .draw: NSCursor.crosshair.set()
        case .move: NSCursor.openHand.set()
        case .resize(_, _, let l, let r, let t, let b):
            ((l || r) && !(t || b) ? NSCursor.resizeLeftRight : (t || b) && !(l || r) ? NSCursor.resizeUpDown
                : NSCursor.crosshair).set()
        }
    }

    /// Square handles on the corners and edge middles of the drawn frame.
    private func drawHandles(_ b: SIMD4<Float>) {
        let a = view(CGPoint(x: CGFloat(b.x), y: CGFloat(b.y))), c = view(CGPoint(x: CGFloat(b.z), y: CGFloat(b.w)))
        let r = CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
        let side: CGFloat = 10
        for x in [r.minX, r.midX, r.maxX] {
            for y in [r.minY, r.midY, r.maxY] where !(x == r.midX && y == r.midY) {
                let handle = NSBezierPath(rect: CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
                NSColor.white.setFill(); handle.fill()
                Palette.ink.setStroke(); handle.lineWidth = 1.5; handle.stroke()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers else { return super.keyDown(with: event) }
        onKey?(key)
    }

    // Layout of the picture in the view, and a size unit (1 at a 1080 px tall picture).
    private var origin = CGPoint.zero, size = CGSize.zero, scale: CGFloat = 1, unit: CGFloat = 1

    /// An image pixel's place in the mirrored view.
    private func view(_ p: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + size.width - p.x * scale, y: origin.y + p.y * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill()
        bounds.fill()
        guard let scene else { return }
        let image = scene.image
        pictureSize = CGSize(width: image.width, height: image.height)
        if let saved = savedFrame {
            savedFrame = nil
            drawnBox = saved * SIMD4(Float(image.width), Float(image.height), Float(image.width), Float(image.height))
        }
        scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        unit = size.height / 1080
        ctx.saveGState()
        ctx.translateBy(x: origin.x + size.width, y: origin.y + size.height)
        ctx.scaleBy(x: -1, y: -1)  // in this flipped view: upright and mirrored
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()

        if let box = drawnBox, !frameLocked { drawHandles(box) }
        if scene.showHelp {
            scene.hands.forEach(drawHand)
            if let flash = scene.flash { drawFlash(flash) }
            if let menu = scene.menu { drawMenu(menu) }
            let hintSize = textSize(scene.hint, 30)
            pill(scene.hint, x: origin.x + (size.width - hintSize.width) / 2 - 16 * unit,
                 midY: origin.y + size.height - 50 * unit, size: 30)
        }
    }

    private func drawHand(_ hand: HandHelp) {
        let pts = hand.points.map(view)
        let skeleton = NSBezierPath()
        for (a, b) in bones {
            skeleton.move(to: pts[a]); skeleton.line(to: pts[b])
        }
        hand.colour.setStroke(); skeleton.lineWidth = 3 * unit; skeleton.stroke()
        for p in pts {
            let r = 5 * unit
            let dot = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            NSColor.white.setFill(); dot.fill()
            hand.colour.setStroke(); dot.lineWidth = 1.5 * unit; dot.stroke()
        }

        let progress = CGFloat(Pinch.progress(hand.gapCm))
        let gaugeColour = hand.pinched ? Palette.green : Palette.grey.blended(withFraction: progress, of: hand.colour)!
        let (thumb, index) = (pts[4], pts[8])
        let gap = NSBezierPath()
        gap.move(to: thumb); gap.line(to: index)
        gaugeColour.setStroke(); gap.lineWidth = (3 + 4 * progress) * unit; gap.stroke()
        let centre = CGPoint(x: (thumb.x + index.x) / 2, y: (thumb.y + index.y) / 2)
        let r = 24 * unit
        let ring = NSBezierPath(ovalIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        Palette.grey.setStroke(); ring.lineWidth = 3 * unit; ring.stroke()
        if hand.pinched {
            Palette.green.setFill(); ring.fill()
        } else if progress > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: centre, radius: r, startAngle: -90, endAngle: -90 + 360 * progress)
            gaugeColour.setStroke(); arc.lineWidth = 6 * unit; arc.stroke()
        }
        let text = hand.pinched ? hand.pinchedText
            : String(format: "%@: pinch %.1f cm more", hand.action, max(hand.gapCm - Pinch.onCm, 0))
        if !text.isEmpty {
            pill(text, x: centre.x + r + 14 * unit, midY: centre.y, size: 26,
                 colour: hand.pinched ? Palette.green : .white)
        }
    }

    private func drawFlash(_ flash: FlashHelp) {
        let age = CACurrentMediaTime() - flash.started
        guard age <= flashSeconds else { return }
        let c = view(flash.at)
        let r = (28 + 110 * CGFloat(age / flashSeconds)) * unit
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        Palette.green.setStroke(); ring.lineWidth = 4 * unit; ring.stroke()
        let w = textSize(flash.text, 44).width
        pill(flash.text, x: c.x - w / 2 - 24 * unit, midY: c.y - 70 * unit, size: 44, colour: Palette.ink,
             background: Palette.green.withAlphaComponent(0.92))
    }

    /// The effect list beside the pinch: it stays put, and the highlight follows the hand.
    private func drawMenu(_ menu: MenuHelp) {
        let hand = view(menu.at)
        let step = menu.stepPx * scale
        let fontSize = min(30, step / unit * 0.6)
        let pad = 18 * unit
        let boxW = menu.names.map { textSize($0, fontSize).width }.max()! + 2 * pad
        let gap = 70 * unit
        let left = hand.x + gap + boxW <= origin.x + size.width ? hand.x + gap : hand.x - gap - boxW
        let rows = menu.names.indices.map { hand.y + CGFloat($0 - menu.anchor) * step }
        let half = step / 2
        let top = rows.first! - half - pad / 2
        Palette.panel.setFill()
        NSBezierPath(roundedRect: CGRect(x: left, y: top, width: boxW, height: rows.last! + half + pad / 2 - top),
                     xRadius: 22 * unit, yRadius: 22 * unit).fill()
        let inset = 6 * unit
        for (i, (name, row)) in zip(menu.names, rows).enumerated() {
            if i == menu.selected {
                let h = 2 * half - inset
                Palette.green.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: CGRect(x: left + inset, y: row - h / 2, width: boxW - 2 * inset, height: h),
                             xRadius: h / 2, yRadius: h / 2).fill()
            }
            let th = textSize(name, fontSize).height
            text(name, at: CGPoint(x: left + pad, y: row - th / 2), size: fontSize,
                 colour: i == menu.selected ? Palette.ink : .white)
        }
    }

    // MARK: Text

    private func attributes(_ size: CGFloat, _ colour: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont(name: "Marker Felt Wide", size: size * unit) ?? .boldSystemFont(ofSize: size * unit),
         .foregroundColor: colour]
    }

    private func textSize(_ s: String, _ size: CGFloat) -> CGSize {
        NSAttributedString(string: s, attributes: attributes(size, .white)).size()
    }

    private func text(_ s: String, at p: CGPoint, size: CGFloat, colour: NSColor) {
        NSAttributedString(string: s, attributes: attributes(size, colour)).draw(at: p)
    }

    /// Text in a rounded pill; `x` is its left edge and `midY` its vertical middle.
    private func pill(_ s: String, x: CGFloat, midY: CGFloat, size: CGFloat, colour: NSColor = .white,
                      background: NSColor = Palette.panel) {
        guard !s.isEmpty else { return }
        let t = textSize(s, size)
        let (padX, padY) = (size * 0.55 * unit, size * 0.25 * unit)
        let box = CGRect(x: x, y: midY - t.height / 2 - padY, width: t.width + 2 * padX, height: t.height + 2 * padY)
        background.setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        text(s, at: CGPoint(x: x + padX, y: midY - t.height / 2), size: size, colour: colour)
    }
}
