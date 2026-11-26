import Foundation

/// A rotated rectangle in image pixels. `angle` turns the rect clockwise on screen (y points down).
public struct RotatedRect: Equatable {
    public var cx, cy, w, h, angle: Float

    public init(cx: Float, cy: Float, w: Float, h: Float, angle: Float) {
        (self.cx, self.cy, self.w, self.h, self.angle) = (cx, cy, w, h, angle)
    }

    /// Image position of a point given in rect units, -0.5…0.5 on each axis.
    public func point(u: Float, v: Float) -> SIMD2<Float> {
        let (c, s) = (cos(angle), sin(angle))
        return [cx + c * u * w - s * v * h, cy + s * u * w + c * v * h]
    }

    /// The axis-aligned box around the rect: xmin, ymin, xmax, ymax.
    public var bounds: SIMD4<Float> {
        let corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { point(u: Float($0.0), v: Float($0.1)) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return [xs.min()!, ys.min()!, xs.max()!, ys.max()!]
    }
}

/// A palm found by the detector, in image pixels.
public struct Palm {
    public var box: SIMD4<Float>  // xmin, ymin, xmax, ymax
    public var keypoints: [SIMD2<Float>]  // 7: wrist, index base, middle base, ring base, little base, thumb x2
    public var score: Float
}

func normalizeAngle(_ a: Float) -> Float {
    a - 2 * .pi * (((a + .pi) / (2 * .pi)).rounded(.down))
}

/// The angle that turns the line from `from` to `to` so that it points straight up.
func uprightAngle(from: SIMD2<Float>, to: SIMD2<Float>) -> Float {
    normalizeAngle(.pi / 2 - atan2(-(to.y - from.y), to.x - from.x))
}

/// MediaPipe's RectTransformation with no x shift and a square from the long side.
func transform(_ r: RotatedRect, scale: Float, shiftY: Float) -> RotatedRect {
    let side = max(r.w, r.h) * scale
    return RotatedRect(
        cx: r.cx - r.h * shiftY * sin(r.angle), cy: r.cy + r.h * shiftY * cos(r.angle),
        w: side, h: side, angle: r.angle)
}

/// The landmark model's crop for a palm: turned upright from wrist to middle finger, then enlarged.
public func rect(for palm: Palm) -> RotatedRect {
    let b = palm.box
    let r = RotatedRect(
        cx: (b.x + b.z) / 2, cy: (b.y + b.w) / 2, w: b.z - b.x, h: b.w - b.y,
        angle: uprightAngle(from: palm.keypoints[0], to: palm.keypoints[2]))
    return transform(r, scale: 2.6, shiftY: -0.5)
}

/// The crop for the next frame, from this frame's landmarks (image pixels).
public func rect(forLandmarks lm: [SIMD3<Float>]) -> RotatedRect {
    let p = lm.map { SIMD2<Float>($0.x, $0.y) }
    let knuckles = (p[5] + p[13]) / 2
    let angle = uprightAngle(from: p[0], to: (knuckles + p[9]) / 2)
    let palmAndBase = [0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18].map { p[$0] }
    let lo = palmAndBase.reduce(palmAndBase[0]) { pointwiseMin($0, $1) }
    let hi = palmAndBase.reduce(palmAndBase[0]) { pointwiseMax($0, $1) }
    let centre = (lo + hi) / 2
    // Extent along the rect's own axes.
    let (c, s) = (cos(-angle), sin(-angle))
    let turned = palmAndBase.map { d -> SIMD2<Float> in
        let q = d - centre
        return [c * q.x - s * q.y, s * q.x + c * q.y]
    }
    let tLo = turned.reduce(turned[0]) { pointwiseMin($0, $1) }
    let tHi = turned.reduce(turned[0]) { pointwiseMax($0, $1) }
    let mid = (tLo + tHi) / 2
    let (c2, s2) = (cos(angle), sin(angle))
    let r = RotatedRect(
        cx: centre.x + c2 * mid.x - s2 * mid.y, cy: centre.y + s2 * mid.x + c2 * mid.y,
        w: tHi.x - tLo.x, h: tHi.y - tLo.y, angle: angle)
    return transform(r, scale: 2.0, shiftY: -0.1)
}

// MARK: - Palm detector output

public enum PalmDecoder {
    public static let inputSize = 192

    /// 2016 anchor centres, normalised: 24 x 24 cells with 2 anchors, then 12 x 12 cells with 6.
    public static let anchors: [SIMD2<Float>] = {
        var out: [SIMD2<Float>] = []
        for (cells, perCell) in [(24, 2), (12, 6)] {
            for y in 0..<cells {
                for x in 0..<cells {
                    let centre = SIMD2<Float>((Float(x) + 0.5) / Float(cells), (Float(y) + 0.5) / Float(cells))
                    out += Array(repeating: centre, count: perCell)
                }
            }
        }
        return out
    }()

    /// Palms from the raw outputs (2016 x 18 boxes, 2016 logits), in the detector's 0–1 square.
    public static func decode(boxes raw: [Float], logits: [Float], minScore: Float = 0.5) -> [Palm] {
        let size = Float(inputSize)
        var palms: [Palm] = []
        for i in 0..<anchors.count {
            let score = 1 / (1 + exp(-min(max(logits[i], -100), 100)))
            guard score >= minScore else { continue }
            let r = raw[(i * 18)..<(i * 18 + 18)].map { $0 / size }
            let a = anchors[i]
            let (cx, cy, w, h) = (r[0] + a.x, r[1] + a.y, r[2], r[3])
            let keypoints = (0..<7).map { SIMD2<Float>(r[4 + 2 * $0] + a.x, r[5 + 2 * $0] + a.y) }
            palms.append(Palm(box: [cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], keypoints: keypoints, score: score))
        }
        return weightedNMS(palms)
    }

    /// Group boxes that overlap more than `iou`; each group becomes its score-weighted average.
    public static func weightedNMS(_ palms: [Palm], iou minIoU: Float = 0.3) -> [Palm] {
        var left = palms.sorted { $0.score > $1.score }
        var out: [Palm] = []
        while let top = left.first {
            let group = left.filter { iou(top.box, $0.box) > minIoU }
            left.removeAll { iou(top.box, $0.box) > minIoU }
            let total = group.reduce(0) { $0 + $1.score }
            let box = group.reduce(SIMD4<Float>()) { $0 + $1.box * $1.score } / total
            let keypoints = (0..<7).map { k in group.reduce(SIMD2<Float>()) { $0 + $1.keypoints[k] * $1.score } / total }
            out.append(Palm(box: box, keypoints: keypoints, score: top.score))
        }
        return out
    }
}

public func iou(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
    let ix = max(0, min(a.z, b.z) - max(a.x, b.x))
    let iy = max(0, min(a.w, b.w) - max(a.y, b.y))
    let inter = ix * iy
    let union = (a.z - a.x) * (a.w - a.y) + (b.z - b.x) * (b.w - b.y) - inter
    return union > 0 ? inter / union : 0
}
