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
    var status = ""
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

    /// Called while you drag a frame with the mouse (image pixels), and with nil on a plain click.
    var onDrawBox: ((SIMD4<Float>?) -> Void)?
    private var dragStart: CGPoint?

    /// A view point's place in the picture: the inverse of `view(_:)`.
    private func picture(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (origin.x + size.width - p.x) / scale, y: (p.y - origin.y) / scale)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let a = picture(start), b = picture(convert(event.locationInWindow, from: nil))
        onDrawBox?(SIMD4(Float(min(a.x, b.x)), Float(min(a.y, b.y)), Float(max(a.x, b.x)), Float(max(a.y, b.y))))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - start.x, end.y - start.y) < 4 { onDrawBox?(nil) }  // a click removes the drawn frame
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
        scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        unit = size.height / 1080
        ctx.saveGState()
        ctx.translateBy(x: origin.x + size.width, y: origin.y + size.height)
        ctx.scaleBy(x: -1, y: -1)  // in this flipped view: upright and mirrored
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()

        if scene.showHelp {
            scene.hands.forEach(drawHand)
            if let flash = scene.flash { drawFlash(flash) }
            if let menu = scene.menu { drawMenu(menu) }
            let hintSize = textSize(scene.hint, 30)
            pill(scene.hint, x: origin.x + (size.width - hintSize.width) / 2 - 16 * unit,
                 midY: origin.y + size.height - 50 * unit, size: 30)
        }
        pill(scene.status, x: origin.x + 16 * unit, midY: origin.y + 34 * unit, size: 24, colour: Palette.muted)
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
